defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
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
