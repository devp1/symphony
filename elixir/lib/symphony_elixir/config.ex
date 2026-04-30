defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type github_role :: :builder | :reviewer | :operator
  @type github_auth :: {:app, map()} | {:token, String.t()} | nil

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    :ok = SymphonyElixir.LocalEnv.load_default_github_app_env()

    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec repos() :: [map()]
  def repos do
    settings!().repos
  end

  @spec repo_by_id(String.t()) :: map() | nil
  def repo_by_id(repo_id) when is_binary(repo_id) do
    Enum.find(repos(), &(&1.id == repo_id))
  end

  @spec primary_repo() :: map() | nil
  def primary_repo do
    List.first(repos())
  end

  @spec github_token(github_role()) :: String.t() | nil
  def github_token(:builder), do: settings!().github.builder_token
  def github_token(:reviewer), do: settings!().github.reviewer_token

  @spec github_app(github_role()) :: map() | nil
  def github_app(:builder), do: settings!().github.builder_app
  def github_app(:reviewer), do: settings!().github.reviewer_app

  @spec github_auth(github_role()) :: github_auth()
  def github_auth(role) when role in [:builder, :reviewer] do
    case github_app(role) do
      %{} = app when map_size(app) > 0 ->
        {:app, app}

      _ ->
        case github_token(role) do
          token when is_binary(token) and token != "" -> {:token, token}
          _ -> nil
        end
    end
  end

  @spec independent_github_reviewer?() :: boolean()
  def independent_github_reviewer? do
    builder_identity = github_identity(:builder)
    reviewer_identity = github_identity(:reviewer)

    not is_nil(reviewer_identity) and reviewer_identity != builder_identity
  end

  defp github_identity(role) do
    case github_auth(role) do
      {:app, %{app_id: app_id, installation_id: installation_id}} -> {:app, app_id, installation_id}
      {:token, token} -> {:token, token}
      nil -> nil
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: Schema.resolve_thread_sandbox(settings, opts),
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    case validate_tracker_kind(settings.tracker) do
      :ok -> validate_tracker_settings(settings)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tracker_settings(%{tracker: %{kind: "linear"} = tracker}), do: validate_linear_tracker(tracker)
  defp validate_tracker_settings(%{tracker: %{kind: "github"} = tracker} = settings), do: validate_github_tracker(settings, tracker)
  defp validate_tracker_settings(_settings), do: :ok

  defp validate_tracker_kind(%{kind: nil}), do: {:error, :missing_tracker_kind}

  defp validate_tracker_kind(%{kind: kind}) when kind not in ["linear", "memory", "github"],
    do: {:error, {:unsupported_tracker_kind, kind}}

  defp validate_tracker_kind(_tracker), do: :ok

  defp validate_linear_tracker(%{kind: "linear", api_key: api_key}) when not is_binary(api_key),
    do: {:error, :missing_linear_api_token}

  defp validate_linear_tracker(%{kind: "linear", project_slug: project_slug}) when not is_binary(project_slug),
    do: {:error, :missing_linear_project_slug}

  defp validate_linear_tracker(_tracker), do: :ok

  defp validate_github_tracker(%{repos: [_ | _]}, _tracker), do: :ok
  defp validate_github_tracker(_settings, %{owner: owner}) when not is_binary(owner), do: {:error, :missing_github_owner}
  defp validate_github_tracker(_settings, %{repo: repo}) when not is_binary(repo), do: {:error, :missing_github_repo}
  defp validate_github_tracker(_settings, _tracker), do: :ok

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
