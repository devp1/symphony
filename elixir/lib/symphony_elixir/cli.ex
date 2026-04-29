defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [
    {@acknowledgement_switch, :boolean},
    allow_stale_binary: :boolean,
    logs_root: :string,
    port: :integer
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:set_logs_root) => (String.t() -> :ok | {:error, term()}),
          required(:set_server_port_override) => (non_neg_integer() | nil -> :ok | {:error, term()}),
          required(:ensure_all_started) => (-> ensure_started_result()),
          optional(:validate_runtime_freshness) => (String.t() -> :ok | {:error, String.t()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps, opts)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps, opts)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    run(workflow_path, deps, [])
  end

  @spec run(String.t(), deps(), keyword()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps, opts) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      with :ok <- maybe_validate_runtime_freshness(expanded_path, opts, deps) do
        case deps.ensure_all_started.() do
          {:ok, _started_apps} ->
            :ok

          {:error, reason} ->
            {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
        end
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--allow-stale-binary] [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      validate_runtime_freshness: &validate_runtime_freshness/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_validate_runtime_freshness(workflow_path, opts, deps) do
    if Keyword.get(opts, :allow_stale_binary, false) do
      :ok
    else
      freshness_validator = Map.get(deps, :validate_runtime_freshness, fn _path -> :ok end)
      freshness_validator.(workflow_path)
    end
  end

  defp validate_runtime_freshness(_workflow_path) do
    with {:ok, script_path} <- current_escript_path(),
         {:ok, checkout_root} <- source_checkout_root(script_path),
         {:ok, script_mtime} <- file_mtime(script_path),
         {:ok, newest_source_mtime} <- newest_runtime_source_mtime(checkout_root),
         true <- newest_source_mtime <= script_mtime do
      :ok
    else
      false ->
        {:error, stale_binary_message(current_escript_path!(), source_checkout_root!())}

      {:skip, _reason} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp current_escript_path do
    case :escript.script_name() do
      path when is_list(path) -> {:ok, path |> List.to_string() |> Path.expand()}
      path when is_binary(path) -> {:ok, Path.expand(path)}
      _other -> {:skip, :not_escript}
    end
  rescue
    _error -> {:skip, :not_escript}
  end

  defp current_escript_path! do
    case current_escript_path() do
      {:ok, path} -> path
      _ -> "bin/symphony"
    end
  end

  defp source_checkout_root(script_path) when is_binary(script_path) do
    bin_dir = Path.dirname(script_path)
    checkout_root = Path.expand("..", bin_dir)

    cond do
      Path.basename(bin_dir) != "bin" ->
        {:skip, :not_checkout_binary}

      not File.dir?(Path.join(checkout_root, "lib")) ->
        {:skip, :source_not_available}

      not File.regular?(Path.join(checkout_root, "mix.exs")) ->
        {:skip, :source_not_available}

      true ->
        {:ok, checkout_root}
    end
  end

  defp source_checkout_root! do
    with {:ok, script_path} <- current_escript_path(),
         {:ok, checkout_root} <- source_checkout_root(script_path) do
      checkout_root
    else
      _ -> File.cwd!()
    end
  end

  defp newest_runtime_source_mtime(checkout_root) when is_binary(checkout_root) do
    mtimes =
      checkout_root
      |> runtime_source_paths()
      |> Enum.flat_map(&source_mtimes/1)

    case mtimes do
      [] -> {:skip, :no_source_files}
      mtimes -> {:ok, Enum.max(mtimes)}
    end
  end

  defp runtime_source_paths(checkout_root) do
    [
      Path.join(checkout_root, "lib"),
      Path.join(checkout_root, "config"),
      Path.join(checkout_root, "priv"),
      Path.join(checkout_root, "mix.exs"),
      Path.join(checkout_root, "mix.lock")
    ]
  end

  defp source_mtimes(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} ->
        children =
          case File.ls(path) do
            {:ok, names} -> Enum.map(names, &Path.join(path, &1))
            {:error, _reason} -> []
          end

        [mtime | Enum.flat_map(children, &source_mtimes/1)]

      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        [mtime]

      {:ok, _stat} ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> {:ok, mtime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stale_binary_message(script_path, checkout_root) do
    """
    Stale Symphony binary: #{script_path} is older than runtime source in #{checkout_root}.
    Run `mise exec -- mix build` from #{checkout_root}, then restart Symphony.
    Use `--allow-stale-binary` only when you intentionally want the packaged binary.
    """
    |> String.trim()
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
