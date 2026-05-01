defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Orchestrator, Storage, TaskRuns}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec repos(Conn.t(), map()) :: Conn.t()
  def repos(conn, _params) do
    json(conn, %{repos: Presenter.repos_payload()})
  end

  @spec issues(Conn.t(), map()) :: Conn.t()
  def issues(conn, _params) do
    json(conn, %{issues: Presenter.issues_payload()})
  end

  @spec task_runs(Conn.t(), map()) :: Conn.t()
  def task_runs(conn, _params) do
    json(conn, %{task_runs: Storage.list_task_runs(100)})
  end

  @spec task_run(Conn.t(), map()) :: Conn.t()
  def task_run(conn, %{"task_run_id" => task_run_id}) do
    case Storage.get_task_run(task_run_id) do
      %{} = task_run -> json(conn, %{task_run: task_run})
      _ -> error_response(conn, 404, "task_run_not_found", "Task run not found")
    end
  end

  @spec create_goal(Conn.t(), map()) :: Conn.t()
  def create_goal(conn, params) do
    case TaskRuns.create_goal(params) do
      {:ok, task_run} ->
        conn
        |> put_status(201)
        |> json(%{task_run: task_run})

      {:error, reason} ->
        error_response(conn, 422, "goal_create_failed", "Goal create failed: #{inspect(reason)}")
    end
  end

  @spec readiness(Conn.t(), map()) :: Conn.t()
  def readiness(conn, _params) do
    {status, payload} = Presenter.readiness_payload(orchestrator(), snapshot_timeout_ms())

    conn
    |> put_status(status)
    |> json(payload)
  end

  @spec run(Conn.t(), map()) :: Conn.t()
  def run(conn, %{"run_id" => run_id}) do
    case Presenter.run_payload(run_id) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :run_not_found} ->
        error_response(conn, 404, "run_not_found", "Run not found")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec run_task_planning(Conn.t(), map()) :: Conn.t()
  def run_task_planning(conn, %{"task_run_id" => task_run_id}) do
    case TaskRuns.run_planning(task_run_id) do
      {:ok, task_run} ->
        conn
        |> put_status(202)
        |> json(%{task_run: task_run, ok: true, action: "planning_completed"})

      {:error, :task_run_not_found} ->
        error_response(conn, 404, "task_run_not_found", "Task run not found")

      {:error, reason} ->
        error_response(conn, 422, "planning_failed", "Planning failed: #{inspect(reason)}")
    end
  end

  @spec submit_task_answers(Conn.t(), map()) :: Conn.t()
  def submit_task_answers(conn, %{"task_run_id" => task_run_id} = params) do
    answers = if is_list(params["answers"]), do: params["answers"], else: []

    case TaskRuns.submit_answers(task_run_id, answers) do
      {:ok, task_run} ->
        json(conn, %{task_run: task_run, ok: true, action: "answers_submitted"})

      {:error, :task_run_not_found} ->
        error_response(conn, 404, "task_run_not_found", "Task run not found")

      {:error, reason} ->
        error_response(conn, 422, "answers_failed", "Answers failed: #{inspect(reason)}")
    end
  end

  @spec approve_task_plan(Conn.t(), map()) :: Conn.t()
  def approve_task_plan(conn, %{"task_run_id" => task_run_id}) do
    case TaskRuns.approve_plan(task_run_id) do
      {:ok, task_run} ->
        json(conn, %{task_run: task_run, ok: true, action: "plan_approved"})

      {:error, :task_run_not_found} ->
        error_response(conn, 404, "task_run_not_found", "Task run not found")

      {:error, reason} ->
        error_response(conn, 422, "approve_plan_failed", "Plan approval failed: #{inspect(reason)}")
    end
  end

  @spec rerun_task_plan(Conn.t(), map()) :: Conn.t()
  def rerun_task_plan(conn, %{"task_run_id" => task_run_id} = params) do
    case TaskRuns.rerun_plan(task_run_id, params["note"]) do
      {:ok, task_run} ->
        json(conn, %{task_run: task_run, ok: true, action: "replanning_queued"})

      {:error, :task_run_not_found} ->
        error_response(conn, 404, "task_run_not_found", "Task run not found")

      {:error, reason} ->
        error_response(conn, 422, "rerun_plan_failed", "Replanning failed: #{inspect(reason)}")
    end
  end

  @spec cancel_run(Conn.t(), map()) :: Conn.t()
  def cancel_run(conn, %{"run_id" => run_id}) do
    case Orchestrator.cancel_run(run_id, orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload |> Map.put(:ok, true) |> Map.put(:action, "cancel_requested"))

      {:error, :run_not_found} ->
        error_response(conn, 404, "run_not_found", "Run not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec rerun_issue(Conn.t(), map()) :: Conn.t()
  def rerun_issue(conn, %{"repo_id" => repo_id, "number" => number}) do
    case Orchestrator.rerun_issue(repo_id, number, orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload |> Map.put(:ok, true) |> Map.put(:action, "rerun_requested"))

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec merge_issue_pr(Conn.t(), map()) :: Conn.t()
  def merge_issue_pr(conn, %{"repo_id" => repo_id, "number" => number}) do
    case Orchestrator.merge_issue_pr(repo_id, number, orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload |> Map.put(:ok, true) |> Map.put(:action, "merge_requested"))

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")

      {:error, :invalid_issue_number} ->
        error_response(conn, 400, "invalid_issue_number", "Invalid issue number")

      {:error, {:merge_gate_blocked, reasons}} ->
        conn
        |> put_status(409)
        |> json(%{error: %{code: "merge_gate_blocked", message: "Merge gate blocked", reasons: reasons}})

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, reason} ->
        error_response(conn, 502, "merge_failed", "Merge failed: #{inspect(reason)}")
    end
  end

  @spec stop_issue_session(Conn.t(), map()) :: Conn.t()
  def stop_issue_session(conn, %{"repo_id" => repo_id, "number" => number}) do
    case Orchestrator.stop_issue_session(repo_id, number, orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload |> Map.put(:ok, true) |> Map.put(:action, "stop_session_requested"))

      {:error, :session_not_found} ->
        error_response(conn, 404, "session_not_found", "Issue session not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
