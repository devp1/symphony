defmodule SymphonyElixir.RunLedger do
  @moduledoc """
  Persistence boundary for run and issue-session ledger updates.
  """

  require Logger

  alias SymphonyElixir.{Linear.Issue, StatusDashboard, Storage}

  @type running_entry :: map()
  @type worker_host :: String.t() | nil

  @spec create_issue_session_record(Issue.t()) :: String.t() | nil
  def create_issue_session_record(%Issue{} = issue) do
    attrs = %{
      repo_id: issue.repo_id,
      issue_number: issue.number,
      issue_identifier: issue.identifier,
      state: "starting",
      health: ["healthy"]
    }

    case Storage.start_issue_session(attrs) do
      {:ok, issue_session_id} ->
        issue_session_id

      {:error, reason} ->
        Logger.warning("Failed to persist issue session record for #{issue_context(issue)}: #{inspect(reason)}")
        nil
    end
  end

  @spec create_run_record(Issue.t(), worker_host(), String.t() | nil) :: String.t() | nil
  def create_run_record(%Issue{} = issue, worker_host, issue_session_id \\ nil) do
    attrs =
      %{
        repo_id: issue.repo_id,
        issue_number: issue.number,
        issue_identifier: issue.identifier,
        issue_session_id: issue_session_id,
        state: "running",
        workspace_path: nil,
        session_state: "running",
        health: ["healthy"]
      }
      |> Map.merge(run_pr_metadata_attrs(issue))

    case Storage.start_run(attrs) do
      {:ok, run_id} ->
        Storage.append_event(run_id, "info", "dispatched", %{
          worker_host: worker_host,
          issue_session_id: issue_session_id
        })

        run_id

      {:error, reason} ->
        Logger.warning("Failed to persist run record for #{issue_context(issue)}: #{inspect(reason)}")
        nil
    end
  end

  @spec persist_codex_update(running_entry(), map()) :: :ok
  def persist_codex_update(%{run_id: run_id} = running_entry, update) when is_binary(run_id) do
    message = StatusDashboard.humanize_codex_message(Map.get(running_entry, :last_codex_message))
    session_state = Map.get(running_entry, :session_state)

    Storage.update_run(
      run_id,
      %{
        state: run_state_for_session_state(session_state),
        error: run_error_for_session_state(session_state, Map.get(running_entry, :stop_reason)),
        workspace_path: Map.get(running_entry, :workspace_path),
        session_id: Map.get(running_entry, :session_id),
        issue_session_id: Map.get(running_entry, :issue_session_id),
        thread_id: Map.get(running_entry, :thread_id),
        turn_count: Map.get(running_entry, :turn_count),
        session_state: session_state,
        health: Map.get(running_entry, :health, ["healthy"])
      }
      |> Map.merge(run_pr_metadata_attrs(Map.get(running_entry, :issue)))
    )

    Storage.append_event(run_id, "info", message, update)
    :ok
  end

  def persist_codex_update(_running_entry, _update), do: :ok

  @spec mark_finished(running_entry(), term()) :: :ok
  def mark_finished(%{run_id: run_id} = running_entry, reason) when is_binary(run_id) do
    state = if reason == :normal, do: "completed", else: "failed"

    Storage.update_run(
      run_id,
      %{
        state: state,
        error: if(reason == :normal, do: nil, else: inspect(reason)),
        workspace_path: Map.get(running_entry, :workspace_path),
        session_id: running_entry_session_id(running_entry),
        issue_session_id: Map.get(running_entry, :issue_session_id),
        thread_id: Map.get(running_entry, :thread_id),
        turn_count: Map.get(running_entry, :turn_count),
        session_state: Map.get(running_entry, :session_state),
        health: Map.get(running_entry, :health, ["healthy"])
      }
      |> Map.merge(run_pr_metadata_attrs(Map.get(running_entry, :issue)))
    )

    :ok
  end

  def mark_finished(_running_entry, _reason), do: :ok

  @spec park_issue_session(running_entry(), DateTime.t()) :: :ok
  def park_issue_session(running_entry, %DateTime{} = parked_at) when is_map(running_entry) do
    parked_at_iso8601 =
      parked_at
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    issue_session_id = Map.get(running_entry, :issue_session_id)
    run_id = Map.get(running_entry, :run_id)
    health = Map.get(running_entry, :health, ["parked"])
    workspace_path = Map.get(running_entry, :workspace_path)
    thread_id = Map.get(running_entry, :thread_id)
    turn_count = Map.get(running_entry, :turn_count, 0)
    stop_reason = Map.get(running_entry, :stop_reason, "human_review")

    Storage.update_issue_session(issue_session_id, %{
      state: "parked",
      current_run_id: run_id,
      workspace_path: workspace_path,
      codex_thread_id: thread_id,
      health: health,
      parked_at: parked_at_iso8601,
      stop_reason: stop_reason
    })

    Storage.update_run(
      run_id,
      %{
        state: "parked",
        issue_session_id: issue_session_id,
        workspace_path: workspace_path,
        thread_id: thread_id,
        turn_count: turn_count,
        session_state: "parked",
        health: health,
        error: nil
      }
      |> Map.merge(run_pr_metadata_attrs(Map.get(running_entry, :issue)))
    )

    Storage.append_event(run_id, "info", "durable issue session parked", %{
      issue_session_id: issue_session_id,
      reason: stop_reason
    })

    :ok
  end

  def park_issue_session(_running_entry, _parked_at), do: :ok

  defp run_pr_metadata_attrs(%Issue{} = issue) do
    %{
      pr_url: issue.pr_url,
      pr_state: issue.pr_state,
      check_state: issue.check_state,
      review_state: issue.review_state
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp run_pr_metadata_attrs(_issue), do: %{}

  defp run_state_for_session_state(:parked), do: "parked"
  defp run_state_for_session_state("parked"), do: "parked"
  defp run_state_for_session_state(:stopped), do: "completed"
  defp run_state_for_session_state("stopped"), do: "completed"
  defp run_state_for_session_state(:failed), do: "failed"
  defp run_state_for_session_state("failed"), do: "failed"
  defp run_state_for_session_state(_session_state), do: "running"

  defp run_error_for_session_state(:failed, stop_reason), do: stop_reason
  defp run_error_for_session_state("failed", stop_reason), do: stop_reason
  defp run_error_for_session_state(_session_state, _stop_reason), do: nil

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{identifier || "n/a"}"
  end
end
