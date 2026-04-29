defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Storage}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: Enum.count(snapshot.running, &(Map.get(&1, :session_state) != :parked)),
            parked: Enum.count(snapshot.running, &(Map.get(&1, :session_state) == :parked)),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          issue_sessions: Storage.list_issue_sessions(),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          repos: repos_payload(),
          issues: Storage.list_issues(),
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
    Storage.list_issues()
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

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

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
