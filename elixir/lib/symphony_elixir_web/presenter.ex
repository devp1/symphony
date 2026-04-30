defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{AutonomousReview, Config, Orchestrator, StatusDashboard, Storage, Workflow}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        active_running = Enum.reject(snapshot.running, &parked_entry?/1)
        parked = Enum.filter(snapshot.running, &parked_entry?/1)
        autonomous_reviews = Storage.list_autonomous_reviews(100)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(active_running),
            parked: length(parked),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(active_running, &running_entry_payload/1),
          parked: Enum.map(parked, &running_entry_payload/1),
          issue_sessions: Storage.list_issue_sessions(),
          evidence_bundles: Storage.list_evidence_bundles(50),
          evidence_reviews: Storage.list_evidence_reviews(100),
          autonomous_reviews: autonomous_reviews,
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          repos: repos_payload(),
          issues: issues_payload(autonomous_reviews),
          runs: Storage.list_runs(50),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec readiness_payload(GenServer.name(), timeout()) :: {200 | 503, map()}
  def readiness_payload(orchestrator, snapshot_timeout_ms) do
    checks = %{
      workflow_loaded: workflow_loaded?(),
      sqlite_reachable: sqlite_reachable?(),
      repos_configured: Config.repos() != [],
      builder_auth_present: not is_nil(Config.github_auth(:builder)),
      reviewer_auth_independent: Config.independent_github_reviewer?(),
      orchestrator_available: orchestrator_available?(orchestrator, snapshot_timeout_ms),
      server_active: true
    }

    ready = checks |> Map.values() |> Enum.all?(&(&1 == true))
    status = if ready, do: 200, else: 503

    {status,
     %{
       ready: ready,
       generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       checks: checks,
       repos: Enum.map(Config.repos(), & &1.id)
     }}
  end

  @spec repos_payload() :: [map()]
  def repos_payload do
    Config.repos()
    |> Enum.map(fn repo ->
      %{
        id: repo.id,
        owner: repo.owner,
        name: repo.name,
        clone_url: repo.clone_url,
        workspace_root: repo.workspace_root,
        labels: repo.labels
      }
    end)
  end

  @spec issues_payload() :: [map()]
  def issues_payload do
    issues_payload(Storage.list_autonomous_reviews(100))
  end

  defp issues_payload(autonomous_reviews) when is_list(autonomous_reviews) do
    latest_reviews = latest_autonomous_reviews_by_issue(autonomous_reviews)
    latest_merge_audits = latest_merge_audits_by_issue(Storage.list_runs(250))

    Storage.list_issues()
    |> Enum.map(fn issue_snapshot ->
      issue_snapshot
      |> put_merge_gate(latest_reviews)
      |> put_merge_audit(latest_merge_audits)
    end)
  end

  @spec run_payload(String.t()) :: {:ok, map()} | {:error, :run_not_found}
  def run_payload(run_id) when is_binary(run_id) do
    case Storage.get_run(run_id) do
      %{} = run -> {:ok, run}
      _ -> {:error, :run_not_found}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp workflow_loaded? do
    match?({:ok, %{config: config}} when is_map(config), Workflow.current())
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp sqlite_reachable? do
    _ = Storage.list_issues()
    true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp orchestrator_available?(orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} -> true
      _ -> false
    end
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(%{session_state: :parked}, nil), do: "parked"
  defp issue_status(%{session_state: "parked"}, nil), do: "parked"
  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp parked_entry?(entry), do: Map.get(entry, :session_state) in [:parked, "parked"]

  defp latest_autonomous_reviews_by_issue(autonomous_reviews) do
    Enum.reduce(autonomous_reviews, %{}, fn review, acc ->
      case {Map.get(review, "repo_id"), normalize_issue_number(Map.get(review, "issue_number"))} do
        {repo_id, issue_number} when is_binary(repo_id) and is_integer(issue_number) ->
          Map.put_new(acc, {repo_id, issue_number}, review)

        _ ->
          acc
      end
    end)
  end

  defp put_merge_gate(%{} = issue_snapshot, latest_reviews) do
    issue = AutonomousReview.issue_from_snapshot(issue_snapshot)
    review = Map.get(latest_reviews, {issue.repo_id, issue.number})
    gate = AutonomousReview.merge_gate(issue, review)

    Map.put(issue_snapshot, "merge_gate", %{
      "ready" => gate.ready?,
      "reasons" => gate.reasons,
      "review_verdict" => gate.review_verdict,
      "review_stale" => gate.review_stale?,
      "latest_review_id" => review && Map.get(review, "id"),
      "latest_review_head_sha" => review && Map.get(review, "head_sha"),
      "check_state" => Map.get(issue_snapshot, "check_state"),
      "pr_state" => Map.get(issue_snapshot, "pr_state"),
      "review_state" => Map.get(issue_snapshot, "review_state")
    })
  end

  defp put_merge_audit(%{} = issue_snapshot, latest_merge_audits) do
    key = {Map.get(issue_snapshot, "repo_id"), normalize_issue_number(Map.get(issue_snapshot, "number"))}

    case Map.get(latest_merge_audits, key) do
      nil -> issue_snapshot
      audit -> Map.put(issue_snapshot, "merge_audit", audit)
    end
  end

  defp latest_merge_audits_by_issue(runs) do
    Enum.reduce(runs, %{}, fn run, acc ->
      key = {Map.get(run, "repo_id"), normalize_issue_number(Map.get(run, "issue_number"))}

      cond do
        not valid_issue_key?(key) ->
          acc

        Map.has_key?(acc, key) ->
          acc

        audit = merge_audit_from_run(run) ->
          Map.put(acc, key, audit)

        true ->
          acc
      end
    end)
  end

  defp valid_issue_key?({repo_id, issue_number}) when is_binary(repo_id) and is_integer(issue_number), do: true
  defp valid_issue_key?(_key), do: false

  defp merge_audit_from_run(%{"id" => run_id} = run) when is_binary(run_id) do
    case Storage.get_run(run_id) do
      %{} = full_run ->
        full_run
        |> Map.get("events", [])
        |> Enum.reverse()
        |> Enum.find(&(Map.get(&1, "message") == "cockpit merge requested"))
        |> merge_audit_payload(full_run, run)

      _ ->
        nil
    end
  end

  defp merge_audit_from_run(_run), do: nil

  defp merge_audit_payload(nil, _full_run, _run), do: nil

  defp merge_audit_payload(%{} = event, %{} = full_run, %{} = run) do
    data = Map.get(event, "data") || %{}

    %{
      "run_id" => Map.get(full_run, "id") || Map.get(run, "id"),
      "issue_session_id" => Map.get(full_run, "issue_session_id") || Map.get(run, "issue_session_id"),
      "state" => Map.get(full_run, "state") || Map.get(run, "state"),
      "session_state" => Map.get(full_run, "session_state") || Map.get(run, "session_state"),
      "health" => Map.get(full_run, "health") || Map.get(run, "health") || [],
      "event_level" => Map.get(event, "level"),
      "event_message" => Map.get(event, "message"),
      "event_inserted_at" => Map.get(event, "inserted_at"),
      "merge_response" => Map.get(data, "merge_response"),
      "post_merge_update" => Map.get(data, "post_merge_update") || %{}
    }
  end

  defp normalize_issue_number(number) when is_integer(number), do: number

  defp normalize_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_issue_number(_number), do: nil

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      repo_id: Map.get(entry, :repo_id),
      issue_number: Map.get(entry, :issue_number),
      run_id: Map.get(entry, :run_id),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      issue_session_id: Map.get(entry, :issue_session_id),
      session_kind: Map.get(entry, :session_kind),
      session_state: Map.get(entry, :session_state),
      health: Map.get(entry, :health, ["healthy"]),
      thread_id: Map.get(entry, :thread_id),
      pr_url: Map.get(entry, :pr_url),
      pr_state: Map.get(entry, :pr_state),
      check_state: Map.get(entry, :check_state),
      review_state: Map.get(entry, :review_state),
      parked_at: iso8601_or_string(Map.get(entry, :parked_at)),
      stop_reason: Map.get(entry, :stop_reason),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      last_semantic_activity_at: iso8601_or_string(Map.get(entry, :last_semantic_activity_timestamp)),
      last_semantic_activity_reason: Map.get(entry, :last_semantic_activity_reason),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      issue_session_id: Map.get(running, :issue_session_id),
      session_kind: Map.get(running, :session_kind),
      session_state: Map.get(running, :session_state),
      health: Map.get(running, :health, ["healthy"]),
      thread_id: Map.get(running, :thread_id),
      pr_url: Map.get(running, :pr_url),
      pr_state: Map.get(running, :pr_state),
      check_state: Map.get(running, :check_state),
      review_state: Map.get(running, :review_state),
      parked_at: iso8601_or_string(Map.get(running, :parked_at)),
      stop_reason: Map.get(running, :stop_reason),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      last_semantic_activity_at: iso8601_or_string(Map.get(running, :last_semantic_activity_timestamp)),
      last_semantic_activity_reason: Map.get(running, :last_semantic_activity_reason),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp iso8601_or_string(%DateTime{} = datetime), do: iso8601(datetime)
  defp iso8601_or_string(value) when is_binary(value), do: value
  defp iso8601_or_string(_value), do: nil
end
