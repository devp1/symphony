defmodule SymphonyElixir.CodingAgent.ClaudeCodeAdapter do
  @moduledoc """
  Claude Code CLI implementation of the coding-agent adapter contract.

  This adapter is intentionally local-only. It uses the user's existing Claude
  Code OAuth/keychain login by running the normal `claude` CLI, not `--bare`.
  """

  @behaviour SymphonyElixir.CodingAgent.Adapter

  require Logger

  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576
  @auth_failure_markers ["auth", "authenticate", "authentication", "login", "oauth", "keychain"]

  @type session :: %{
          agent_provider: String.t(),
          thread_id: String.t(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: nil,
          metadata: map()
        }

  @impl true
  def run(role, workspace, prompt, issue, opts) do
    with {:ok, session} <- start_session(role, workspace, opts) do
      run_turn(role, session, prompt, issue, opts)
    end
  end

  @impl true
  def start_session(role, workspace, opts) do
    if is_binary(Keyword.get(opts, :worker_host)) do
      {:error, {:unsupported_agent_provider, :claude_code, :remote_worker}}
    else
      do_start_session(role, workspace, opts)
    end
  end

  defp do_start_session(_role, workspace, opts) do
    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace) do
      session_id = reusable_session_id(Keyword.get(opts, :resume_thread_id))

      {:ok,
       %{
         agent_provider: "claude_code",
         thread_id: session_id,
         session_id: session_id,
         workspace: expanded_workspace,
         worker_host: nil,
         metadata: %{claude_code_session_id: session_id}
       }}
    end
  end

  @spec run_turn(SymphonyElixir.CodingAgent.role(), session(), String.t(), map()) ::
          SymphonyElixir.CodingAgent.result()
  def run_turn(role, session, prompt, issue), do: run_turn(role, session, prompt, issue, [])

  @impl true
  def run_turn(_role, %{thread_id: session_id, workspace: workspace, metadata: metadata} = session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    config = Config.settings!()
    timeout_ms = config.codex.turn_timeout_ms
    stall_timeout_ms = config.codex.stall_timeout_ms
    env = Keyword.get(opts, :env, [])

    with {:ok, argv} <- cli_argv(session_id, config, Keyword.get(opts, :agent_profile)),
         {:ok, prompt_path} <- write_prompt_file(prompt) do
      try do
        run_cli_turn(%{
          argv: argv,
          prompt_path: prompt_path,
          workspace: workspace,
          session: session,
          issue: issue,
          on_message: on_message,
          metadata: metadata,
          timeout_ms: timeout_ms,
          stall_timeout_ms: stall_timeout_ms,
          env: env
        })
      after
        File.rm(prompt_path)
      end
    end
  end

  @impl true
  def stop_session(_role, _session, _opts), do: :ok

  @doc false
  @spec cli_argv(String.t(), map()) :: {:ok, [String.t()]} | {:error, term()}
  def cli_argv(session_id, config), do: cli_argv(session_id, config, nil)

  @doc false
  @spec cli_argv(String.t(), map(), map() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def cli_argv(session_id, %{claude_code: claude_code}, agent_profile) when is_binary(session_id) do
    agent_profile = agent_profile || %{}

    with {:ok, command_parts} <- command_parts(claude_code.command),
         [executable | command_args] <- command_parts,
         {:ok, executable} <- resolve_executable(executable) do
      args =
        command_args ++
          [
            "-p",
            "--verbose",
            "--output-format",
            "stream-json",
            "--input-format",
            "text",
            "--permission-mode",
            Map.get(agent_profile, :permission_mode) || claude_code.permission_mode,
            "--session-id",
            session_id
          ] ++
          model_args(Map.get(agent_profile, :model) || claude_code.model) ++
          effort_args(Map.get(agent_profile, :effort)) ++
          setting_sources_args(claude_code.setting_sources) ++
          List.wrap(Map.get(agent_profile, :extra_args)) ++
          claude_code.extra_args

      {:ok, [executable | args]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_cli_turn(%{
         argv: argv,
         prompt_path: prompt_path,
         workspace: workspace,
         session: session,
         issue: issue,
         on_message: on_message,
         metadata: metadata,
         timeout_ms: timeout_ms,
         stall_timeout_ms: stall_timeout_ms,
         env: env
       }) do
    [executable | args] = argv

    with {:ok, port} <- start_port(executable, args, workspace, prompt_path, env) do
      metadata = Map.merge(metadata, port_metadata(port))
      session_id = session.session_id

      Logger.info("Claude Code session started for #{issue_context(issue)} session_id=#{session_id}")

      emit_message(on_message, :session_started, %{session_id: session_id, thread_id: session.thread_id}, metadata)

      started_at = now_ms()

      context = %{
        port: port,
        on_message: on_message,
        metadata: metadata,
        started_at: started_at,
        last_output_at: started_at,
        timeout_ms: timeout_ms,
        stall_timeout_ms: stall_timeout_ms,
        result: nil,
        raw_lines: []
      }

      case await_result(context) do
        {:ok, result} ->
          Logger.info("Claude Code session completed for #{issue_context(issue)} session_id=#{session_id}")

          {:ok,
           %{
             result: result,
             session_id: session_id,
             thread_id: session.thread_id
           }}

        {:error, reason} ->
          Logger.warning("Claude Code session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

          emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
          {:error, reason}
      end
    end
  end

  defp start_port(executable, args, workspace, prompt_path, env) do
    bash = System.find_executable("bash")

    if is_nil(bash) do
      {:error, :bash_not_found}
    else
      wrapper = ~s(exec "$@" < "$CLAUDE_PROMPT_FILE")

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(bash)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: port_args(wrapper, executable, args),
            cd: String.to_charlist(workspace),
            env: port_env(prompt_path, env),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp port_args(wrapper, executable, args) do
    [~c"-lc", String.to_charlist(wrapper), ~c"symphony-claude-code", String.to_charlist(executable) | Enum.map(args, &String.to_charlist/1)]
  end

  defp port_env(prompt_path, env) do
    [{~c"CLAUDE_PROMPT_FILE", String.to_charlist(prompt_path)}] ++
      Enum.map(env, fn {key, value} -> {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))} end)
  end

  defp await_result(
         %{
           port: port,
           started_at: started_at,
           last_output_at: last_output_at,
           timeout_ms: timeout_ms,
           stall_timeout_ms: stall_timeout_ms,
           result: result,
           raw_lines: raw_lines
         } = context
       ) do
    receive_timeout = next_receive_timeout(started_at, last_output_at, timeout_ms, stall_timeout_ms)

    receive do
      {^port, {:data, {:eol, line}}} ->
        handle_output_line(%{context | last_output_at: now_ms()}, to_string(line))

      {^port, {:data, {:noeol, line}}} ->
        handle_output_line(%{context | last_output_at: now_ms()}, to_string(line))

      {^port, {:exit_status, 0}} ->
        case result do
          %{} -> {:ok, result}
          nil -> {:error, {:claude_code_missing_result, Enum.reverse(raw_lines)}}
        end

      {^port, {:exit_status, status}} ->
        raw = Enum.reverse(raw_lines)

        if auth_failure_in_plain_output?(raw) do
          {:error, {:claude_code_auth_failed, raw}}
        else
          {:error, {:claude_code_exit, status, raw}}
        end
    after
      receive_timeout ->
        reason = timeout_reason(started_at, last_output_at, timeout_ms, stall_timeout_ms)
        Port.close(port)
        {:error, reason}
    end
  end

  defp handle_output_line(context, line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      await_result(context)
    else
      handle_json_line(context, trimmed)
    end
  end

  defp handle_json_line(context, trimmed) do
    case Jason.decode(trimmed) do
      {:ok, %{} = payload} ->
        emit_claude_event(context.on_message, payload, context.metadata)
        continue_from_payload(context, payload, trimmed)

      {:error, _reason} ->
        if auth_failure?(trimmed) do
          Port.close(context.port)
          {:error, {:claude_code_auth_failed, trimmed}}
        else
          Port.close(context.port)
          {:error, {:malformed_claude_json, trimmed}}
        end
    end
  end

  defp continue_from_payload(context, payload, trimmed) do
    raw_lines = [trimmed | context.raw_lines]

    case result_from_payload(payload) do
      {:ok, result} ->
        await_result(%{context | result: result, raw_lines: raw_lines})

      {:error, reason} ->
        Port.close(context.port)
        {:error, reason}

      :cont ->
        await_result(%{context | raw_lines: raw_lines})
    end
  end

  defp result_from_payload(%{"type" => "result", "is_error" => false} = payload), do: {:ok, payload}
  defp result_from_payload(%{"type" => "result", "is_error" => true} = payload), do: {:error, {:claude_code_result_error, payload}}
  defp result_from_payload(%{type: "result", is_error: false} = payload), do: {:ok, payload}
  defp result_from_payload(%{type: "result", is_error: true} = payload), do: {:error, {:claude_code_result_error, payload}}
  defp result_from_payload(_payload), do: :cont

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp reusable_session_id(session_id) when is_binary(session_id) and session_id != "" do
    case Ecto.UUID.cast(session_id) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.generate()
    end
  end

  defp reusable_session_id(_session_id), do: Ecto.UUID.generate()

  defp command_parts(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> case do
      [] -> {:error, :empty_claude_code_command}
      parts -> {:ok, parts}
    end
  end

  defp command_parts(_command), do: {:error, :invalid_claude_code_command}

  defp resolve_executable(path) when is_binary(path) do
    cond do
      String.contains?(path, "/") and File.exists?(path) -> {:ok, path}
      String.contains?(path, "/") -> {:error, {:claude_code_command_not_found, path}}
      found = System.find_executable(path) -> {:ok, found}
      true -> {:error, {:claude_code_command_not_found, path}}
    end
  end

  defp model_args(model) when is_binary(model) do
    if String.trim(model) == "", do: [], else: ["--model", model]
  end

  defp model_args(_model), do: []

  defp effort_args(effort) when is_binary(effort) do
    if String.trim(effort) == "", do: [], else: ["--effort", effort]
  end

  defp effort_args(_effort), do: []

  defp setting_sources_args(setting_sources) when is_binary(setting_sources) do
    if String.trim(setting_sources) == "", do: [], else: ["--setting-sources", setting_sources]
  end

  defp setting_sources_args(_setting_sources), do: []

  defp write_prompt_file(prompt) when is_binary(prompt) do
    path = Path.join(System.tmp_dir!(), "symphony-claude-prompt-#{Ecto.UUID.generate()}.txt")

    case File.write(path, prompt) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:claude_code_prompt_write_failed, reason}}
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{claude_code_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp emit_claude_event(on_message, %{} = payload, metadata) do
    type = Map.get(payload, "type") || Map.get(payload, :type) || "unknown"

    emit_message(
      on_message,
      :"claude/event/#{type}",
      %{
        payload: payload,
        semantic_activity_at: DateTime.utc_now(),
        semantic_activity_reason: "claude event: #{type}"
      },
      metadata
    )
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp next_receive_timeout(started_at, last_output_at, timeout_ms, stall_timeout_ms) do
    now = now_ms()
    turn_remaining = max(1, timeout_ms - (now - started_at))

    stall_remaining =
      if stall_timeout_ms > 0,
        do: max(1, stall_timeout_ms - (now - last_output_at)),
        else: turn_remaining

    min(turn_remaining, stall_remaining)
  end

  defp timeout_reason(started_at, last_output_at, timeout_ms, stall_timeout_ms) do
    now = now_ms()

    cond do
      stall_timeout_ms > 0 and now - last_output_at >= stall_timeout_ms ->
        {:claude_code_timeout, :stall, stall_timeout_ms}

      now - started_at >= timeout_ms ->
        {:claude_code_timeout, :turn, timeout_ms}

      true ->
        {:claude_code_timeout, :unknown, min(timeout_ms, stall_timeout_ms)}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp auth_failure_in_plain_output?(lines) when is_list(lines) do
    Enum.any?(lines, fn line ->
      case Jason.decode(line) do
        {:ok, _json} -> false
        {:error, _reason} -> auth_failure?(line)
      end
    end)
  end

  defp auth_failure?(line) when is_binary(line) do
    downcased = String.downcase(line)
    Enum.any?(@auth_failure_markers, &String.contains?(downcased, &1))
  end

  defp auth_failure?(_line), do: false

  defp issue_context(%{identifier: identifier}) when is_binary(identifier), do: "issue_identifier=#{identifier}"
  defp issue_context(%{id: id}) when is_binary(id), do: "issue_id=#{id}"
  defp issue_context(_issue), do: "issue_id=unknown"
end
