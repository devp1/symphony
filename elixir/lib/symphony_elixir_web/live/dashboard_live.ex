defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:action_notice, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    notice =
      case Presenter.refresh_payload(orchestrator()) do
        {:ok, payload} -> "Refresh queued: #{Enum.join(Map.get(payload, :operations, []), ", ")}"
        {:error, reason} -> "Refresh failed: #{inspect(reason)}"
      end

    {:noreply, reload_with_notice(socket, notice)}
  end

  def handle_event("cancel-run", %{"run-id" => run_id}, socket) do
    notice =
      case Orchestrator.cancel_run(run_id, orchestrator()) do
        {:ok, _payload} -> "Cancel requested for #{run_id}"
        {:error, reason} -> "Cancel failed for #{run_id}: #{inspect(reason)}"
      end

    {:noreply, reload_with_notice(socket, notice)}
  end

  def handle_event("rerun-issue", %{"repo-id" => repo_id, "number" => number}, socket) do
    notice =
      case Orchestrator.rerun_issue(repo_id, number, orchestrator()) do
        {:ok, _payload} -> "Rerun queued for #{repo_id}##{number}"
        {:error, reason} -> "Rerun failed for #{repo_id}##{number}: #{inspect(reason)}"
      end

    {:noreply, reload_with_notice(socket, notice)}
  end

  def handle_event("stop-session", %{"repo-id" => repo_id, "number" => number}, socket) do
    notice =
      case Orchestrator.stop_issue_session(repo_id, number, orchestrator()) do
        {:ok, _payload} -> "Stop requested for #{repo_id}##{number}"
        {:error, reason} -> "Stop failed for #{repo_id}##{number}: #{inspect(reason)}"
      end

    {:noreply, reload_with_notice(socket, notice)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Cockpit
            </p>
            <h1 class="hero-title">
              GitHub Control Plane
            </h1>
            <p class="hero-copy">
              GitHub issues, autonomous Codex runs, evidence, and PR handoff state for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <button type="button" class="subtle-button" phx-click="refresh">
              Refresh now
            </button>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @action_notice do %>
        <section class="notice-card">
          <%= @action_notice %>
        </section>
      <% end %>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Repos</h2>
              <p class="section-copy">Configured GitHub repositories managed by this local cockpit.</p>
            </div>
          </div>

          <%= if @payload.repos == [] do %>
            <p class="empty-state">No GitHub repos configured yet.</p>
          <% else %>
            <div class="repo-strip">
              <article :for={repo <- @payload.repos} class="repo-pill">
                <strong><%= repo.owner %>/<%= repo.name %></strong>
                <span class="mono"><%= repo.id %></span>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Issue board</h2>
              <p class="section-copy">GitHub label states are the durable queue; Symphony augments them with run history and evidence.</p>
            </div>
          </div>

          <%= if @payload.issues == [] do %>
            <p class="empty-state">No issue snapshots yet. The next GitHub poll will populate this board.</p>
          <% else %>
            <div class="kanban-grid">
              <article :for={column <- issue_columns()} class="kanban-column">
                <div class="kanban-column-header">
                  <h3><%= column %></h3>
                  <span class="mono"><%= length(issues_for_state(@payload.issues, column)) %></span>
                </div>
                <div class="kanban-card-stack">
                  <article
                    :for={issue <- issues_for_state(@payload.issues, column)}
                    class="kanban-card"
                  >
                    <a
                      class="kanban-card-primary"
                      href={issue["url"] || "#"}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      <span class="issue-id"><%= issue["identifier"] %></span>
                      <strong><%= issue["title"] || "Untitled issue" %></strong>
                    </a>
                    <span class="muted"><%= issue["repo_id"] %></span>
                    <div class="card-meta-row">
                      <%= if present?(issue["pr_url"]) do %>
                        <a class="meta-pill meta-link" href={issue["pr_url"]} target="_blank" rel="noopener noreferrer">PR handoff</a>
                      <% end %>
                      <%= if present?(issue["check_state"]) do %>
                        <span class={state_badge_class(issue["check_state"])}><%= issue["check_state"] %></span>
                      <% end %>
                      <%= if present?(issue["review_state"]) do %>
                        <span class="meta-pill"><%= issue["review_state"] %></span>
                      <% end %>
                    </div>
                  </article>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Active runs</h2>
              <p class="section-copy">Live Codex sessions, last known agent activity, watchdog markers, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                  <col style="width: 12rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                    <th>Controls</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <%= if entry.pr_url do %>
                          <a class="issue-link" href={entry.pr_url} target="_blank" rel="noopener noreferrer">PR handoff</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                    <td>
                      <div class="action-stack">
                        <%= if entry.run_id do %>
                          <button type="button" class="subtle-button danger-button" phx-click="cancel-run" phx-value-run-id={entry.run_id}>
                            Cancel
                          </button>
                        <% end %>
                        <%= if entry.repo_id && entry.issue_number do %>
                          <button type="button" class="subtle-button secondary-action" phx-click="rerun-issue" phx-value-repo-id={entry.repo_id} phx-value-number={entry.issue_number}>
                            Rerun
                          </button>
                          <button type="button" class="subtle-button secondary-action" phx-click="stop-session" phx-value-repo-id={entry.repo_id} phx-value-number={entry.issue_number}>
                            Stop Session
                          </button>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Run history</h2>
              <p class="section-copy">SQLite-backed ledger of recent autonomous attempts.</p>
            </div>
          </div>

          <%= if @payload.runs == [] do %>
            <p class="empty-state">No persisted run history yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Run</th>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>PR</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @payload.runs}>
                    <td class="mono"><a href={"/api/v1/runs/#{run["id"]}"}><%= run["id"] %></a></td>
                    <td><%= run["issue_identifier"] || "n/a" %></td>
                    <td><span class={state_badge_class(run["state"])}><%= run["state"] %></span></td>
                    <td class="mono"><%= run["session_id"] || "n/a" %></td>
                    <td>
                      <%= if run["pr_url"] do %>
                        <a href={run["pr_url"]} target="_blank" rel="noopener noreferrer">PR</a>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp reload_with_notice(socket, notice) do
    socket
    |> assign(:payload, load_payload())
    |> assign(:action_notice, notice)
    |> assign(:now, DateTime.utc_now())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp issue_columns do
    ["Todo", "In Progress", "Human Review", "Needs Input", "Blocked", "Rework", "Merging", "Done", "Backlog"]
  end

  defp issues_for_state(issues, state) do
    Enum.filter(issues, &(Map.get(&1, "state") == state))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
