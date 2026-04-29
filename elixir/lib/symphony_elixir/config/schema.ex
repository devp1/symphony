defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false
  @default_github_labels %{
    "queued" => "agent-ready",
    "running" => "in-progress",
    "human_review" => "human-review",
    "needs_input" => "needs-input",
    "blocked" => "blocked",
    "rework" => "rework",
    "merging" => "merging",
    "managed" => "symphony"
  }

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:owner, :string)
      field(:repo, :string)
      field(:label, :string, default: "symphony")
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :owner, :repo, :label, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule GitHub do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:builder_token, :string)
      field(:reviewer_token, :string)
      field(:review_check_name, :string, default: "symphony/autonomous-review")
      field(:required_check_names, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:builder_token, :reviewer_token, :review_check_name, :required_check_names], empty_values: [])
      |> validate_required([:review_check_name])
      |> update_change(:required_check_names, &normalize_check_names/1)
    end

    defp normalize_check_names(names) when is_list(names) do
      names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    defp normalize_check_names(_names), do: []
  end

  defmodule Repo do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:id, :string)
      field(:owner, :string)
      field(:name, :string)
      field(:clone_url, :string)
      field(:workspace_root, :string)
      field(:labels, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:id, :owner, :name, :clone_url, :workspace_root, :labels], empty_values: [])
      |> validate_required([:owner, :name])
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:artifact_nudge_tokens, :integer, default: 250_000)
      field(:max_artifact_nudges, :integer, default: 1)
      field(:max_tokens_before_first_artifact, :integer, default: 200_000)
      field(:max_tokens_without_artifact, :integer, default: 250_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :artifact_nudge_tokens,
          :max_artifact_nudges,
          :max_tokens_before_first_artifact,
          :max_tokens_without_artifact,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:artifact_nudge_tokens, greater_than_or_equal_to: 0)
      |> validate_number(:max_artifact_nudges, greater_than_or_equal_to: 0)
      |> validate_number(:max_tokens_before_first_artifact, greater_than_or_equal_to: 0)
      |> validate_number(:max_tokens_without_artifact, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:semantic_inactivity_timeout_ms, :integer, default: 1_800_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :semantic_inactivity_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:semantic_inactivity_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Evidence do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:force_labels, {:array, :string}, default: ["evidence-required"])
      field(:skip_labels, {:array, :string}, default: ["evidence-skip"])
      field(:review_gate, :string, default: "blocking")
      field(:max_review_attempts, :integer, default: 2)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :force_labels, :skip_labels, :review_gate, :max_review_attempts], empty_values: [])
      |> validate_inclusion(:review_gate, ["blocking", "advisory", "off"])
      |> validate_number(:max_review_attempts, greater_than: 0)
      |> update_change(:force_labels, &normalize_labels/1)
      |> update_change(:skip_labels, &normalize_labels/1)
    end

    defp normalize_labels(labels) when is_list(labels) do
      labels
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    defp normalize_labels(_labels), do: []
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Storage do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:sqlite_path, :string, default: Path.join([".", "symphony.sqlite3"]))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:sqlite_path], empty_values: [])
    end
  end

  embedded_schema do
    field(:runtime_profile, :string, default: "default")
    embeds_many(:repos, Repo, on_replace: :delete)
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github, GitHub, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:evidence, Evidence, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:storage, Storage, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        runtime_profile_turn_sandbox_policy(settings, workspace, policy)

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy_for_profile(settings, [])
    end
  end

  @spec resolve_thread_sandbox(%__MODULE__{}) :: String.t()
  def resolve_thread_sandbox(settings), do: resolve_thread_sandbox(settings, [])

  @spec resolve_thread_sandbox(%__MODULE__{}, keyword()) :: String.t()
  def resolve_thread_sandbox(%{runtime_profile: "local_trusted", codex: codex}, opts) do
    if Keyword.get(opts, :remote, false) do
      codex.thread_sandbox
    else
      "danger-full-access"
    end
  end

  def resolve_thread_sandbox(%{codex: %{thread_sandbox: thread_sandbox}}, _opts), do: thread_sandbox

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, runtime_profile_turn_sandbox_policy(settings, workspace, policy)}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(settings, opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:runtime_profile])
    |> validate_inclusion(:runtime_profile, ["default", "local_trusted"])
    |> cast_embed(:repos, with: &Repo.changeset/2)
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:github, with: &GitHub.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:evidence, with: &Evidence.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:storage, with: &Storage.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key:
          resolve_secret_setting(
            settings.tracker.api_key,
            System.get_env("LINEAR_API_KEY") || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
          ),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    github = %{
      settings.github
      | builder_token:
          resolve_secret_setting(
            settings.github.builder_token,
            System.get_env("SYMPHONY_GITHUB_BUILDER_TOKEN") || settings.tracker.api_key || System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
          ),
        reviewer_token:
          resolve_secret_setting(
            settings.github.reviewer_token,
            System.get_env("SYMPHONY_GITHUB_REVIEWER_TOKEN")
          )
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    repos =
      settings
      |> configured_repos(tracker, workspace)
      |> Enum.map(&finalize_repo(&1, workspace.root))

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    storage = %{
      settings.storage
      | sqlite_path: resolve_path_value(settings.storage.sqlite_path, Path.join([File.cwd!(), "symphony.sqlite3"]))
    }

    %{settings | repos: repos, tracker: tracker, github: github, workspace: workspace, codex: codex, storage: storage}
  end

  @spec default_github_labels() :: map()
  def default_github_labels, do: @default_github_labels

  defp configured_repos(%{repos: repos}, _tracker, _workspace) when is_list(repos) and repos != [] do
    repos
  end

  defp configured_repos(_settings, %{kind: "github", owner: owner, repo: repo}, _workspace)
       when is_binary(owner) and is_binary(repo) do
    [%Repo{owner: owner, name: repo}]
  end

  defp configured_repos(_settings, _tracker, _workspace), do: []

  defp finalize_repo(%Repo{} = repo, default_workspace_root) do
    owner = String.trim(repo.owner || "")
    name = String.trim(repo.name || "")
    id = repo.id || repo_id(owner, name)

    %{
      repo
      | id: id,
        owner: owner,
        name: name,
        clone_url: repo.clone_url || "https://github.com/#{owner}/#{name}.git",
        workspace_root: resolve_path_value(repo.workspace_root, Path.join(default_workspace_root, id)),
        labels: Map.merge(@default_github_labels, normalize_keys(repo.labels || %{}))
    }
  end

  defp repo_id(owner, name) do
    [owner, name]
    |> Enum.join("/")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim("-")
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_path_value(nil, default), do: default
  defp resolve_path_value("", default), do: default

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_turn_sandbox_policy_for_profile(workspace, %{runtime_profile: "local_trusted"}) do
    workspace
    |> default_turn_sandbox_policy()
    |> Map.put("networkAccess", true)
  end

  defp default_turn_sandbox_policy_for_profile(workspace, _settings), do: default_turn_sandbox_policy(workspace)

  defp default_turn_sandbox_policy_for_profile(workspace, %{runtime_profile: "local_trusted"} = settings, opts) do
    if Keyword.get(opts, :remote, false) do
      default_turn_sandbox_policy_for_profile(workspace, settings)
    else
      %{"type" => "dangerFullAccess"}
    end
  end

  defp default_turn_sandbox_policy_for_profile(workspace, settings, _opts) do
    default_turn_sandbox_policy_for_profile(workspace, settings)
  end

  defp runtime_profile_turn_sandbox_policy(%{runtime_profile: "local_trusted"} = settings, workspace, policy)
       when is_map(policy) do
    if danger_full_access_sandbox_policy?(policy) do
      %{"type" => "dangerFullAccess"}
    else
      trusted_workspace_turn_sandbox_policy(settings, workspace, policy)
    end
  end

  defp runtime_profile_turn_sandbox_policy(_settings, _workspace, policy), do: policy

  defp trusted_workspace_turn_sandbox_policy(settings, workspace, policy) do
    workspace_root =
      workspace
      |> default_workspace_root(settings.workspace.root)
      |> expand_local_workspace_root()

    workspace_root
    |> default_turn_sandbox_policy_for_profile(settings)
    |> Map.merge(policy)
    |> Map.put("networkAccess", true)
    |> Map.update("writableRoots", [workspace_root], fn roots ->
      roots
      |> List.wrap()
      |> Enum.concat([workspace_root])
      |> Enum.uniq()
    end)
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, settings, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy_for_profile(workspace_root, settings, opts)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy_for_profile(canonical_workspace_root, settings, opts)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _settings, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp danger_full_access_sandbox_policy?(%{"type" => "dangerFullAccess"}), do: true
  defp danger_full_access_sandbox_policy?(_policy), do: false

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
