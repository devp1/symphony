defmodule SymphonyElixir.Storage do
  @moduledoc """
  Local SQLite-backed ledger for Symphony cockpit state.

  GitHub remains the source of truth for issues and pull requests. This store is
  Symphony's durable run ledger: snapshots, run attempts, events, artifacts, and
  Codex session telemetry.
  """

  use GenServer

  alias SymphonyElixir.Config

  @schema_version 1

  @type repo_attrs :: %{
          optional(:id) => String.t(),
          optional(:owner) => String.t(),
          optional(:name) => String.t(),
          optional(:clone_url) => String.t(),
          optional(:workspace_root) => String.t(),
          optional(:labels) => map()
        }

  @type issue_attrs :: %{
          optional(:repo_id) => String.t(),
          optional(:number) => integer(),
          optional(:identifier) => String.t(),
          optional(:title) => String.t(),
          optional(:state) => String.t(),
          optional(:url) => String.t(),
          optional(:labels) => [String.t()],
          optional(:pr_url) => String.t() | nil,
          optional(:head_sha) => String.t() | nil,
          optional(:pr_state) => String.t() | nil,
          optional(:check_state) => String.t() | nil,
          optional(:review_state) => String.t() | nil
        }

  @type run_attrs :: %{
          optional(:repo_id) => String.t(),
          optional(:issue_number) => integer(),
          optional(:issue_identifier) => String.t(),
          optional(:issue_session_id) => String.t() | nil,
          optional(:state) => String.t(),
          optional(:workspace_path) => String.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:turn_count) => integer() | nil,
          optional(:session_state) => String.t() | nil,
          optional(:health) => [String.t()] | map() | nil,
          optional(:pr_url) => String.t() | nil,
          optional(:pr_state) => String.t() | nil,
          optional(:check_state) => String.t() | nil,
          optional(:review_state) => String.t() | nil,
          optional(:error) => String.t() | nil
        }

  @type issue_session_attrs :: %{
          optional(:id) => String.t(),
          optional(:repo_id) => String.t(),
          optional(:issue_number) => integer(),
          optional(:issue_identifier) => String.t(),
          optional(:workspace_path) => String.t() | nil,
          optional(:codex_thread_id) => String.t() | nil,
          optional(:app_server_pid) => String.t() | nil,
          optional(:state) => String.t(),
          optional(:current_run_id) => String.t() | nil,
          optional(:health) => [String.t()] | map() | nil,
          optional(:parked_at) => String.t() | nil,
          optional(:stop_reason) => String.t() | nil
        }

  @type evidence_bundle_attrs :: %{
          optional(:id) => String.t(),
          optional(:run_id) => String.t(),
          optional(:issue_session_id) => String.t() | nil,
          optional(:issue_identifier) => String.t() | nil,
          optional(:workspace_path) => String.t() | nil,
          optional(:manifest_path) => String.t() | nil,
          optional(:required) => boolean(),
          optional(:status) => String.t(),
          optional(:reason) => String.t() | nil,
          optional(:verdict) => String.t() | nil,
          optional(:summary) => String.t() | nil
        }

  @type evidence_review_attrs :: %{
          optional(:id) => String.t(),
          optional(:bundle_id) => String.t(),
          optional(:run_id) => String.t(),
          optional(:issue_session_id) => String.t() | nil,
          optional(:attempt) => integer(),
          optional(:agent_kind) => String.t(),
          optional(:session_id) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:verdict) => String.t(),
          optional(:summary) => String.t() | nil,
          optional(:feedback) => term(),
          optional(:output_path) => String.t() | nil
        }

  @type autonomous_review_attrs :: %{
          optional(:id) => String.t(),
          optional(:run_id) => String.t() | nil,
          optional(:issue_session_id) => String.t() | nil,
          optional(:repo_id) => String.t() | nil,
          optional(:issue_number) => integer() | nil,
          optional(:issue_identifier) => String.t() | nil,
          optional(:pr_url) => String.t() | nil,
          optional(:head_sha) => String.t() | nil,
          optional(:reviewer_kind) => String.t(),
          optional(:verdict) => String.t(),
          optional(:summary) => String.t() | nil,
          optional(:findings) => term(),
          optional(:check_name) => String.t() | nil,
          optional(:check_conclusion) => String.t() | nil,
          optional(:stale) => boolean(),
          optional(:output_path) => String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec sqlite_path() :: String.t()
  def sqlite_path do
    case Application.get_env(:symphony_elixir, :storage_sqlite_path) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.expand(Config.settings!().storage.sqlite_path)
    end
  end

  @spec upsert_repo(repo_attrs()) :: :ok | {:error, term()}
  def upsert_repo(attrs), do: call_or_direct({:upsert_repo, attrs})

  @spec record_issue_snapshot(issue_attrs()) :: :ok | {:error, term()}
  def record_issue_snapshot(attrs), do: call_or_direct({:record_issue_snapshot, attrs})

  @spec start_run(run_attrs()) :: {:ok, String.t()} | {:error, term()}
  def start_run(attrs), do: call_or_direct({:start_run, attrs})

  @spec update_run(String.t() | nil, run_attrs()) :: :ok | {:error, term()}
  def update_run(nil, _attrs), do: :ok
  def update_run(run_id, attrs), do: call_or_direct({:update_run, run_id, attrs})

  @spec start_issue_session(issue_session_attrs()) :: {:ok, String.t()} | {:error, term()}
  def start_issue_session(attrs), do: call_or_direct({:start_issue_session, attrs})

  @spec update_issue_session(String.t() | nil, issue_session_attrs()) :: :ok | {:error, term()}
  def update_issue_session(nil, _attrs), do: :ok
  def update_issue_session(session_id, attrs), do: call_or_direct({:update_issue_session, session_id, attrs})

  @spec interrupt_running_runs() :: {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_running_runs do
    interrupt_running_runs("interrupted on Symphony startup")
  end

  @spec interrupt_running_runs(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_running_runs(reason) when is_binary(reason), do: call_or_direct({:interrupt_running_runs, reason})

  @spec interrupt_running_issue_sessions(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_running_issue_sessions(reason) when is_binary(reason),
    do: call_or_direct({:interrupt_running_issue_sessions, reason})

  @spec append_event(String.t() | nil, String.t(), String.t()) :: :ok | {:error, term()}
  def append_event(run_id, level, message), do: append_event(run_id, level, message, nil)

  @spec append_event(String.t() | nil, String.t(), String.t(), term()) :: :ok | {:error, term()}
  def append_event(nil, _level, _message, _data), do: :ok

  def append_event(run_id, level, message, data) do
    call_or_direct({:append_event, run_id, level, message, data})
  end

  @spec put_artifact(String.t(), map()) :: :ok | {:error, term()}
  def put_artifact(run_id, attrs), do: call_or_direct({:put_artifact, run_id, attrs})

  @spec upsert_evidence_bundle(evidence_bundle_attrs()) :: {:ok, String.t()} | {:error, term()}
  def upsert_evidence_bundle(attrs), do: call_or_direct({:upsert_evidence_bundle, attrs})

  @spec record_evidence_review(evidence_review_attrs()) :: {:ok, String.t()} | {:error, term()}
  def record_evidence_review(attrs), do: call_or_direct({:record_evidence_review, attrs})

  @spec record_autonomous_review(autonomous_review_attrs()) :: {:ok, String.t()} | {:error, term()}
  def record_autonomous_review(attrs), do: call_or_direct({:record_autonomous_review, attrs})

  @spec list_evidence_bundles(non_neg_integer()) :: [map()]
  def list_evidence_bundles(limit \\ 50) when is_integer(limit) and limit >= 0 do
    query_json("""
    select *
    from evidence_bundles
    order by updated_at desc
    limit #{limit}
    """)
  end

  @spec list_evidence_reviews(non_neg_integer()) :: [map()]
  def list_evidence_reviews(limit \\ 100) when is_integer(limit) and limit >= 0 do
    query_json("""
    select *
    from evidence_reviews
    order by created_at desc
    limit #{limit}
    """)
  end

  @spec evidence_reviews_for_run(String.t()) :: [map()]
  def evidence_reviews_for_run(run_id) when is_binary(run_id) do
    query_json("""
    select *
    from evidence_reviews
    where run_id = #{sql_quote(run_id)}
    order by attempt, created_at, id
    """)
  end

  @spec list_autonomous_reviews(non_neg_integer()) :: [map()]
  def list_autonomous_reviews(limit \\ 100) when is_integer(limit) and limit >= 0 do
    query_json("""
    select *
    from autonomous_reviews
    order by created_at desc
    limit #{limit}
    """)
  end

  @spec list_repos() :: [map()]
  def list_repos, do: query_json("select * from repos order by id")

  @spec list_issues() :: [map()]
  def list_issues do
    query_json("""
    select *
    from issue_snapshots
    order by repo_id, number
    """)
  end

  @spec list_runs(non_neg_integer()) :: [map()]
  def list_runs(limit \\ 50) when is_integer(limit) and limit >= 0 do
    query_json("""
    select *
    from runs
    order by updated_at desc
    limit #{limit}
    """)
  end

  @spec list_issue_sessions() :: [map()]
  def list_issue_sessions do
    query_json("""
    select *
    from issue_sessions
    order by updated_at desc
    """)
  end

  @spec get_run(String.t()) :: map() | nil
  def get_run(run_id) when is_binary(run_id) do
    case query_json("select * from runs where id = #{sql_quote(run_id)} limit 1") do
      [run] ->
        run
        |> Map.put("events", run_events(run_id))
        |> Map.put("artifacts", run_artifacts(run_id))
        |> Map.put("evidence_bundles", run_evidence_bundles(run_id))
        |> Map.put("evidence_reviews", run_evidence_reviews(run_id))
        |> Map.put("autonomous_reviews", run_autonomous_reviews(run_id))

      _ ->
        nil
    end
  end

  @impl true
  def init(_opts) do
    path = sqlite_path()
    File.mkdir_p!(Path.dirname(path))

    case migrate(path) do
      :ok -> {:ok, %{path: path}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:upsert_repo, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_upsert_repo(path, attrs), state}
  end

  def handle_call({:record_issue_snapshot, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_record_issue_snapshot(path, attrs), state}
  end

  def handle_call({:start_run, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_start_run(path, attrs), state}
  end

  def handle_call({:update_run, run_id, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_update_run(path, run_id, attrs), state}
  end

  def handle_call({:start_issue_session, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_start_issue_session(path, attrs), state}
  end

  def handle_call({:update_issue_session, session_id, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_update_issue_session(path, session_id, attrs), state}
  end

  def handle_call({:interrupt_running_runs, reason}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_interrupt_running_runs(path, reason), state}
  end

  def handle_call({:interrupt_running_issue_sessions, reason}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_interrupt_running_issue_sessions(path, reason), state}
  end

  def handle_call({:append_event, run_id, level, message, data}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_append_event(path, run_id, level, message, data), state}
  end

  def handle_call({:put_artifact, run_id, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_put_artifact(path, run_id, attrs), state}
  end

  def handle_call({:upsert_evidence_bundle, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_upsert_evidence_bundle(path, attrs), state}
  end

  def handle_call({:record_evidence_review, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_record_evidence_review(path, attrs), state}
  end

  def handle_call({:record_autonomous_review, attrs}, _from, state) do
    path = sqlite_path()
    _ = migrate(path)
    {:reply, do_record_autonomous_review(path, attrs), state}
  end

  defp call_or_direct(message) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, message)
      _ -> direct(message)
    end
  end

  defp direct(message) do
    path = sqlite_path()

    with :ok <- migrate(path) do
      direct(path, message)
    end
  end

  defp direct(path, {:upsert_repo, attrs}), do: do_upsert_repo(path, attrs)
  defp direct(path, {:record_issue_snapshot, attrs}), do: do_record_issue_snapshot(path, attrs)
  defp direct(path, {:start_run, attrs}), do: do_start_run(path, attrs)
  defp direct(path, {:update_run, run_id, attrs}), do: do_update_run(path, run_id, attrs)
  defp direct(path, {:start_issue_session, attrs}), do: do_start_issue_session(path, attrs)
  defp direct(path, {:update_issue_session, session_id, attrs}), do: do_update_issue_session(path, session_id, attrs)
  defp direct(path, {:interrupt_running_runs, reason}), do: do_interrupt_running_runs(path, reason)

  defp direct(path, {:interrupt_running_issue_sessions, reason}),
    do: do_interrupt_running_issue_sessions(path, reason)

  defp direct(path, {:append_event, run_id, level, message, data}), do: do_append_event(path, run_id, level, message, data)
  defp direct(path, {:put_artifact, run_id, attrs}), do: do_put_artifact(path, run_id, attrs)
  defp direct(path, {:upsert_evidence_bundle, attrs}), do: do_upsert_evidence_bundle(path, attrs)
  defp direct(path, {:record_evidence_review, attrs}), do: do_record_evidence_review(path, attrs)
  defp direct(path, {:record_autonomous_review, attrs}), do: do_record_autonomous_review(path, attrs)

  defp migrate(path) do
    sql = """
    pragma journal_mode = wal;
    create table if not exists schema_migrations (version integer primary key);
    insert or ignore into schema_migrations(version) values (#{@schema_version});
    create table if not exists repos (
      id text primary key,
      owner text not null,
      name text not null,
      clone_url text,
      workspace_root text,
      labels_json text not null,
      updated_at text not null
    );
    create table if not exists issue_snapshots (
      repo_id text not null,
      number integer not null,
      identifier text not null,
      title text,
      state text,
      url text,
      labels_json text not null,
      pr_url text,
      head_sha text,
      pr_state text,
      check_state text,
      review_state text,
      updated_at text not null,
      primary key (repo_id, number)
    );
    create table if not exists runs (
      id text primary key,
      repo_id text,
      issue_number integer,
      issue_identifier text,
      issue_session_id text,
      state text not null,
      workspace_path text,
      session_id text,
      thread_id text,
      turn_count integer,
      session_state text,
      health_json text,
      pr_url text,
      pr_state text,
      check_state text,
      review_state text,
      error text,
      created_at text not null,
      updated_at text not null
    );
    create table if not exists issue_sessions (
      id text primary key,
      repo_id text,
      issue_number integer,
      issue_identifier text,
      workspace_path text,
      codex_thread_id text,
      app_server_pid text,
      state text not null,
      current_run_id text,
      health_json text,
      parked_at text,
      stop_reason text,
      created_at text not null,
      updated_at text not null
    );
    create table if not exists run_events (
      id integer primary key autoincrement,
      run_id text not null,
      level text not null,
      message text not null,
      data_json text,
      inserted_at text not null
    );
    create table if not exists artifacts (
      id text primary key,
      run_id text not null,
      kind text not null,
      path text not null,
      label text,
      content_type text,
      bytes integer,
      created_at text not null
    );
    create table if not exists evidence_bundles (
      id text primary key,
      run_id text not null,
      issue_session_id text,
      issue_identifier text,
      workspace_path text,
      manifest_path text,
      required integer not null,
      status text not null,
      reason text,
      verdict text,
      summary text,
      created_at text not null,
      updated_at text not null
    );
    create table if not exists evidence_reviews (
      id text primary key,
      bundle_id text not null,
      run_id text not null,
      issue_session_id text,
      attempt integer not null,
      agent_kind text not null,
      session_id text,
      thread_id text,
      verdict text not null,
      summary text,
      feedback_json text,
      output_path text,
      created_at text not null
    );
    create table if not exists autonomous_reviews (
      id text primary key,
      run_id text,
      issue_session_id text,
      repo_id text,
      issue_number integer,
      issue_identifier text,
      pr_url text,
      head_sha text,
      reviewer_kind text not null,
      verdict text not null,
      summary text,
      findings_json text,
      check_name text,
      check_conclusion text,
      stale integer not null,
      output_path text,
      created_at text not null
    );
    """

    with :ok <- exec(path, sql),
         :ok <- ensure_column(path, "runs", "issue_session_id", "text"),
         :ok <- ensure_column(path, "runs", "thread_id", "text"),
         :ok <- ensure_column(path, "runs", "turn_count", "integer"),
         :ok <- ensure_column(path, "runs", "session_state", "text"),
         :ok <- ensure_column(path, "runs", "health_json", "text"),
         :ok <- ensure_column(path, "runs", "pr_state", "text"),
         :ok <- ensure_column(path, "runs", "check_state", "text"),
         :ok <- ensure_column(path, "runs", "review_state", "text"),
         :ok <- ensure_column(path, "issue_snapshots", "pr_state", "text"),
         :ok <- ensure_column(path, "issue_snapshots", "check_state", "text"),
         :ok <- ensure_column(path, "issue_snapshots", "review_state", "text") do
      :ok
    end
  end

  defp do_upsert_repo(path, attrs) do
    now = timestamp()
    id = required(attrs, :id)

    exec(path, """
    insert into repos(id, owner, name, clone_url, workspace_root, labels_json, updated_at)
    values (#{sql_quote(id)}, #{sql_quote(required(attrs, :owner))}, #{sql_quote(required(attrs, :name))}, #{sql_quote(attrs[:clone_url])}, #{sql_quote(attrs[:workspace_root])}, #{json(attrs[:labels] || %{})}, #{sql_quote(now)})
    on conflict(id) do update set
      owner = excluded.owner,
      name = excluded.name,
      clone_url = excluded.clone_url,
      workspace_root = excluded.workspace_root,
      labels_json = excluded.labels_json,
      updated_at = excluded.updated_at;
    """)
  end

  defp do_record_issue_snapshot(path, attrs) do
    now = timestamp()

    exec(path, """
    insert into issue_snapshots(repo_id, number, identifier, title, state, url, labels_json, pr_url, head_sha, pr_state, check_state, review_state, updated_at)
    values (#{sql_quote(required(attrs, :repo_id))}, #{integer(required(attrs, :number))}, #{sql_quote(required(attrs, :identifier))}, #{sql_quote(attrs[:title])}, #{sql_quote(attrs[:state])}, #{sql_quote(attrs[:url])}, #{json(attrs[:labels] || [])}, #{sql_quote(attrs[:pr_url])}, #{sql_quote(attrs[:head_sha])}, #{sql_quote(attrs[:pr_state])}, #{sql_quote(attrs[:check_state])}, #{sql_quote(attrs[:review_state])}, #{sql_quote(now)})
    on conflict(repo_id, number) do update set
      identifier = excluded.identifier,
      title = excluded.title,
      state = excluded.state,
      url = excluded.url,
      labels_json = excluded.labels_json,
      pr_url = excluded.pr_url,
      head_sha = excluded.head_sha,
      pr_state = excluded.pr_state,
      check_state = excluded.check_state,
      review_state = excluded.review_state,
      updated_at = excluded.updated_at;
    """)
  end

  defp do_start_run(path, attrs) do
    now = timestamp()
    run_id = attrs[:id] || "run-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    case exec(path, """
         insert into runs(id, repo_id, issue_number, issue_identifier, issue_session_id, state, workspace_path, session_id, thread_id, turn_count, session_state, health_json, pr_url, pr_state, check_state, review_state, error, created_at, updated_at)
         values (#{sql_quote(run_id)}, #{sql_quote(attrs[:repo_id])}, #{integer(attrs[:issue_number])}, #{sql_quote(attrs[:issue_identifier])}, #{sql_quote(attrs[:issue_session_id])}, #{sql_quote(attrs[:state] || "queued")}, #{sql_quote(attrs[:workspace_path])}, #{sql_quote(attrs[:session_id])}, #{sql_quote(attrs[:thread_id])}, #{integer(attrs[:turn_count])}, #{sql_quote(attrs[:session_state])}, #{json(attrs[:health] || [])}, #{sql_quote(attrs[:pr_url])}, #{sql_quote(attrs[:pr_state])}, #{sql_quote(attrs[:check_state])}, #{sql_quote(attrs[:review_state])}, #{sql_quote(attrs[:error])}, #{sql_quote(now)}, #{sql_quote(now)});
         """) do
      :ok -> {:ok, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_update_run(path, run_id, attrs) do
    assignments =
      attrs
      |> Map.take([
        :state,
        :workspace_path,
        :session_id,
        :issue_session_id,
        :thread_id,
        :turn_count,
        :session_state,
        :health,
        :pr_url,
        :pr_state,
        :check_state,
        :review_state,
        :error
      ])
      |> Enum.map(&run_assignment/1)

    case assignments do
      [] ->
        :ok

      assignments ->
        exec(path, "update runs set #{Enum.join(assignments, ", ")}, updated_at = #{sql_quote(timestamp())} where id = #{sql_quote(run_id)};")
    end
  end

  defp do_start_issue_session(path, attrs) do
    now = timestamp()
    session_id = attrs[:id] || "issue-session-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    case exec(path, """
         insert into issue_sessions(id, repo_id, issue_number, issue_identifier, workspace_path, codex_thread_id, app_server_pid, state, current_run_id, health_json, parked_at, stop_reason, created_at, updated_at)
         values (#{sql_quote(session_id)}, #{sql_quote(attrs[:repo_id])}, #{integer(attrs[:issue_number])}, #{sql_quote(attrs[:issue_identifier])}, #{sql_quote(attrs[:workspace_path])}, #{sql_quote(attrs[:codex_thread_id])}, #{sql_quote(attrs[:app_server_pid])}, #{sql_quote(attrs[:state] || "starting")}, #{sql_quote(attrs[:current_run_id])}, #{json(attrs[:health] || ["healthy"])}, #{sql_quote(attrs[:parked_at])}, #{sql_quote(attrs[:stop_reason])}, #{sql_quote(now)}, #{sql_quote(now)});
         """) do
      :ok -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_update_issue_session(path, session_id, attrs) do
    assignments =
      attrs
      |> Map.take([
        :workspace_path,
        :codex_thread_id,
        :app_server_pid,
        :state,
        :current_run_id,
        :health,
        :parked_at,
        :stop_reason
      ])
      |> Enum.map(&issue_session_assignment/1)

    case assignments do
      [] ->
        :ok

      assignments ->
        exec(
          path,
          "update issue_sessions set #{Enum.join(assignments, ", ")}, updated_at = #{sql_quote(timestamp())} where id = #{sql_quote(session_id)};"
        )
    end
  end

  defp do_interrupt_running_runs(path, reason) when is_binary(reason) do
    run_ids =
      path
      |> query_json_at_path("select id from runs where state = 'running' order by created_at;")
      |> Enum.flat_map(fn
        %{"id" => id} when is_binary(id) -> [id]
        _ -> []
      end)

    case run_ids do
      [] ->
        {:ok, 0}

      [_ | _] ->
        now = timestamp()

        case exec(
               path,
               "update runs set state = 'cancelled', error = #{sql_quote(reason)}, updated_at = #{sql_quote(now)} where state = 'running';"
             ) do
          :ok ->
            Enum.each(run_ids, fn run_id ->
              _ =
                do_append_event(path, run_id, "warning", "startup recovery marked run interrupted", %{
                  reason: reason
                })
            end)

            {:ok, length(run_ids)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_interrupt_running_issue_sessions(path, reason) when is_binary(reason) do
    session_ids =
      path
      |> query_json_at_path("select id from issue_sessions where state in ('starting', 'running') order by created_at;")
      |> Enum.flat_map(fn
        %{"id" => id} when is_binary(id) -> [id]
        _ -> []
      end)

    case session_ids do
      [] ->
        {:ok, 0}

      [_ | _] ->
        now = timestamp()

        case exec(
               path,
               "update issue_sessions set state = 'interrupted-resumable', stop_reason = #{sql_quote(reason)}, health_json = #{json(["interrupted-resumable"])}, app_server_pid = null, updated_at = #{sql_quote(now)} where state in ('starting', 'running');"
             ) do
          :ok -> {:ok, length(session_ids)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_append_event(path, run_id, level, message, data) do
    exec(path, """
    insert into run_events(run_id, level, message, data_json, inserted_at)
    values (#{sql_quote(run_id)}, #{sql_quote(level)}, #{sql_quote(message)}, #{json(data)}, #{sql_quote(timestamp())});
    """)
  end

  defp do_put_artifact(path, run_id, attrs) do
    id = attrs[:id] || "artifact-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    exec(path, """
    insert into artifacts(id, run_id, kind, path, label, content_type, bytes, created_at)
    values (#{sql_quote(id)}, #{sql_quote(run_id)}, #{sql_quote(attrs[:kind] || "other")}, #{sql_quote(required(attrs, :path))}, #{sql_quote(attrs[:label])}, #{sql_quote(attrs[:content_type])}, #{integer(attrs[:bytes])}, #{sql_quote(timestamp())});
    """)
  end

  defp do_upsert_evidence_bundle(path, attrs) do
    now = timestamp()
    id = attrs[:id] || "evidence-bundle-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    case exec(path, """
         insert into evidence_bundles(id, run_id, issue_session_id, issue_identifier, workspace_path, manifest_path, required, status, reason, verdict, summary, created_at, updated_at)
         values (#{sql_quote(id)}, #{sql_quote(required(attrs, :run_id))}, #{sql_quote(attrs[:issue_session_id])}, #{sql_quote(attrs[:issue_identifier])}, #{sql_quote(attrs[:workspace_path])}, #{sql_quote(attrs[:manifest_path])}, #{boolean_integer(attrs[:required])}, #{sql_quote(attrs[:status] || "pending")}, #{sql_quote(attrs[:reason])}, #{sql_quote(attrs[:verdict])}, #{sql_quote(attrs[:summary])}, #{sql_quote(now)}, #{sql_quote(now)})
         on conflict(id) do update set
           issue_session_id = excluded.issue_session_id,
           issue_identifier = excluded.issue_identifier,
           workspace_path = excluded.workspace_path,
           manifest_path = excluded.manifest_path,
           required = excluded.required,
           status = excluded.status,
           reason = excluded.reason,
           verdict = excluded.verdict,
           summary = excluded.summary,
           updated_at = excluded.updated_at;
         """) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_record_evidence_review(path, attrs) do
    id = attrs[:id] || "evidence-review-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    case exec(path, """
         insert into evidence_reviews(id, bundle_id, run_id, issue_session_id, attempt, agent_kind, session_id, thread_id, verdict, summary, feedback_json, output_path, created_at)
         values (#{sql_quote(id)}, #{sql_quote(required(attrs, :bundle_id))}, #{sql_quote(required(attrs, :run_id))}, #{sql_quote(attrs[:issue_session_id])}, #{integer(attrs[:attempt] || 1)}, #{sql_quote(attrs[:agent_kind] || "review-agent")}, #{sql_quote(attrs[:session_id])}, #{sql_quote(attrs[:thread_id])}, #{sql_quote(attrs[:verdict] || "fail")}, #{sql_quote(attrs[:summary])}, #{json(attrs[:feedback] || %{})}, #{sql_quote(attrs[:output_path])}, #{sql_quote(timestamp())});
         """) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_record_autonomous_review(path, attrs) do
    id = attrs[:id] || "autonomous-review-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    case exec(path, """
         insert into autonomous_reviews(id, run_id, issue_session_id, repo_id, issue_number, issue_identifier, pr_url, head_sha, reviewer_kind, verdict, summary, findings_json, check_name, check_conclusion, stale, output_path, created_at)
         values (#{sql_quote(id)}, #{sql_quote(attrs[:run_id])}, #{sql_quote(attrs[:issue_session_id])}, #{sql_quote(attrs[:repo_id])}, #{integer(attrs[:issue_number])}, #{sql_quote(attrs[:issue_identifier])}, #{sql_quote(attrs[:pr_url])}, #{sql_quote(attrs[:head_sha])}, #{sql_quote(attrs[:reviewer_kind] || "review-agent")}, #{sql_quote(attrs[:verdict] || "needs_input")}, #{sql_quote(attrs[:summary])}, #{json(attrs[:findings] || [])}, #{sql_quote(attrs[:check_name])}, #{sql_quote(attrs[:check_conclusion])}, #{boolean_integer(attrs[:stale])}, #{sql_quote(attrs[:output_path])}, #{sql_quote(timestamp())});
         """) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_events(run_id) do
    query_json("""
    select *
    from run_events
    where run_id = #{sql_quote(run_id)}
    order by id
    """)
  end

  defp run_artifacts(run_id) do
    query_json("""
    select *
    from artifacts
    where run_id = #{sql_quote(run_id)}
    order by created_at, id
    """)
  end

  defp run_evidence_bundles(run_id) do
    query_json("""
    select *
    from evidence_bundles
    where run_id = #{sql_quote(run_id)}
    order by updated_at, id
    """)
  end

  defp run_evidence_reviews(run_id) do
    query_json("""
    select *
    from evidence_reviews
    where run_id = #{sql_quote(run_id)}
    order by attempt, created_at, id
    """)
  end

  defp run_autonomous_reviews(run_id) do
    query_json("""
    select *
    from autonomous_reviews
    where run_id = #{sql_quote(run_id)}
    order by created_at, id
    """)
  end

  defp query_json(sql) do
    path = sqlite_path()
    _ = migrate(path)

    query_json_at_path(path, sql)
  end

  defp query_json_at_path(path, sql) do
    case System.cmd("sqlite3", ["-json", path, sql], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, rows} when is_list(rows) -> Enum.map(rows, &decode_json_columns/1)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp ensure_column(path, table, column, type) do
    column_exists? =
      path
      |> query_json_at_path("pragma table_info(#{table});")
      |> Enum.any?(fn
        %{"name" => ^column} -> true
        _ -> false
      end)

    if column_exists? do
      :ok
    else
      exec(path, "alter table #{table} add column #{column} #{type};")
    end
  end

  defp run_assignment({:health, value}), do: "health_json = #{json(value || [])}"
  defp run_assignment({:turn_count, value}), do: "turn_count = #{integer(value)}"
  defp run_assignment({key, value}), do: "#{key} = #{sql_quote(value)}"

  defp issue_session_assignment({:health, value}), do: "health_json = #{json(value || [])}"
  defp issue_session_assignment({key, value}), do: "#{key} = #{sql_quote(value)}"

  defp exec(path, sql) do
    File.mkdir_p!(Path.dirname(path))

    case System.cmd("sqlite3", [path, sql], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:sqlite_failed, status, String.trim(output)}}
    end
  end

  defp decode_json_columns(row) when is_map(row) do
    Enum.reduce(row, %{}, fn {key, value}, acc ->
      if String.ends_with?(key, "_json") do
        Map.put(acc, String.replace_suffix(key, "_json", ""), decode_json_value(value))
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp decode_json_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_json_value(value), do: value

  defp required(attrs, key) do
    Map.fetch!(attrs, key)
  end

  defp sql_quote(nil), do: "null"
  defp sql_quote(value) when is_binary(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp sql_quote(value), do: sql_quote(to_string(value))

  defp json(value), do: sql_quote(Jason.encode!(value))

  defp integer(nil), do: "null"
  defp integer(value) when is_integer(value), do: Integer.to_string(value)
  defp integer(value), do: value |> to_string() |> String.to_integer() |> Integer.to_string()

  defp boolean_integer(true), do: "1"
  defp boolean_integer(false), do: "0"
  defp boolean_integer(_value), do: "0"

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
