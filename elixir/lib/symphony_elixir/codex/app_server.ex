defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @turn_interrupt_id 4
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @turn_interrupt_sentinel_interval_ms 500
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @github_issue_state_labels ~w(agent-ready in-progress human-review needs-input blocked rework merging)

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          resume_thread_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, opts),
           {:ok, thread_id, resume_metadata} <-
             do_start_session(port, expanded_workspace, session_policies, Keyword.get(opts, :resume_thread_id)) do
        {:ok,
         %{
           port: port,
           metadata: Map.merge(metadata, resume_metadata),
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           resume_thread_id: Keyword.get(opts, :resume_thread_id),
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_interrupt_sentinel = Keyword.get(opts, :turn_interrupt_sentinel)
    turn_interrupt_poll_ms = Keyword.get(opts, :turn_interrupt_poll_ms, @turn_interrupt_sentinel_interval_ms)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(
               port,
               on_message,
               tool_executor,
               auto_approve_requests,
               thread_id,
               turn_id,
               turn_interrupt_sentinel,
               turn_interrupt_poll_ms
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
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

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(Config.settings!().codex.command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, opts) do
    workspace
    |> Config.codex_runtime_settings()
    |> apply_session_policy_overrides(opts)
  end

  defp session_policies(workspace, worker_host, opts) when is_binary(worker_host) do
    workspace
    |> Config.codex_runtime_settings(remote: true)
    |> apply_session_policy_overrides(opts)
  end

  defp apply_session_policy_overrides({:ok, policies}, opts) when is_map(policies) and is_list(opts) do
    overrides =
      %{}
      |> maybe_put_policy_override(:approval_policy, Keyword.get(opts, :approval_policy))
      |> maybe_put_policy_override(:thread_sandbox, Keyword.get(opts, :thread_sandbox))
      |> maybe_put_policy_override(:turn_sandbox_policy, Keyword.get(opts, :turn_sandbox_policy))

    {:ok, Map.merge(policies, overrides)}
  end

  defp apply_session_policy_overrides({:error, reason}, _opts), do: {:error, reason}

  defp maybe_put_policy_override(overrides, _key, nil), do: overrides
  defp maybe_put_policy_override(overrides, key, value), do: Map.put(overrides, key, value)

  defp do_start_session(port, workspace, session_policies, resume_thread_id) do
    case send_initialize(port) do
      :ok -> start_or_resume_thread(port, workspace, session_policies, resume_thread_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_or_resume_thread(port, workspace, session_policies, resume_thread_id)
       when is_binary(resume_thread_id) and resume_thread_id != "" do
    case resume_thread(port, workspace, resume_thread_id) do
      {:ok, thread_id} ->
        {:ok, thread_id, %{resume_attempted: true, resume_succeeded: true, resume_failure_reason: nil}}

      {:error, reason} ->
        Logger.warning("Codex thread/resume failed; falling back to thread/start: #{inspect(reason)}")

        case start_thread(port, workspace, session_policies) do
          {:ok, thread_id} ->
            {:ok, thread_id,
             %{
               resume_attempted: true,
               resume_succeeded: false,
               resume_failure_reason: inspect(reason)
             }}

          other ->
            other
        end
    end
  end

  defp start_or_resume_thread(port, workspace, session_policies, _resume_thread_id) do
    case start_thread(port, workspace, session_policies) do
      {:ok, thread_id} ->
        {:ok, thread_id, %{resume_attempted: false, resume_succeeded: false, resume_failure_reason: nil}}

      other ->
        other
    end
  end

  defp resume_thread(port, workspace, thread_id) do
    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_start_id,
      "params" => %{
        "threadId" => thread_id,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, result} -> extract_thread_id(result)
      other -> other
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs(),
        "persistExtendedHistory" => true
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, result} ->
        extract_thread_id(result)

      other ->
        other
    end
  end

  defp extract_thread_id(%{"thread" => %{"id" => thread_id}}) when is_binary(thread_id), do: {:ok, thread_id}
  defp extract_thread_id(%{"id" => thread_id}) when is_binary(thread_id), do: {:ok, thread_id}
  defp extract_thread_id(payload), do: {:error, {:invalid_thread_payload, payload}}

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(
         port,
         on_message,
         tool_executor,
         auto_approve_requests,
         thread_id,
         turn_id,
         turn_interrupt_sentinel,
         turn_interrupt_poll_ms
       ) do
    receive_loop(
      port,
      on_message,
      "",
      tool_executor,
      auto_approve_requests,
      semantic_activity_state(thread_id, turn_id, turn_interrupt_sentinel, turn_interrupt_poll_ms)
    )
  end

  defp receive_loop(port, on_message, pending_line, tool_executor, auto_approve_requests, activity) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, tool_executor, auto_approve_requests, activity)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests,
          activity
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      receive_timeout_ms(activity) ->
        handle_receive_timeout(port, on_message, pending_line, tool_executor, auto_approve_requests, activity)
    end
  end

  defp handle_incoming(port, on_message, data, tool_executor, auto_approve_requests, activity) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        handle_turn_completed(port, on_message, payload, payload_string, tool_executor, auto_approve_requests, activity)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        handle_turn_failed(port, on_message, payload, payload_string, tool_executor, auto_approve_requests, activity)

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        handle_turn_cancelled(port, on_message, payload, payload_string, tool_executor, auto_approve_requests, activity)

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          tool_executor,
          auto_approve_requests,
          activity
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)
    end
  end

  defp handle_turn_completed(port, on_message, payload, payload_string, tool_executor, auto_approve_requests, activity) do
    if foreign_thread_notification?(payload, activity.thread_id) do
      receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)
    else
      emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
      {:ok, turn_completion_result(activity)}
    end
  end

  defp handle_turn_failed(port, on_message, payload, payload_string, tool_executor, auto_approve_requests, activity) do
    if foreign_thread_notification?(payload, activity.thread_id) do
      receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)
    else
      emit_turn_event(
        on_message,
        :turn_failed,
        payload,
        payload_string,
        port,
        Map.get(payload, "params")
      )

      {:error, {:turn_failed, Map.get(payload, "params")}}
    end
  end

  defp handle_turn_cancelled(port, on_message, payload, payload_string, tool_executor, auto_approve_requests, activity) do
    if foreign_thread_notification?(payload, activity.thread_id) do
      receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)
    else
      emit_turn_event(
        on_message,
        :turn_cancelled,
        payload,
        payload_string,
        port,
        Map.get(payload, "params")
      )

      turn_cancelled_result(activity, Map.get(payload, "params"))
    end
  end

  defp semantic_activity_state(thread_id, turn_id, turn_interrupt_sentinel, turn_interrupt_poll_ms) do
    now_ms = System.monotonic_time(:millisecond)
    now = DateTime.utc_now()

    %{
      thread_id: thread_id,
      turn_id: turn_id,
      timeout_ms: Config.settings!().codex.semantic_inactivity_timeout_ms,
      last_at_ms: now_ms,
      last_at: now,
      last_reason: "turn/start",
      turn_interrupt_sentinel: normalize_turn_interrupt_sentinel(turn_interrupt_sentinel),
      turn_interrupt_poll_ms: normalize_turn_interrupt_poll_ms(turn_interrupt_poll_ms),
      turn_interrupt_requested: nil
    }
  end

  defp normalize_turn_interrupt_sentinel(sentinel) when is_function(sentinel, 0), do: sentinel
  defp normalize_turn_interrupt_sentinel(_sentinel), do: nil

  defp normalize_turn_interrupt_poll_ms(poll_ms) when is_integer(poll_ms) and poll_ms > 0, do: poll_ms
  defp normalize_turn_interrupt_poll_ms(_poll_ms), do: @turn_interrupt_sentinel_interval_ms

  defp receive_timeout_ms(%{turn_interrupt_sentinel: sentinel, turn_interrupt_requested: nil} = activity)
       when is_function(sentinel, 0) do
    min(semantic_timeout_remaining_ms(activity), activity.turn_interrupt_poll_ms)
  end

  defp receive_timeout_ms(activity), do: semantic_timeout_remaining_ms(activity)

  defp handle_receive_timeout(port, on_message, pending_line, tool_executor, auto_approve_requests, activity) do
    if semantic_timeout_remaining_ms(activity) <= 0 do
      {:error, {:semantic_inactivity_timeout, semantic_timeout_payload(activity)}}
    else
      case maybe_interrupt_for_sentinel(port, on_message, activity) do
        {:ok, activity} ->
          receive_loop(port, on_message, pending_line, tool_executor, auto_approve_requests, activity)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_interrupt_for_sentinel(
         port,
         on_message,
         %{turn_interrupt_sentinel: sentinel, turn_interrupt_requested: nil} = activity
       )
       when is_function(sentinel, 0) do
    case sentinel.() do
      {:interrupt, reason, details} ->
        request_turn_interrupt(port, on_message, activity, reason, details)

      {:interrupt, reason} ->
        request_turn_interrupt(port, on_message, activity, reason, %{})

      :continue ->
        {:ok, activity}

      nil ->
        {:ok, activity}

      other ->
        {:error, {:invalid_turn_interrupt_sentinel_result, other}}
    end
  rescue
    error -> {:error, {:turn_interrupt_sentinel_failed, Exception.message(error)}}
  end

  defp maybe_interrupt_for_sentinel(_port, _on_message, activity), do: {:ok, activity}

  defp request_turn_interrupt(port, on_message, activity, reason, details) do
    payload = %{
      "method" => "turn/interrupt",
      "id" => @turn_interrupt_id,
      "params" => %{
        "threadId" => activity.thread_id,
        "turnId" => activity.turn_id
      }
    }

    send_message(port, payload)

    interrupt = %{
      reason: reason,
      details: details,
      requested_at: DateTime.utc_now(),
      thread_id: activity.thread_id,
      turn_id: activity.turn_id
    }

    emit_message(
      on_message,
      :turn_interrupt_requested,
      %{
        reason: reason,
        details: details,
        payload: payload
      },
      metadata_from_message(port, payload)
    )

    {:ok,
     %{
       activity
       | turn_interrupt_requested: interrupt,
         last_at_ms: System.monotonic_time(:millisecond),
         last_at: interrupt.requested_at,
         last_reason: "turn interrupt requested"
     }}
  end

  defp turn_completion_result(%{turn_interrupt_requested: interrupt}) when is_map(interrupt) do
    {:turn_interrupted, interrupt}
  end

  defp turn_completion_result(_activity), do: :turn_completed

  defp turn_cancelled_result(%{turn_interrupt_requested: interrupt} = activity, _params) when is_map(interrupt) do
    {:ok, turn_completion_result(activity)}
  end

  defp turn_cancelled_result(_activity, params), do: {:error, {:turn_cancelled, params}}

  defp semantic_timeout_remaining_ms(%{timeout_ms: timeout_ms, last_at_ms: last_at_ms}) do
    elapsed_ms = System.monotonic_time(:millisecond) - last_at_ms
    max(timeout_ms - elapsed_ms, 0)
  end

  defp semantic_timeout_payload(%{timeout_ms: timeout_ms, last_at: last_at, last_reason: last_reason}) do
    %{
      timeout_ms: timeout_ms,
      last_activity_at: last_at,
      last_activity_reason: last_reason
    }
  end

  defp mark_semantic_activity(activity, method, payload, metadata) do
    case semantic_activity_reason(method, payload) do
      nil ->
        {activity, metadata}

      reason ->
        now = DateTime.utc_now()

        updated_activity = %{
          activity
          | last_at_ms: System.monotonic_time(:millisecond),
            last_at: now,
            last_reason: reason
        }

        updated_metadata =
          metadata
          |> Map.put(:semantic_activity_at, now)
          |> Map.put(:semantic_activity_reason, reason)

        {updated_activity, updated_metadata}
    end
  end

  defp semantic_activity_reason("turn/started", _payload), do: "turn started"
  defp semantic_activity_reason("turn/diff/updated", _payload), do: "codex diff updated"
  defp semantic_activity_reason("item/agentMessage/delta", _payload), do: "agent message delta"
  defp semantic_activity_reason("item/commandExecution/outputDelta", _payload), do: "command output delta"
  defp semantic_activity_reason("item/fileChange/outputDelta", _payload), do: "file change output delta"
  defp semantic_activity_reason("item/mcpToolCall/progress", _payload), do: "mcp tool progress"
  defp semantic_activity_reason("item/tool/call", _payload), do: "dynamic tool call"
  defp semantic_activity_reason("item/commandExecution/requestApproval", _payload), do: "command approval requested"
  defp semantic_activity_reason("item/fileChange/requestApproval", _payload), do: "file change approval requested"
  defp semantic_activity_reason("execCommandApproval", _payload), do: "command approval requested"
  defp semantic_activity_reason("applyPatchApproval", _payload), do: "file change approval requested"
  defp semantic_activity_reason("item/tool/requestUserInput", _payload), do: "tool user input requested"
  defp semantic_activity_reason(_method, _payload), do: nil

  defp foreign_thread_notification?(payload, active_thread_id) when is_map(payload) and is_binary(active_thread_id) do
    case payload_thread_id(payload) do
      thread_id when is_binary(thread_id) and thread_id != active_thread_id -> true
      _ -> false
    end
  end

  defp foreign_thread_notification?(_payload, _active_thread_id), do: false

  defp payload_thread_id(payload) when is_map(payload) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}

    Map.get(payload, "threadId") ||
      Map.get(payload, :threadId) ||
      map_get(params, "threadId") ||
      map_get(params, "thread_id") ||
      thread_id_from_nested(map_get(params, "thread")) ||
      thread_id_from_nested(map_get(params, "item"))
  end

  defp payload_thread_id(_payload), do: nil

  defp thread_id_from_nested(%{} = value), do: map_get(value, "id") || map_get(value, "threadId")
  defp thread_id_from_nested(_value), do: nil

  defp map_get(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         tool_executor,
         auto_approve_requests,
         activity
       ) do
    if foreign_thread_notification?(payload, activity.thread_id) do
      receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)
    else
      metadata = metadata_from_message(port, payload)
      {activity, metadata} = mark_semantic_activity(activity, method, payload, metadata)

      case maybe_handle_approval_request(
             port,
             method,
             payload,
             payload_string,
             on_message,
             metadata,
             tool_executor,
             auto_approve_requests
           ) do
        :input_required ->
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}

        :approved ->
          receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)

        :approval_required ->
          emit_message(
            on_message,
            :approval_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:approval_required, payload}}

        :unhandled ->
          if needs_input?(method, payload) do
            emit_message(
              on_message,
              :turn_input_required,
              %{payload: payload, raw: payload_string},
              metadata
            )

            {:error, {:turn_input_required, payload}}
          else
            emit_message(
              on_message,
              :notification,
              %{
                payload: payload,
                raw: payload_string
              },
              metadata
            )

            Logger.debug("Codex notification: #{inspect(method)}")
            receive_loop(port, on_message, "", tool_executor, auto_approve_requests, activity)
          end
      end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         "mcpServer/elicitation/request",
         %{"id" => _id, "params" => _params} = _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :approval_required
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    approve_request(port, id, decision, payload, payload_string, on_message, metadata)
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    if safe_bookkeeping_approval?(payload) do
      approve_request(port, id, decision, payload, payload_string, on_message, metadata)
    else
      :approval_required
    end
  end

  defp approve_request(port, id, decision, payload, payload_string, on_message, metadata) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp safe_bookkeeping_approval?(%{"method" => "item/commandExecution/requestApproval", "params" => params})
       when is_map(params) do
    commands = approval_commands(params)

    Enum.any?(commands, &safe_github_issue_label_command?/1) or
      (safe_repo_validation_cwd?(Map.get(params, "cwd")) and
         Enum.any?(commands, &safe_repo_validation_command?/1))
  end

  defp safe_bookkeeping_approval?(_payload), do: false

  defp approval_commands(params) when is_map(params) do
    [
      Map.get(params, "command"),
      Map.get(params, "parsedCmd")
      | command_action_commands(Map.get(params, "commandActions"))
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp command_action_commands(actions) when is_list(actions) do
    actions
    |> Enum.map(fn
      %{"command" => command} when is_binary(command) -> command
      %{command: command} when is_binary(command) -> command
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end

  defp command_action_commands(_actions), do: []

  defp safe_github_issue_label_command?(command) when is_binary(command) do
    command
    |> unwrap_shell_command()
    |> github_issue_bookkeeping_command?()
  end

  defp safe_github_issue_label_command?(_command), do: false

  defp safe_repo_validation_command?(command) when is_binary(command) do
    command
    |> unwrap_shell_command()
    |> repo_validation_command?()
  end

  defp safe_repo_validation_command?(_command), do: false

  defp repo_validation_command?(command) when is_binary(command) do
    String.trim(command) in [
      "npm test",
      "npm run test",
      "npm run typecheck",
      "npm run lint"
    ]
  end

  defp safe_repo_validation_cwd?(cwd) when is_binary(cwd) do
    expanded_cwd = Path.expand(cwd)
    expanded_root = Path.expand(Config.settings!().workspace.root)

    with {:ok, canonical_cwd} <- PathSafety.canonicalize(expanded_cwd),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"
      canonical_cwd != canonical_root and String.starts_with?(canonical_cwd <> "/", canonical_root_prefix)
    else
      _ -> false
    end
  end

  defp safe_repo_validation_cwd?(_cwd), do: false

  defp unwrap_shell_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    case Regex.run(~r/\A(?:\/bin\/)?(?:zsh|bash|sh)\s+-lc\s+'([^']+)'\z/, trimmed) do
      [_, inner] -> inner
      _ -> trimmed
    end
  end

  defp github_issue_bookkeeping_command?(command) when is_binary(command) do
    github_issue_label_command?(command) or github_issue_comment_command?(command)
  end

  defp github_issue_label_command?(command) when is_binary(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      ["gh", "issue", "edit", issue_number | flags] ->
        github_issue_number?(issue_number) and github_issue_label_flags?(flags)

      _ ->
        false
    end
  end

  defp github_issue_comment_command?(command) when is_binary(command) do
    case Regex.run(~r/\Agh issue comment ([1-9][0-9]*) --repo ([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+) --body [\s\S]+\z/, command) do
      [_, issue_number, repo] -> github_issue_number?(issue_number) and repo == configured_github_repo()
      _ -> false
    end
  end

  defp github_issue_number?(issue_number) when is_binary(issue_number) do
    String.match?(issue_number, ~r/\A[1-9][0-9]*\z/)
  end

  defp github_issue_label_flags?(flags) when is_list(flags) do
    case parse_github_issue_label_flags(flags, %{repo: nil, labels: []}) do
      {:ok, %{repo: repo, labels: labels}} ->
        repo == configured_github_repo() and labels != [] and Enum.all?(labels, &(&1 in @github_issue_state_labels))

      :error ->
        false
    end
  end

  defp parse_github_issue_label_flags([], acc), do: {:ok, acc}

  defp parse_github_issue_label_flags(["--repo", repo | rest], acc) when is_binary(repo) do
    if valid_github_repo?(repo) do
      parse_github_issue_label_flags(rest, %{acc | repo: repo})
    else
      :error
    end
  end

  defp parse_github_issue_label_flags(["--add-label", label | rest], acc) when is_binary(label) do
    parse_github_issue_label_flags(rest, %{acc | labels: [label | acc.labels]})
  end

  defp parse_github_issue_label_flags(["--remove-label", label | rest], acc) when is_binary(label) do
    parse_github_issue_label_flags(rest, %{acc | labels: [label | acc.labels]})
  end

  defp parse_github_issue_label_flags(_flags, _acc), do: :error

  defp valid_github_repo?(repo) when is_binary(repo) do
    String.match?(repo, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
  end

  defp configured_github_repo do
    case Config.primary_repo() do
      %{owner: owner, name: name} when is_binary(owner) and is_binary(name) ->
        "#{owner}/#{name}"

      _ ->
        case Config.settings!().tracker do
          %{kind: "github", owner: owner, repo: repo} when is_binary(owner) and is_binary(repo) ->
            "#{owner}/#{repo}"

          _ ->
            nil
        end
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
