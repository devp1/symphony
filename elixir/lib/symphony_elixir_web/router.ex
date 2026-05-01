defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/readiness", ObservabilityApiController, :readiness)
    get("/api/v1/repos", ObservabilityApiController, :repos)
    get("/api/v1/issues", ObservabilityApiController, :issues)
    get("/api/v1/task-runs", ObservabilityApiController, :task_runs)
    post("/api/v1/goals", ObservabilityApiController, :create_goal)
    get("/api/v1/task-runs/:task_run_id", ObservabilityApiController, :task_run)
    post("/api/v1/task-runs/:task_run_id/plan", ObservabilityApiController, :run_task_planning)
    post("/api/v1/task-runs/:task_run_id/answers", ObservabilityApiController, :submit_task_answers)
    post("/api/v1/task-runs/:task_run_id/approve-plan", ObservabilityApiController, :approve_task_plan)
    post("/api/v1/task-runs/:task_run_id/rerun-plan", ObservabilityApiController, :rerun_task_plan)
    get("/api/v1/runs/:run_id", ObservabilityApiController, :run)
    post("/api/v1/runs/:run_id/cancel", ObservabilityApiController, :cancel_run)
    post("/api/v1/issues/:repo_id/:number/rerun", ObservabilityApiController, :rerun_issue)
    post("/api/v1/issues/:repo_id/:number/merge", ObservabilityApiController, :merge_issue_pr)
    post("/api/v1/issues/:repo_id/:number/stop-session", ObservabilityApiController, :stop_issue_session)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/readiness", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/repos", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-runs", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/goals", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-runs/:task_run_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-runs/:task_run_id/plan", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-runs/:task_run_id/answers", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-runs/:task_run_id/approve-plan", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-runs/:task_run_id/rerun-plan", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
