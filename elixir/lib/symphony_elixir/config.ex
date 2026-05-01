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
  @type agent_provider :: String.t()
  @type agent_phase :: :planner | :executor | :reviewer | String.t()
  @type agent_profile :: %{
          required(:provider) => agent_provider(),
          optional(:model) => String.t(),
          optional(:effort) => String.t(),
          optional(:permission_mode) => String.t(),
          optional(:extra_args) => [String.t()]
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

  @spec agent_provider_for_issue(map() | nil) :: agent_provider()
  def agent_provider_for_issue(issue), do: agent_profile_for_issue(issue, :executor).provider

  @spec agent_provider_for_repo_id(String.t() | nil) :: agent_provider()
  def agent_provider_for_repo_id(repo_id) when is_binary(repo_id) do
    agent_provider_for_issue(%{repo_id: repo_id})
  end

  def agent_provider_for_repo_id(_repo_id), do: settings!().agent.default_provider

  @spec agent_profile_for_issue(map() | nil, agent_phase()) :: agent_profile()
  def agent_profile_for_issue(issue, phase) do
    settings = settings!()
    phase = normalize_agent_phase(phase)

    settings
    |> routed_agent_profile(issue, phase)
    |> merge_agent_profile(default_agent_profile(settings, issue, phase))
  end

  @spec agent_profile_for_repo_id(String.t() | nil, agent_phase()) :: agent_profile()
  def agent_profile_for_repo_id(repo_id, phase) when is_binary(repo_id) do
    agent_profile_for_issue(%{repo_id: repo_id, labels: []}, phase)
  end

  def agent_profile_for_repo_id(_repo_id, phase), do: agent_profile_for_issue(nil, phase)

  defp routed_agent_profile(settings, issue, phase) do
    labels =
      issue
      |> issue_labels()
      |> MapSet.new()

    settings.agent.routes
    |> Enum.find_value(%{}, fn route ->
      route_labels = Map.get(route, "labels", [])

      if route_labels != [] and Enum.all?(route_labels, &MapSet.member?(labels, &1)) do
        route |> Map.get(Atom.to_string(phase), %{}) |> atomize_profile()
      end
    end)
  end

  defp default_agent_profile(settings, issue, phase) do
    profiles = settings.agent.profiles || %{}
    phase_profile = profiles |> Map.get(Atom.to_string(phase), %{}) |> atomize_profile()
    provider = profile_provider(phase_profile) || repo_agent_provider(settings, issue, phase) || settings.agent.default_provider

    phase_profile
    |> Map.put(:provider, provider)
  end

  defp merge_agent_profile(profile, defaults) when is_map(profile) do
    profile
    |> atomize_profile()
    |> Map.merge(defaults, fn _key, value, _default -> value end)
    |> Map.put_new(:provider, defaults.provider)
  end

  defp repo_agent_provider(settings, %{repo_id: repo_id}, :executor) when is_binary(repo_id) do
    settings.repos
    |> Enum.find(&(&1.id == repo_id))
    |> case do
      %{agent_provider: provider} when is_binary(provider) and provider != "" -> provider
      _ -> nil
    end
  end

  defp repo_agent_provider(_settings, _issue, _phase), do: nil

  defp profile_provider(%{provider: provider}) when is_binary(provider) and provider != "", do: provider
  defp profile_provider(_profile), do: nil

  defp atomize_profile(profile) when is_map(profile) do
    Enum.reduce(profile, %{}, fn
      {key, value}, acc when key in [:provider, :model, :effort, :permission_mode, :extra_args] ->
        Map.put(acc, key, value)

      {key, value}, acc when key in ["provider", "model", "effort", "permission_mode", "extra_args"] ->
        Map.put(acc, String.to_existing_atom(key), value)

      {_key, _value}, acc ->
        acc
    end)
  end

  defp atomize_profile(_profile), do: %{}

  defp normalize_agent_phase(phase) when phase in [:planner, :executor, :reviewer], do: phase
  defp normalize_agent_phase("planner"), do: :planner
  defp normalize_agent_phase("executor"), do: :executor
  defp normalize_agent_phase("reviewer"), do: :reviewer
  defp normalize_agent_phase(_phase), do: :executor

  defp issue_labels(%{labels: labels}) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp issue_labels(%{"labels" => labels}) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp issue_labels(_issue), do: []

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
