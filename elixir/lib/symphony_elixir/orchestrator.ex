defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to
  Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.AutonomousReview
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub
  alias SymphonyElixir.IssueSession
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunLedger
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Storage
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workpad
  alias SymphonyElixir.Workspace

  @continuation_retry_delay_ms 1_000
  @artifact_nudge_retry_delay_ms 1_000
  @codex_activity_trace_limit 8
  @failure_retry_base_ms 10_000
  @proof_health_warning_flags ["stale-proof", "high-token-no-proof"]
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      artifact_nudge_counts: %{},
      operator_paused_issue_ids: MapSet.new(),
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    preserve_human_review_storage_runs()
    interrupt_stale_storage_runs()
    interrupt_stale_issue_sessions()
    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        RunLedger.mark_finished(running_entry, reason)

        state =
          handle_worker_down_state(state, issue_id, running_entry, reason, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        {updated_running_entry, state} =
          maybe_restore_artifact_nudge_state_from_workspace(updated_running_entry, state, issue_id)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        persist_codex_update(updated_running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> maybe_clear_artifact_nudge_count_after_repo_artifact(issue_id, running_entry, updated_running_entry)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:issue_session_state, issue_id, session_update}, %{running: running} = state)
      when is_binary(issue_id) and is_map(session_update) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        state = integrate_issue_session_update(state, issue_id, running_entry, session_update)
        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_worker_down_state(state, issue_id, running_entry, :normal, session_id) do
    if durable_session_entry?(running_entry) do
      Logger.info("Durable issue session stopped normally for issue_id=#{issue_id} session_id=#{session_id}")

      state
      |> complete_issue(issue_id)
      |> release_issue_claim(issue_id)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_worker_down_state(state, issue_id, running_entry, reason, session_id) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp integrate_issue_session_update(%State{} = state, issue_id, running_entry, session_update) do
    updated_entry =
      running_entry
      |> maybe_put_runtime_value(:issue_session_id, Map.get(session_update, :issue_session_id))
      |> maybe_put_runtime_value(:workspace_path, Map.get(session_update, :workspace_path))
      |> maybe_put_runtime_value(:session_state, Map.get(session_update, :session_state))
      |> maybe_put_runtime_value(:health, Map.get(session_update, :health))
      |> maybe_put_runtime_value(:thread_id, Map.get(session_update, :thread_id))
      |> maybe_put_runtime_value(:codex_app_server_pid, Map.get(session_update, :codex_app_server_pid))
      |> maybe_put_runtime_value(:turn_count, Map.get(session_update, :turn_count))
      |> maybe_put_runtime_value(:parked_at, Map.get(session_update, :parked_at))
      |> maybe_put_runtime_value(:stop_reason, Map.get(session_update, :stop_reason))
      |> maybe_put_runtime_value(:run_id, Map.get(session_update, :run_id))

    case Map.get(session_update, :session_state) do
      :running ->
        %{state | running: Map.put(state.running, issue_id, Map.put(updated_entry, :last_codex_timestamp, DateTime.utc_now()))}

      :parked ->
        %{state | running: Map.put(state.running, issue_id, updated_entry)}

      :stopped ->
        finish_issue_session_without_retry(state, issue_id, updated_entry, session_update)

      :failed ->
        finish_failed_issue_session(state, issue_id, updated_entry, session_update)

      _ ->
        %{state | running: Map.put(state.running, issue_id, updated_entry)}
    end
  end

  defp finish_issue_session_without_retry(%State{} = state, issue_id, running_entry, session_update) do
    if Map.get(session_update, :cleanup_workspace) do
      cleanup_issue_workspace(Map.get(running_entry, :identifier), Map.get(running_entry, :worker_host))
    end

    demonitor_running_entry(running_entry)

    state
    |> record_session_completion_totals(running_entry)
    |> complete_issue(issue_id)
    |> release_issue_claim(issue_id)
    |> Map.update!(:running, &Map.delete(&1, issue_id))
  end

  defp finish_failed_issue_session(%State{} = state, issue_id, running_entry, session_update) do
    demonitor_running_entry(running_entry)
    state = record_session_completion_totals(state, running_entry)
    next_attempt = next_retry_attempt_from_running(running_entry)

    state
    |> Map.update!(:running, &Map.delete(&1, issue_id))
    |> schedule_issue_retry(issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: Map.get(session_update, :stop_reason) || "issue session failed",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         true <- available_slots(state) > 0,
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      choose_issues_after_preflight(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_github_owner} ->
        Logger.error("GitHub owner missing in WORKFLOW.md")
        state

      {:error, :missing_github_repo} ->
        Logger.error("GitHub repo missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, {:github_auth_preflight_failed, status, output}} ->
        Logger.error("GitHub preflight failed: gh auth status exited=#{status} output=#{inspect(output)}")
        state

      {:error, {:github_missing_labels, repo, labels}} ->
        Logger.error("GitHub preflight failed: repo=#{repo} missing_labels=#{inspect(labels)}")
        state

      {:error, {:github_label_preflight_failed, repo, reason}} ->
        Logger.error("GitHub preflight failed: repo=#{repo} reason=#{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    state = reconcile_artifact_watchdog_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec preserve_human_review_storage_for_test() :: :ok
  def preserve_human_review_storage_for_test do
    preserve_human_review_storage_runs()
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec claim_issue_for_dispatch_for_test(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def claim_issue_for_dispatch_for_test(%Issue{} = issue) do
    claim_issue_for_dispatch(issue)
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec reconcile_artifact_watchdog_for_test(term()) :: term()
  def reconcile_artifact_watchdog_for_test(%State{} = state) do
    reconcile_artifact_watchdog_running_issues(state)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        state
        |> refresh_running_issue_state(issue)
        |> maybe_resume_parked_issue_session(issue)

      true ->
        if human_review_issue_state?(issue.state) do
          park_durable_issue_session(state, issue)
        else
          Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

          terminate_running_issue(state, issue.id, false)
        end
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp maybe_resume_parked_issue_session(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{session_kind: :durable, session_state: :parked, pid: pid} = running_entry when is_pid(pid) ->
        resume_parked_issue_session(state, issue, running_entry, pid)

      _ ->
        state
    end
  end

  defp resume_parked_issue_session(state, issue, running_entry, pid) do
    worker_host = Map.get(running_entry, :worker_host)

    if dispatch_slots_available?(issue, state) and worker_slots_available?(state, worker_host) do
      do_resume_parked_issue_session(state, issue, running_entry, pid, worker_host)
    else
      state
    end
  end

  defp do_resume_parked_issue_session(state, issue, running_entry, pid, worker_host) do
    run_id = create_run_record(issue, worker_host, Map.get(running_entry, :issue_session_id))

    opts =
      agent_runner_opts(
        next_retry_attempt_from_running(running_entry),
        worker_host,
        run_resume_agent_opts(running_entry, run_id)
      )

    case IssueSession.resume(pid, issue, opts) do
      :ok -> resumed_issue_session_state(state, issue, running_entry, run_id)
      {:error, reason} -> failed_resume_parked_issue_session(state, issue, reason)
    end
  end

  defp resumed_issue_session_state(state, issue, running_entry, run_id) do
    Logger.info("Resumed parked durable issue session for #{issue_context(issue)} run_id=#{run_id}")

    updated_entry =
      running_entry
      |> Map.merge(%{
        issue: issue,
        run_id: run_id,
        session_state: :running,
        health: ["healthy"],
        stop_reason: nil,
        parked_at: nil
      })

    %{state | running: Map.put(state.running, issue.id, updated_entry)}
  end

  defp failed_resume_parked_issue_session(state, issue, reason) do
    Logger.warning("Unable to resume parked durable issue session for #{issue_context(issue)}: #{inspect(reason)}")
    state
  end

  defp park_durable_issue_session(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{session_kind: :durable, session_state: :parked} = running_entry ->
        updated_entry = Map.put(running_entry, :issue, issue)
        %{state | running: Map.put(state.running, issue.id, updated_entry)}

      %{session_kind: :durable} = running_entry ->
        parked_at = DateTime.utc_now()

        updated_entry =
          running_entry
          |> Map.put(:issue, issue)
          |> Map.put(:session_state, :parked)
          |> Map.put(:health, ["parked"])
          |> Map.put(:parked_at, parked_at)
          |> Map.put(:stop_reason, "human_review")

        RunLedger.park_issue_session(updated_entry, parked_at)

        %{state | running: Map.put(state.running, issue.id, updated_entry)}

      _ ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, issue.id, false)
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_worker_process(running_entry, pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            artifact_nudge_counts: Map.delete(state.artifact_nudge_counts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = if parked_durable_issue_session?(running_entry), do: nil, else: stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp reconcile_artifact_watchdog_running_issues(%State{} = state) do
    settings = Config.settings!()

    if map_size(state.running) == 0 do
      state
    else
      reconcile_running_entries(state, settings)
    end
  end

  defp reconcile_running_entries(state, settings) do
    state.running
    |> Map.keys()
    |> Enum.reduce(state, fn issue_id, state_acc ->
      reconcile_running_entry(state_acc, issue_id, settings)
    end)
  end

  defp reconcile_running_entry(state, issue_id, settings) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      %{session_state: :parked} ->
        state

      running_entry ->
        state
        |> refresh_local_workspace_artifact(issue_id, running_entry)
        |> refresh_tracker_artifact(issue_id)
        |> maybe_nudge_unproductive_issue(issue_id, settings)
        |> maybe_pause_unproductive_issue(issue_id, settings)
    end
  end

  defp refresh_local_workspace_artifact(%State{} = state, issue_id, running_entry) do
    case local_workspace_artifact_fingerprint(running_entry) do
      {:artifact, reason, fingerprint} ->
        if fingerprint != Map.get(running_entry, :last_workspace_artifact_fingerprint) do
          reset_artifact_progress(
            state,
            issue_id,
            reason,
            DateTime.utc_now(),
            %{last_workspace_artifact_fingerprint: fingerprint},
            repo_artifact: repo_artifact_reason?(reason)
          )
        else
          state
        end

      :clean ->
        state
    end
  end

  defp local_workspace_artifact_fingerprint(%{worker_host: worker_host, workspace_path: workspace})
       when is_nil(worker_host) and is_binary(workspace) do
    if File.dir?(workspace) do
      local_workspace_fingerprint_from_files(workspace)
    else
      :clean
    end
  rescue
    _ -> :clean
  end

  defp local_workspace_artifact_fingerprint(_running_entry), do: :clean

  defp local_workspace_fingerprint_from_files(workspace) do
    case local_git_status_artifact_fingerprint(workspace) do
      {:artifact, _reason, _fingerprint} = artifact -> artifact
      :clean -> workpad_artifact_fingerprint(workspace)
    end
  end

  defp workpad_artifact_fingerprint(workspace) do
    case Workpad.fingerprint(workspace) do
      {:ok, fingerprint} -> {:artifact, "symphony workpad updated", {:workpad, fingerprint}}
      :missing -> :clean
    end
  end

  defp maybe_restore_artifact_nudge_state_from_workspace(running_entry, %State{} = state, issue_id) do
    restored_count = local_artifact_nudge_count_from_capsule(running_entry)
    current_count = artifact_nudge_count(state, issue_id, running_entry)

    if restored_count > current_count do
      running_entry =
        running_entry
        |> Map.put(:artifact_nudge_count, restored_count)
        |> maybe_mark_current_workspace_artifact_as_inherited()

      {running_entry, put_artifact_nudge_count(state, issue_id, restored_count)}
    else
      {running_entry, state}
    end
  end

  defp local_artifact_nudge_count_from_capsule(%{worker_host: worker_host, workspace_path: workspace})
       when is_nil(worker_host) and is_binary(workspace) do
    capsule_path = Path.join([workspace, ".symphony", "continuation.json"])

    with true <- File.regular?(capsule_path),
         {:ok, body} <- File.read(capsule_path),
         {:ok, %{} = capsule} <- Jason.decode(body),
         count when is_integer(count) and count > 0 <- Map.get(capsule, "nudge_count") do
      count
    else
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp local_artifact_nudge_count_from_capsule(_running_entry), do: 0

  defp maybe_mark_current_workspace_artifact_as_inherited(running_entry) do
    case local_workspace_artifact_fingerprint(running_entry) do
      {:artifact, reason, fingerprint} ->
        if repo_artifact_reason?(reason) do
          Map.put(running_entry, :last_workspace_artifact_fingerprint, fingerprint)
        else
          running_entry
        end

      :clean ->
        running_entry
    end
  end

  defp refresh_tracker_artifact(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        if tracker_artifact_check_due?(running_entry) do
          do_refresh_tracker_artifact(state, issue_id, running_entry)
        else
          state
        end
    end
  end

  defp tracker_artifact_check_due?(running_entry) do
    last_check_ms = Map.get(running_entry, :last_tracker_artifact_check_ms)

    is_nil(last_check_ms) ||
      System.monotonic_time(:millisecond) - last_check_ms >= 15_000
  end

  defp do_refresh_tracker_artifact(%State{} = state, issue_id, running_entry) do
    checked_at_ms = System.monotonic_time(:millisecond)

    case Tracker.fetch_artifact_marker(issue_id) do
      {:ok, reason, fingerprint} ->
        attrs = %{
          last_tracker_artifact_check_ms: checked_at_ms,
          last_tracker_artifact_fingerprint: fingerprint
        }

        if fingerprint != Map.get(running_entry, :last_tracker_artifact_fingerprint) do
          reset_artifact_progress(state, issue_id, reason, DateTime.utc_now(), attrs)
        else
          put_running_entry_attrs(state, issue_id, attrs)
        end

      :missing ->
        put_running_entry_attrs(state, issue_id, %{last_tracker_artifact_check_ms: checked_at_ms})

      {:error, reason} ->
        Logger.debug("Tracker artifact marker lookup failed issue_id=#{issue_id} reason=#{inspect(reason)}")
        put_running_entry_attrs(state, issue_id, %{last_tracker_artifact_check_ms: checked_at_ms})
    end
  end

  defp put_running_entry_attrs(%State{} = state, issue_id, attrs) when is_map(attrs) do
    case Map.get(state.running, issue_id) do
      nil -> state
      running_entry -> %{state | running: Map.put(state.running, issue_id, Map.merge(running_entry, attrs))}
    end
  end

  defp repo_artifact_reason?("codex diff updated"), do: true
  defp repo_artifact_reason?("workspace git status changed"), do: true
  defp repo_artifact_reason?(_reason), do: false

  defp local_git_status_artifact_fingerprint(workspace) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        trimmed_output =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&symphony_control_status_line?/1)
          |> Enum.join("\n")

        if trimmed_output == "" do
          :clean
        else
          {:artifact, "workspace git status changed", {:git_status, :erlang.phash2(trimmed_output)}}
        end

      _ ->
        :clean
    end
  end

  defp symphony_control_status_line?(line) when is_binary(line) do
    String.contains?(line, ".symphony/")
  end

  defp symphony_control_status_line?(_line), do: false

  defp maybe_nudge_unproductive_issue(%State{} = state, issue_id, settings) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        threshold = settings.agent.artifact_nudge_tokens
        max_nudges = settings.agent.max_artifact_nudges
        nudge_count = artifact_nudge_count(state, issue_id, running_entry)
        maybe_nudge_running_entry(state, issue_id, running_entry, settings, threshold, max_nudges, nudge_count)
    end
  end

  defp maybe_nudge_running_entry(state, issue_id, running_entry, settings, threshold, max_nudges, nudge_count) do
    if handoff_progress_recent?(running_entry, settings) do
      state
    else
      tokens_without_repo_artifact = tokens_without_repo_artifact(running_entry)

      maybe_apply_artifact_nudge(
        state,
        issue_id,
        running_entry,
        tokens_without_repo_artifact,
        threshold,
        max_nudges,
        nudge_count
      )
    end
  end

  defp maybe_apply_artifact_nudge(
         state,
         issue_id,
         running_entry,
         tokens_without_repo_artifact,
         threshold,
         max_nudges,
         nudge_count
       ) do
    if artifact_nudge_enabled?(threshold, max_nudges, nudge_count) and tokens_without_repo_artifact > threshold do
      apply_artifact_nudge(state, issue_id, running_entry, tokens_without_repo_artifact, threshold, nudge_count)
    else
      state
    end
  end

  defp apply_artifact_nudge(state, issue_id, running_entry, tokens_without_repo_artifact, threshold, nudge_count) do
    if durable_session_entry?(running_entry) do
      record_session_health_warning(
        state,
        issue_id,
        running_entry,
        "stale-proof",
        "artifact nudge threshold exceeded",
        tokens_without_repo_artifact,
        threshold
      )
    else
      restart_for_artifact_nudge(
        state,
        issue_id,
        running_entry,
        tokens_without_repo_artifact,
        threshold,
        nudge_count
      )
    end
  end

  defp artifact_nudge_enabled?(threshold, max_nudges, nudge_count)
       when is_integer(threshold) and is_integer(max_nudges) and is_integer(nudge_count) do
    threshold > 0 and max_nudges > 0 and nudge_count < max_nudges
  end

  defp artifact_nudge_enabled?(_threshold, _max_nudges, _nudge_count), do: false

  defp restart_for_artifact_nudge(state, issue_id, running_entry, tokens_without_repo_artifact, threshold, nudge_count) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)
    next_nudge_count = nudge_count + 1

    artifact_nudge =
      running_entry
      |> artifact_nudge_context(tokens_without_repo_artifact, threshold, next_nudge_count)
      |> maybe_write_continuation_capsule(running_entry)

    Logger.warning(
      "Issue exceeded artifact nudge budget: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} tokens_without_repo_artifact=#{tokens_without_repo_artifact} threshold=#{threshold} nudge=#{next_nudge_count}; restarting same workspace with continuation guidance"
    )

    record_artifact_nudge_restart(
      running_entry,
      issue_id,
      tokens_without_repo_artifact,
      threshold,
      next_nudge_count
    )

    state
    |> terminate_running_issue(issue_id, false)
    |> put_artifact_nudge_count(issue_id, next_nudge_count)
    |> schedule_issue_retry(issue_id, next_retry_attempt_from_running(running_entry), %{
      identifier: identifier,
      delay_type: :artifact_nudge,
      error: "artifact nudge restart after #{tokens_without_repo_artifact} tokens without repo artifact",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      artifact_nudge_count: next_nudge_count,
      artifact_nudge: artifact_nudge,
      last_workspace_artifact_fingerprint: Map.get(running_entry, :last_workspace_artifact_fingerprint),
      last_codex_diff_artifact_fingerprint: Map.get(running_entry, :last_codex_diff_artifact_fingerprint)
    })
  end

  defp record_artifact_nudge_restart(%{run_id: run_id} = running_entry, issue_id, tokens, threshold, nudge_count)
       when is_binary(run_id) do
    _ =
      Storage.append_event(run_id, "warning", "artifact nudge restart", %{
        issue_id: issue_id,
        session_id: running_entry_session_id(running_entry),
        tokens_without_repo_artifact: tokens,
        threshold: threshold,
        nudge_count: nudge_count,
        last_event: Map.get(running_entry, :last_codex_event),
        last_repo_artifact: last_repo_artifact_summary(running_entry)
      })

    _ = Storage.update_run(run_id, %{state: "cancelled", error: "artifact nudge restart"})
    :ok
  end

  defp record_artifact_nudge_restart(_running_entry, _issue_id, _tokens, _threshold, _nudge_count), do: :ok

  defp record_session_health_warning(state, issue_id, running_entry, health_flag, message, tokens, threshold) do
    previous_health = normalize_health_flags(Map.get(running_entry, :health, ["healthy"]))
    health = normalize_health_flags(previous_health ++ [health_flag])
    warning_is_new? = health_flag not in previous_health

    run_id = Map.get(running_entry, :run_id)
    issue_session_id = Map.get(running_entry, :issue_session_id)

    if is_binary(run_id) and warning_is_new? do
      _ =
        Storage.append_event(run_id, "warning", message, %{
          issue_id: issue_id,
          issue_session_id: issue_session_id,
          tokens_without_artifact: tokens,
          threshold: threshold,
          last_event: Map.get(running_entry, :last_codex_event),
          last_artifact: last_artifact_summary(running_entry),
          last_repo_artifact: last_repo_artifact_summary(running_entry)
        })
    end

    if is_binary(run_id) and health != previous_health do
      _ = Storage.update_run(run_id, %{health: health, session_state: Map.get(running_entry, :session_state)})
    end

    if is_binary(issue_session_id) and health != previous_health do
      _ = Storage.update_issue_session(issue_session_id, %{health: health})
    end

    put_running_entry_attrs(state, issue_id, %{health: health})
  end

  defp artifact_nudge_context(running_entry, tokens, threshold, nudge_count) do
    %{
      "nudge_count" => nudge_count,
      "tokens_without_repo_artifact" => tokens,
      "threshold" => threshold,
      "last_event" => inspect(Map.get(running_entry, :last_codex_event)),
      "last_artifact" => last_artifact_summary(running_entry),
      "last_repo_artifact" => last_repo_artifact_summary(running_entry),
      "last_handoff_progress" => last_handoff_progress_summary(running_entry),
      "handoff_candidate" => handoff_progress_candidate?(running_entry),
      "workspace" => Map.get(running_entry, :workspace_path),
      "session" => running_entry_session_id(running_entry),
      "continuation" => continuation_context(running_entry)
    }
  end

  defp maybe_write_continuation_capsule(context, %{worker_host: worker_host, workspace_path: workspace})
       when is_nil(worker_host) and is_binary(workspace) do
    capsule_path = Path.join([workspace, ".symphony", "continuation.json"])

    with true <- File.dir?(workspace),
         :ok <- File.mkdir_p(Path.dirname(capsule_path)),
         {:ok, encoded} <- Jason.encode(context, pretty: true),
         :ok <- File.write(capsule_path, encoded <> "\n") do
      Map.put(context, "capsule_path", capsule_path)
    else
      _ ->
        context
    end
  rescue
    _ -> context
  end

  defp maybe_write_continuation_capsule(context, _running_entry), do: context

  defp continuation_context(running_entry) when is_map(running_entry) do
    issue = Map.get(running_entry, :issue, %Issue{})

    %{
      "issue" => %{
        "identifier" => issue.identifier || issue.id || Map.get(running_entry, :identifier),
        "title" => issue.title,
        "state" => issue.state
      },
      "workspace" => workspace_continuation_context(running_entry),
      "recent_activity" => Map.get(running_entry, :codex_activity_trace, []),
      "resume_directive" => continuation_resume_directive(running_entry)
    }
  end

  defp continuation_resume_directive(running_entry) do
    if handoff_progress_candidate?(running_entry) do
      "Continue in this workspace from the existing repo changes. Inspect the current diff first, remove unrelated generated churn, validate the issue, and move to PR handoff before broad rediscovery."
    else
      "Continue in this workspace and create the smallest issue-relevant repo artifact before broad rediscovery."
    end
  end

  defp workspace_continuation_context(%{worker_host: worker_host, workspace_path: workspace})
       when is_binary(workspace) do
    base =
      %{
        "path" => workspace,
        "worker_host" => worker_host
      }

    if is_nil(worker_host) and File.dir?(workspace) do
      Map.merge(base, %{
        "branch" => git_output(workspace, ["branch", "--show-current"]),
        "head" => git_output(workspace, ["rev-parse", "--short", "HEAD"]),
        "status" => git_status_summary(workspace)
      })
    else
      base
    end
  rescue
    _ -> %{"path" => workspace, "worker_host" => worker_host}
  end

  defp workspace_continuation_context(_running_entry), do: %{}

  defp git_output(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> blank_as_unknown()

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp git_status_summary(workspace) when is_binary(workspace) do
    case System.cmd("git", ["status", "--short"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.take(12)
        |> case do
          [] -> "clean"
          lines -> Enum.join(lines, "\n")
        end

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp blank_as_unknown(""), do: "unknown"
  defp blank_as_unknown(value), do: value

  defp maybe_pause_unproductive_issue(%State{} = state, issue_id, settings) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        running_entry = Map.put(running_entry, :artifact_nudge_count, artifact_nudge_count(state, issue_id, running_entry))
        maybe_pause_running_entry(state, issue_id, running_entry, settings)
    end
  end

  defp maybe_pause_running_entry(state, issue_id, running_entry, settings) do
    case artifact_watchdog_budget(running_entry, settings) do
      {:enabled, watchdog_kind, threshold} ->
        maybe_apply_artifact_watchdog(state, issue_id, running_entry, watchdog_kind, threshold)

      :disabled ->
        state
    end
  end

  defp maybe_apply_artifact_watchdog(state, issue_id, running_entry, watchdog_kind, threshold) do
    tokens_without_artifact = artifact_watchdog_tokens_without_artifact(running_entry, watchdog_kind)

    if tokens_without_artifact > threshold do
      apply_artifact_watchdog(state, issue_id, running_entry, watchdog_kind, tokens_without_artifact, threshold)
    else
      state
    end
  end

  defp apply_artifact_watchdog(state, issue_id, running_entry, watchdog_kind, tokens_without_artifact, threshold) do
    if durable_session_entry?(running_entry) do
      record_session_health_warning(
        state,
        issue_id,
        running_entry,
        "high-token-no-proof",
        artifact_watchdog_label(watchdog_kind),
        tokens_without_artifact,
        threshold
      )
    else
      pause_unproductive_issue(state, issue_id, running_entry, tokens_without_artifact, threshold, watchdog_kind)
    end
  end

  defp artifact_watchdog_budget(running_entry, settings) do
    if handoff_progress_recent?(running_entry, settings) do
      :disabled
    else
      case repo_artifact_nudge_exhausted_budget(running_entry, settings) do
        {:enabled, _watchdog_kind, _threshold} = budget ->
          budget

        :disabled ->
          artifact_budget_after_nudge(running_entry, settings)
      end
    end
  end

  defp artifact_budget_after_nudge(running_entry, settings) do
    if first_artifact_seen?(running_entry) do
      standard_artifact_budget(settings)
    else
      first_artifact_budget(settings)
    end
  end

  defp repo_artifact_nudge_exhausted_budget(running_entry, settings) do
    threshold = settings.agent.artifact_nudge_tokens
    max_nudges = settings.agent.max_artifact_nudges
    nudge_count = Map.get(running_entry, :artifact_nudge_count, 0)

    if is_integer(threshold) and threshold > 0 and is_integer(max_nudges) and max_nudges > 0 and
         is_integer(nudge_count) and nudge_count >= max_nudges do
      {:enabled, :repo_artifact_nudge_exhausted, threshold}
    else
      :disabled
    end
  end

  defp first_artifact_budget(settings) do
    first_artifact_threshold = settings.agent.max_tokens_before_first_artifact
    standard_threshold = settings.agent.max_tokens_without_artifact

    [first_artifact_threshold, standard_threshold]
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> case do
      [] -> :disabled
      thresholds -> {:enabled, :first_artifact, Enum.min(thresholds)}
    end
  end

  defp standard_artifact_budget(settings) do
    threshold = settings.agent.max_tokens_without_artifact

    if is_integer(threshold) and threshold > 0 do
      {:enabled, :standard_artifact, threshold}
    else
      :disabled
    end
  end

  defp first_artifact_seen?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_artifact_reason) not in [nil, "run started"]
  end

  defp artifact_watchdog_tokens_without_artifact(running_entry, :repo_artifact_nudge_exhausted) do
    tokens_without_repo_artifact(running_entry)
  end

  defp artifact_watchdog_tokens_without_artifact(running_entry, _watchdog_kind) do
    tokens_without_artifact(running_entry)
  end

  defp handoff_progress_recent?(running_entry, settings) when is_map(running_entry) do
    threshold = handoff_progress_threshold(settings)

    handoff_progress_candidate?(running_entry) and is_integer(threshold) and threshold > 0 and
      handoff_progress_seen?(running_entry) and tokens_without_handoff_progress(running_entry) <= threshold
  end

  defp handoff_progress_threshold(settings) do
    [
      get_in(settings, [Access.key(:agent), Access.key(:artifact_nudge_tokens)]),
      get_in(settings, [Access.key(:agent), Access.key(:max_tokens_without_artifact)])
    ]
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> case do
      [] -> nil
      thresholds -> Enum.max(thresholds)
    end
  end

  defp handoff_progress_seen?(running_entry) do
    Map.get(running_entry, :last_handoff_progress_reason) not in [nil, ""]
  end

  defp handoff_progress_candidate?(running_entry) when is_map(running_entry) do
    repo_artifact_reason?(Map.get(running_entry, :last_repo_artifact_reason)) or
      repo_artifact_fingerprint?(Map.get(running_entry, :last_workspace_artifact_fingerprint)) or
      repo_artifact_fingerprint?(Map.get(running_entry, :last_codex_diff_artifact_fingerprint))
  end

  defp repo_artifact_fingerprint?({:git_status, _fingerprint}), do: true
  defp repo_artifact_fingerprint?({:codex_diff, _fingerprint}), do: true
  defp repo_artifact_fingerprint?(_fingerprint), do: false

  defp tokens_without_handoff_progress(running_entry) when is_map(running_entry) do
    total = Map.get(running_entry, :codex_total_tokens, 0)
    baseline = Map.get(running_entry, :handoff_progress_baseline_total_tokens, 0)

    if is_integer(total) and is_integer(baseline) do
      max(0, total - baseline)
    else
      0
    end
  end

  defp pause_unproductive_issue(state, issue_id, running_entry, tokens_without_artifact, threshold, watchdog_kind) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)
    watchdog_label = artifact_watchdog_label(watchdog_kind)

    Logger.warning(
      "Issue exceeded #{watchdog_label}: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} tokens_without_artifact=#{tokens_without_artifact} threshold=#{threshold}; pausing for human input"
    )

    comment_result =
      Tracker.create_comment(
        issue_id,
        artifact_watchdog_comment(running_entry, tokens_without_artifact, threshold, watchdog_kind)
      )

    state_result = Tracker.update_issue_state(issue_id, "Needs Input")

    case {comment_result, state_result} do
      {:ok, :ok} ->
        Storage.update_run(Map.get(running_entry, :run_id), %{state: "needs_input", error: "#{watchdog_label} exceeded"})
        :ok

      {comment_error, state_error} ->
        Logger.error(
          "#{String.capitalize(watchdog_label)} failed to report pause for issue_id=#{issue_id} issue_identifier=#{identifier}: comment_result=#{inspect(comment_error)} state_result=#{inspect(state_error)}"
        )
    end

    terminate_running_issue(state, issue_id, false)
  end

  defp artifact_watchdog_label(:first_artifact), do: "first-artifact watchdog"
  defp artifact_watchdog_label(:repo_artifact_nudge_exhausted), do: "artifact nudge watchdog"
  defp artifact_watchdog_label(:standard_artifact), do: "artifact watchdog"

  defp tokens_without_artifact(running_entry) when is_map(running_entry) do
    total = Map.get(running_entry, :codex_total_tokens, 0)
    baseline = Map.get(running_entry, :artifact_baseline_total_tokens, 0)

    if is_integer(total) and is_integer(baseline) do
      max(0, total - baseline)
    else
      0
    end
  end

  defp tokens_without_repo_artifact(running_entry) when is_map(running_entry) do
    total = Map.get(running_entry, :codex_total_tokens, 0)
    baseline = Map.get(running_entry, :repo_artifact_baseline_total_tokens, 0)

    if is_integer(total) and is_integer(baseline) do
      max(0, total - baseline)
    else
      0
    end
  end

  defp reset_artifact_progress(%State{} = state, issue_id, reason, timestamp, attrs, opts \\ [])
       when is_binary(issue_id) and is_binary(reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      running_entry ->
        repo_artifact? = Keyword.get(opts, :repo_artifact, false)
        health = health_after_artifact_progress(running_entry)

        artifact_attrs = %{
          artifact_baseline_total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
          last_artifact_timestamp: timestamp,
          last_artifact_reason: reason,
          health: health
        }

        repo_attrs =
          if repo_artifact? do
            %{
              repo_artifact_baseline_total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
              last_repo_artifact_timestamp: timestamp,
              last_repo_artifact_reason: reason,
              artifact_nudge_count: 0
            }
          else
            %{}
          end

        state =
          if repo_artifact? do
            clear_artifact_nudge_count(state, issue_id)
          else
            state
          end

        updated_running_entry =
          running_entry
          |> Map.merge(artifact_attrs)
          |> Map.merge(repo_attrs)
          |> Map.merge(attrs)

        persist_health_after_artifact_progress(running_entry, updated_running_entry, issue_id, reason)

        %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
    end
  end

  defp health_after_artifact_progress(running_entry) when is_map(running_entry) do
    running_entry
    |> Map.get(:health, ["healthy"])
    |> normalize_health_flags()
    |> Enum.reject(&(&1 in @proof_health_warning_flags))
    |> normalize_health_flags()
  end

  defp persist_health_after_artifact_progress(previous_entry, updated_entry, issue_id, reason) do
    previous_health = normalize_health_flags(Map.get(previous_entry, :health, ["healthy"]))
    next_health = normalize_health_flags(Map.get(updated_entry, :health, ["healthy"]))

    if next_health != previous_health do
      run_id = Map.get(updated_entry, :run_id)
      issue_session_id = Map.get(updated_entry, :issue_session_id)

      if is_binary(run_id) do
        _ =
          Storage.append_event(run_id, "info", "artifact observed; proof warning cleared", %{
            issue_id: issue_id,
            issue_session_id: issue_session_id,
            reason: reason,
            health: next_health,
            last_artifact: last_artifact_summary(updated_entry),
            last_repo_artifact: last_repo_artifact_summary(updated_entry)
          })

        _ = Storage.update_run(run_id, %{health: next_health, session_state: Map.get(updated_entry, :session_state)})
      end

      if is_binary(issue_session_id) do
        _ = Storage.update_issue_session(issue_session_id, %{health: next_health})
      end
    end

    :ok
  end

  defp artifact_watchdog_comment(running_entry, tokens_without_artifact, threshold, watchdog_kind) do
    issue = Map.get(running_entry, :issue, %Issue{})
    workspace = Map.get(running_entry, :workspace_path)
    explanation = artifact_watchdog_explanation(watchdog_kind)

    """
    ## Symphony paused: no inspectable artifact

    Symphony stopped this autonomous Codex run because #{explanation}.

    - Issue: `#{issue.identifier || issue.id || Map.get(running_entry, :identifier)}`
    - Session: `#{running_entry_session_id(running_entry)}`
    - Workspace: `#{workspace || "unknown"}`
    - Watchdog: `#{artifact_watchdog_comment_kind(watchdog_kind)}`
    - Tokens without artifact: `#{tokens_without_artifact}`
    - Threshold: `#{threshold}`
    - Last event: `#{inspect(Map.get(running_entry, :last_codex_event))}`
    - Last artifact: `#{last_artifact_summary(running_entry)}`
    - Last repo artifact: `#{last_repo_artifact_summary(running_entry)}`
    - Last handoff progress: `#{last_handoff_progress_summary(running_entry)}`
    - Artifact nudges sent: `#{Map.get(running_entry, :artifact_nudge_count, 0)}`

    Artifacts currently counted by Symphony are non-empty Codex diff events, local workspace git changes, the local `.symphony/workpad.md` run ledger, and updates to the durable GitHub `## Codex Workpad` comment. When repo changes already exist, validation and PR handoff commands count as handoff progress so Symphony keeps Codex moving toward review instead of demanding another code diff. Plain status narration and reasoning text do not reset this watchdog.
    """
  end

  defp artifact_watchdog_explanation(watchdog_kind) do
    Map.get(
      %{
        first_artifact: "it exceeded the first-artifact budget before producing inspectable repo proof",
        repo_artifact_nudge_exhausted: "it exhausted its artifact nudge budget without producing new inspectable repo proof",
        standard_artifact: "it spent too many tokens without producing a new inspectable artifact"
      },
      watchdog_kind,
      "it spent too many tokens without producing a new inspectable artifact"
    )
  end

  defp artifact_watchdog_comment_kind(watchdog_kind) do
    Map.get(
      %{
        first_artifact: "first-artifact",
        repo_artifact_nudge_exhausted: "artifact-nudge",
        standard_artifact: "standard"
      },
      watchdog_kind,
      "standard"
    )
  end

  defp last_artifact_summary(running_entry) do
    reason = Map.get(running_entry, :last_artifact_reason, "run started")

    case Map.get(running_entry, :last_artifact_timestamp) do
      %DateTime{} = timestamp -> "#{reason} at #{DateTime.to_iso8601(timestamp)}"
      _ -> reason
    end
  end

  defp last_repo_artifact_summary(running_entry) do
    reason = Map.get(running_entry, :last_repo_artifact_reason, "run started")

    case Map.get(running_entry, :last_repo_artifact_timestamp) do
      %DateTime{} = timestamp -> "#{reason} at #{DateTime.to_iso8601(timestamp)}"
      _ -> reason
    end
  end

  defp last_handoff_progress_summary(running_entry) do
    reason = Map.get(running_entry, :last_handoff_progress_reason, "none")

    case Map.get(running_entry, :last_handoff_progress_timestamp) do
      %DateTime{} = timestamp -> "#{reason} at #{DateTime.to_iso8601(timestamp)}"
      _ -> reason
    end
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp terminate_worker_process(%{session_kind: :durable, session_state: :parked}, pid) when is_pid(pid) do
    case IssueSession.stop(pid, :orchestrator_stop) do
      :ok -> :ok
      _ -> Process.exit(pid, :shutdown)
    end
  catch
    :exit, _ -> Process.exit(pid, :shutdown)
  end

  defp terminate_worker_process(%{session_kind: :durable}, pid) when is_pid(pid) do
    Process.exit(pid, :shutdown)
  end

  defp terminate_worker_process(_running_entry, pid), do: terminate_task(pid)

  defp choose_issues_after_preflight(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    if Enum.any?(issues, &should_dispatch_issue?(&1, state, active_states, terminal_states)) do
      case Tracker.preflight() do
        :ok ->
          choose_issues(issues, state, active_states, terminal_states)

        {:error, reason} ->
          Logger.error("Tracker preflight failed before dispatch: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp choose_issues(issues, state, active_states, terminal_states) do
    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, operator_paused_issue_ids: operator_paused_issue_ids} = state,
         active_states,
         terminal_states
       ) do
    parked_resume? = parked_durable_issue_session?(Map.get(running, issue.id))

    dispatchable_issue_state?(issue, active_states, terminal_states, operator_paused_issue_ids) and
      dispatchable_claim_state?(issue, running, claimed, parked_resume?) and
      dispatch_capacity_available?(issue, state, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp dispatchable_issue_state?(issue, active_states, terminal_states, operator_paused_issue_ids) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(operator_paused_issue_ids, issue.id) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatchable_claim_state?(issue, running, claimed, parked_resume?) do
    (!MapSet.member?(claimed, issue.id) or parked_resume?) and
      (!Map.has_key?(running, issue.id) or parked_resume?)
  end

  defp dispatch_capacity_available?(issue, state, running) do
    available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{session_state: :parked}} ->
        false

      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp human_review_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "human-review"
  end

  defp human_review_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[\s_]+/, "-")
  end

  defp normalize_issue_state(_state_name), do: ""

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, agent_opts \\ []) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        case claim_issue_for_dispatch(refreshed_issue) do
          {:ok, %Issue{} = claimed_issue} ->
            do_dispatch_issue(state, claimed_issue, attempt, preferred_worker_host, agent_opts)

          {:error, reason} ->
            handle_claim_failure(state, refreshed_issue, reason)
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp claim_issue_for_dispatch(%Issue{} = issue) do
    case normalize_issue_state(issue.state) do
      state when state in ["todo", "rework"] ->
        case Tracker.update_issue_state(issue.id, "In Progress") do
          :ok -> {:ok, %{issue | state: "In Progress"}}
          {:error, reason} -> {:error, {:claim_failed, reason}}
        end

      _state ->
        {:ok, issue}
    end
  end

  defp handle_claim_failure(%State{} = state, %Issue{} = issue, reason) do
    Logger.error("Unable to claim issue before dispatch: #{issue_context(issue)} reason=#{inspect(reason)}")

    comment_result = Tracker.create_comment(issue.id, claim_failure_comment(issue, reason))
    state_result = Tracker.update_issue_state(issue.id, "Needs Input")

    unless comment_result == :ok and state_result == :ok do
      Logger.error("Failed to report claim failure for #{issue_context(issue)} comment_result=#{inspect(comment_result)} state_result=#{inspect(state_result)}")
    end

    state
  end

  defp claim_failure_comment(%Issue{} = issue, reason) do
    """
    ## Symphony paused: claim failed

    Symphony did not start a Codex worker because it could not claim this issue first.

    - Issue: `#{issue.identifier || issue.id}`
    - Reason: `#{inspect(reason)}`

    This usually means GitHub auth, repository access, or required workflow labels need operator attention.
    """
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, agent_opts) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, agent_opts)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, agent_opts) do
    cond do
      durable_local_issue_session_enabled?(worker_host) and parked_durable_issue_session?(Map.get(state.running, issue.id)) ->
        resume_existing_issue_session(state, issue, attempt, worker_host, agent_opts)

      durable_local_issue_session_enabled?(worker_host) ->
        spawn_durable_issue_session(state, issue, attempt, recipient, worker_host, agent_opts)

      true ->
        spawn_legacy_agent_runner(state, issue, attempt, recipient, worker_host, agent_opts)
    end
  end

  defp spawn_legacy_agent_runner(%State{} = state, issue, attempt, recipient, worker_host, agent_opts) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, agent_runner_opts(attempt, worker_host, agent_opts))
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        started_at = DateTime.utc_now()

        artifact_nudge_count =
          [Keyword.get(agent_opts, :artifact_nudge_count, 0), Map.get(state.artifact_nudge_counts, issue.id, 0)]
          |> Enum.filter(&is_integer/1)
          |> Enum.max(fn -> 0 end)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")
        run_id = create_run_record(issue, worker_host)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: Keyword.get(agent_opts, :workspace_path),
            run_id: run_id,
            session_kind: :legacy,
            session_state: :running,
            issue_session_id: nil,
            thread_id: nil,
            health: ["healthy"],
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            last_semantic_activity_timestamp: nil,
            last_semantic_activity_reason: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: started_at,
            artifact_baseline_total_tokens: 0,
            last_artifact_timestamp: started_at,
            last_artifact_reason: "run started",
            repo_artifact_baseline_total_tokens: 0,
            last_repo_artifact_timestamp: started_at,
            last_repo_artifact_reason: "run started",
            handoff_progress_baseline_total_tokens: 0,
            last_handoff_progress_timestamp: nil,
            last_handoff_progress_reason: nil,
            last_handoff_progress_fingerprint: nil,
            artifact_nudge_count: artifact_nudge_count,
            last_workspace_artifact_fingerprint: Keyword.get(agent_opts, :last_workspace_artifact_fingerprint),
            last_codex_diff_artifact_fingerprint: Keyword.get(agent_opts, :last_codex_diff_artifact_fingerprint),
            codex_activity_trace: []
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp spawn_durable_issue_session(%State{} = state, issue, attempt, recipient, worker_host, agent_opts) do
    recoverable_session = recoverable_issue_session_for_issue(issue)
    issue_session_id = recoverable_session_id(recoverable_session) || create_issue_session_record(issue)
    run_id = create_run_record(issue, worker_host, issue_session_id)
    agent_opts = recovered_issue_session_agent_opts(agent_opts, recoverable_session, issue)

    opts =
      agent_runner_opts(attempt, worker_host, agent_opts)
      |> Keyword.put(:issue_session_id, issue_session_id)
      |> Keyword.put(:run_id, run_id)

    child_opts = Keyword.merge([issue: issue, recipient: recipient], opts)

    case DynamicSupervisor.start_child(SymphonyElixir.IssueSessionSupervisor, {IssueSession, child_opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        started_at = DateTime.utc_now()

        Logger.info("Dispatching issue to durable Codex session: #{issue_context(issue)} pid=#{inspect(pid)} run_id=#{run_id}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: Keyword.get(opts, :workspace_path),
            run_id: run_id,
            issue_session_id: issue_session_id,
            session_kind: :durable,
            session_state: :running,
            health: ["healthy"],
            thread_id: Keyword.get(opts, :resume_thread_id),
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            last_semantic_activity_timestamp: nil,
            last_semantic_activity_reason: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: started_at,
            artifact_baseline_total_tokens: 0,
            last_artifact_timestamp: started_at,
            last_artifact_reason: "run started",
            repo_artifact_baseline_total_tokens: 0,
            last_repo_artifact_timestamp: started_at,
            last_repo_artifact_reason: "run started",
            handoff_progress_baseline_total_tokens: 0,
            last_handoff_progress_timestamp: nil,
            last_handoff_progress_reason: nil,
            last_handoff_progress_fingerprint: nil,
            artifact_nudge_count: 0,
            last_workspace_artifact_fingerprint: Keyword.get(agent_opts, :last_workspace_artifact_fingerprint),
            last_codex_diff_artifact_fingerprint: Keyword.get(agent_opts, :last_codex_diff_artifact_fingerprint),
            codex_activity_trace: []
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn durable issue session for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        _ = Storage.update_issue_session(issue_session_id, %{state: "failed", stop_reason: inspect(reason), health: ["failed"]})
        _ = Storage.update_run(run_id, %{state: "failed", error: inspect(reason), health: ["failed"]})

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn durable issue session: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp recoverable_issue_session_for_issue(%Issue{} = issue) do
    Storage.list_issue_sessions()
    |> Enum.find(&recoverable_issue_session_match?(&1, issue))
  rescue
    _ -> nil
  end

  defp recoverable_issue_session_match?(%{"state" => state} = session, %Issue{} = issue)
       when state in ["interrupted-resumable", "parked"] do
    same_repo_issue_number?(session, issue) or same_issue_identifier?(session, issue)
  end

  defp recoverable_issue_session_match?(_session, _issue), do: false

  defp same_repo_issue_number?(session, %Issue{repo_id: repo_id, number: number})
       when is_binary(repo_id) and is_integer(number) do
    Map.get(session, "repo_id") == repo_id and Map.get(session, "issue_number") == number
  end

  defp same_repo_issue_number?(_session, _issue), do: false

  defp same_issue_identifier?(session, %Issue{identifier: identifier}) when is_binary(identifier) do
    Map.get(session, "issue_identifier") == identifier
  end

  defp same_issue_identifier?(_session, _issue), do: false

  defp recoverable_session_id(%{"id" => id}) when is_binary(id), do: id
  defp recoverable_session_id(_session), do: nil

  defp recovered_issue_session_agent_opts(agent_opts, nil, _issue), do: agent_opts

  defp recovered_issue_session_agent_opts(agent_opts, session, %Issue{} = issue) when is_map(session) do
    capsule = %{
      workspace_path: Map.get(session, "workspace_path"),
      stop_reason: Map.get(session, "stop_reason"),
      pr_url: issue.pr_url,
      issue_session_id: Map.get(session, "id")
    }

    agent_opts
    |> maybe_put_keyword(:workspace_path, Map.get(session, "workspace_path"))
    |> maybe_put_keyword(:resume_thread_id, Map.get(session, "codex_thread_id"))
    |> maybe_put_keyword(:restart_capsule, capsule)
  end

  defp resume_existing_issue_session(%State{} = state, issue, attempt, worker_host, agent_opts) do
    case Map.get(state.running, issue.id) do
      %{pid: pid, issue_session_id: issue_session_id} = running_entry when is_pid(pid) ->
        run_id = create_run_record(issue, worker_host, issue_session_id)

        opts =
          agent_runner_opts(attempt, worker_host, run_resume_agent_opts(running_entry, run_id) ++ agent_opts)
          |> Keyword.put(:issue_session_id, issue_session_id)
          |> Keyword.put(:run_id, run_id)

        case IssueSession.resume(pid, issue, opts) do
          :ok ->
            Logger.info("Dispatch resumed parked durable issue session: #{issue_context(issue)} run_id=#{run_id}")

            updated_entry =
              running_entry
              |> Map.merge(%{
                issue: issue,
                run_id: run_id,
                session_state: :running,
                health: ["healthy"],
                stop_reason: nil,
                parked_at: nil
              })

            %{
              state
              | running: Map.put(state.running, issue.id, updated_entry),
                retry_attempts: Map.delete(state.retry_attempts, issue.id)
            }

          {:error, reason} ->
            Logger.warning("Unable to resume durable issue session for #{issue_context(issue)}: #{inspect(reason)}")
            state
        end

      _ ->
        state
    end
  end

  defp agent_runner_opts(attempt, worker_host, agent_opts) when is_list(agent_opts) do
    [attempt: attempt, worker_host: worker_host]
    |> Keyword.merge(agent_opts)
  end

  defp create_issue_session_record(%Issue{} = issue), do: RunLedger.create_issue_session_record(issue)

  defp create_run_record(%Issue{} = issue, worker_host, issue_session_id \\ nil) do
    RunLedger.create_run_record(issue, worker_host, issue_session_id)
  end

  defp run_resume_agent_opts(running_entry, run_id) do
    issue = Map.get(running_entry, :issue)
    pr_url = if match?(%Issue{}, issue), do: issue.pr_url, else: nil

    [
      workspace_path: Map.get(running_entry, :workspace_path),
      run_id: run_id,
      issue_session_id: Map.get(running_entry, :issue_session_id),
      pr_url: pr_url
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp persist_codex_update(%{run_id: run_id} = running_entry, update) when is_binary(run_id) do
    RunLedger.persist_codex_update(running_entry, update)
  end

  defp persist_codex_update(_running_entry, _update), do: :ok

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp clear_issue_runtime_state(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.delete(state.completed, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        operator_paused_issue_ids: MapSet.delete(state.operator_paused_issue_ids, issue_id)
    }
  end

  defp add_operator_paused_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | operator_paused_issue_ids: MapSet.put(state.operator_paused_issue_ids, issue_id)}
  end

  defp add_operator_paused_issue(%State{} = state, _issue_id), do: state

  defp pause_issue_for_operator(issue_id, running_entry, reason) when is_binary(issue_id) and is_map(running_entry) do
    issue = Map.get(running_entry, :issue)
    run_id = Map.get(running_entry, :run_id)
    issue_session_id = Map.get(running_entry, :issue_session_id)

    _ =
      Storage.append_event(run_id, "warning", "operator paused issue session", %{
        issue_id: issue_id,
        issue_session_id: issue_session_id,
        reason: reason
      })

    _ =
      Storage.update_issue_session(issue_session_id, %{
        state: operator_pause_session_state(reason),
        stop_reason: operator_pause_reason(reason),
        health: ["needs-input"]
      })

    comment_result =
      case issue do
        %Issue{} -> Tracker.create_comment(issue_id, operator_pause_comment(issue, running_entry, reason))
        _ -> :ok
      end

    state_result = Tracker.update_issue_state(issue_id, "Needs Input")

    case {comment_result, state_result} do
      {:ok, :ok} ->
        :ok

      {comment_error, state_error} ->
        Logger.warning("Operator pause report was not fully delivered for #{issue_id}: comment_result=#{inspect(comment_error)} state_result=#{inspect(state_error)}")
        {:error, %{comment_result: comment_error, state_result: state_error}}
    end
  end

  defp pause_issue_for_operator(_issue_id, _running_entry, _reason), do: :ok

  defp resume_issue_from_operator_pause(issue_id) when is_binary(issue_id) do
    case Tracker.update_issue_state(issue_id, "In Progress") do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Unable to move rerun issue #{issue_id} to In Progress: #{inspect(reason)}")
        error
    end
  end

  defp operator_pause_reason(:run_cancelled), do: "operator cancelled run"
  defp operator_pause_reason(:session_stopped), do: "operator stopped issue session"

  defp operator_pause_session_state(:run_cancelled), do: "interrupted-resumable"
  defp operator_pause_session_state(:session_stopped), do: "stopped"

  defp operator_pause_comment(%Issue{} = issue, running_entry, reason) do
    """
    ## Symphony paused: #{operator_pause_reason(reason)}

    Symphony stopped the active Codex worker and moved this issue to `needs-input` so it will not be redispatched automatically.

    - Issue: `#{issue.identifier || issue.id}`
    - Run: `#{Map.get(running_entry, :run_id) || "unknown"}`
    - Issue session: `#{Map.get(running_entry, :issue_session_id) || "unknown"}`
    - Workspace: `#{Map.get(running_entry, :workspace_path) || "unknown"}`

    Use rerun/resume from the cockpit when you want Symphony to continue this issue.
    """
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    delay_type = pick_retry_delay_type(previous_retry, metadata)
    artifact_nudge_count = pick_retry_artifact_nudge_count(previous_retry, metadata)
    artifact_nudge = pick_retry_artifact_nudge(previous_retry, metadata)

    last_workspace_artifact_fingerprint =
      pick_retry_value(previous_retry, metadata, :last_workspace_artifact_fingerprint)

    last_codex_diff_artifact_fingerprint =
      pick_retry_value(previous_retry, metadata, :last_codex_diff_artifact_fingerprint)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            delay_type: delay_type,
            artifact_nudge_count: artifact_nudge_count,
            artifact_nudge: artifact_nudge,
            last_workspace_artifact_fingerprint: last_workspace_artifact_fingerprint,
            last_codex_diff_artifact_fingerprint: last_codex_diff_artifact_fingerprint
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          delay_type: Map.get(retry_entry, :delay_type),
          artifact_nudge_count: Map.get(retry_entry, :artifact_nudge_count),
          artifact_nudge: Map.get(retry_entry, :artifact_nudge),
          last_workspace_artifact_fingerprint: Map.get(retry_entry, :last_workspace_artifact_fingerprint),
          last_codex_diff_artifact_fingerprint: Map.get(retry_entry, :last_codex_diff_artifact_fingerprint)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp preserve_human_review_storage_runs do
    case Tracker.fetch_issues_by_states(["Human Review", "human-review"]) do
      {:ok, issues} ->
        runs = Storage.list_runs(500)
        issue_sessions = Storage.list_issue_sessions()

        Enum.each(issues, fn
          %Issue{} = issue -> preserve_human_review_storage_for_issue(issue, runs, issue_sessions)
          _issue -> :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup human-review recovery; failed to fetch review-ready issues: #{inspect(reason)}")
    end
  end

  defp preserve_human_review_storage_for_issue(%Issue{} = issue, runs, issue_sessions)
       when is_list(runs) and is_list(issue_sessions) do
    matching_runs =
      Enum.filter(runs, fn run ->
        startup_recoverable_run?(run) and storage_row_matches_issue?(run, issue)
      end)

    Enum.each(matching_runs, &park_human_review_storage_run(&1, issue, issue_sessions))

    matching_run_session_ids =
      matching_runs
      |> Enum.flat_map(fn
        %{"issue_session_id" => issue_session_id} when is_binary(issue_session_id) -> [issue_session_id]
        _run -> []
      end)
      |> MapSet.new()

    issue_sessions
    |> Enum.filter(&storage_row_matches_issue?(&1, issue))
    |> Enum.reject(&(Map.get(&1, "id") in matching_run_session_ids))
    |> Enum.each(&park_human_review_issue_session(&1))
  end

  defp park_human_review_storage_run(%{"id" => run_id} = run, %Issue{} = issue, issue_sessions)
       when is_binary(run_id) and is_list(issue_sessions) do
    issue_session = issue_session_for_run(run, issue_sessions)
    issue_session_id = Map.get(run, "issue_session_id") || Map.get(issue_session || %{}, "id")
    parked_at = DateTime.utc_now()

    RunLedger.park_issue_session(
      %{
        run_id: run_id,
        issue_session_id: issue_session_id,
        issue: issue,
        workspace_path: Map.get(run, "workspace_path") || Map.get(issue_session || %{}, "workspace_path"),
        thread_id: Map.get(run, "thread_id") || Map.get(issue_session || %{}, "codex_thread_id"),
        turn_count: Map.get(run, "turn_count") || 0,
        health: ["parked"],
        stop_reason: "human_review"
      },
      parked_at
    )

    _ = Storage.update_issue_session(issue_session_id, %{app_server_pid: nil})

    _ =
      Storage.append_event(run_id, "info", "startup recovery preserved human-review handoff", %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_session_id: issue_session_id,
        pr_url: issue.pr_url
      })

    :ok
  end

  defp park_human_review_storage_run(_run, _issue, _issue_sessions), do: :ok

  defp startup_recoverable_run?(%{"state" => "running"}), do: true

  defp startup_recoverable_run?(%{"state" => "cancelled", "error" => reason}) do
    startup_interruption_reason?(reason)
  end

  defp startup_recoverable_run?(_run), do: false

  defp park_human_review_issue_session(%{"id" => issue_session_id} = issue_session)
       when is_binary(issue_session_id) do
    if startup_recoverable_issue_session?(issue_session) do
      parked_at = Map.get(issue_session, "parked_at") || timestamp()

      _ =
        Storage.update_issue_session(issue_session_id, %{
          state: "parked",
          app_server_pid: nil,
          health: ["parked"],
          parked_at: parked_at,
          stop_reason: "human_review"
        })
    end

    :ok
  end

  defp park_human_review_issue_session(_issue_session), do: :ok

  defp startup_recoverable_issue_session?(%{"state" => state})
       when state in ["starting", "running", "parked"],
       do: true

  defp startup_recoverable_issue_session?(%{"state" => "interrupted-resumable", "stop_reason" => reason}) do
    startup_interruption_reason?(reason)
  end

  defp startup_recoverable_issue_session?(_issue_session), do: false

  defp startup_interruption_reason?(reason) when is_binary(reason) do
    String.starts_with?(reason, "interrupted on Symphony startup")
  end

  defp startup_interruption_reason?(_reason), do: false

  defp issue_session_for_run(run, issue_sessions) when is_map(run) and is_list(issue_sessions) do
    issue_session_id = Map.get(run, "issue_session_id")

    Enum.find(issue_sessions, &(is_binary(issue_session_id) and Map.get(&1, "id") == issue_session_id)) ||
      Enum.find(issue_sessions, &storage_rows_match?(&1, run))
  end

  defp storage_row_matches_issue?(row, %Issue{} = issue) when is_map(row) do
    same_repo_issue_number?(row, issue) or same_issue_identifier?(row, issue) or Map.get(row, "issue_identifier") == issue.id
  end

  defp storage_row_matches_issue?(_row, _issue), do: false

  defp storage_rows_match?(left, right) when is_map(left) and is_map(right) do
    same_storage_repo_issue_number?(left, right) or same_storage_issue_identifier?(left, right)
  end

  defp storage_rows_match?(_left, _right), do: false

  defp same_storage_repo_issue_number?(left, right) do
    is_binary(Map.get(left, "repo_id")) and is_integer(Map.get(left, "issue_number")) and
      Map.get(left, "repo_id") == Map.get(right, "repo_id") and
      Map.get(left, "issue_number") == Map.get(right, "issue_number")
  end

  defp same_storage_issue_identifier?(left, right) do
    is_binary(Map.get(left, "issue_identifier")) and Map.get(left, "issue_identifier") == Map.get(right, "issue_identifier")
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp interrupt_stale_storage_runs do
    case Storage.interrupt_running_runs("interrupted on Symphony startup before live worker recovery") do
      {:ok, count} when count > 0 ->
        Logger.warning("Marked #{count} stale persisted run(s) interrupted during startup recovery")

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Skipping startup run-ledger recovery; failed to mark stale runs: #{inspect(reason)}")
    end
  end

  defp interrupt_stale_issue_sessions do
    case Storage.interrupt_running_issue_sessions("interrupted on Symphony startup; Codex app-server thread did not survive daemon restart") do
      {:ok, count} when count > 0 ->
        Logger.warning("Marked #{count} stale issue session(s) interrupted during startup recovery")

      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Skipping startup issue-session recovery; failed to mark stale sessions: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], retry_agent_opts(metadata))}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp retry_agent_opts(metadata) when is_map(metadata) do
    []
    |> maybe_put_keyword(:workspace_path, metadata[:workspace_path])
    |> maybe_put_keyword(:artifact_nudge_count, metadata[:artifact_nudge_count])
    |> maybe_put_keyword(:artifact_nudge, metadata[:artifact_nudge])
    |> maybe_put_keyword(:last_workspace_artifact_fingerprint, metadata[:last_workspace_artifact_fingerprint])
    |> maybe_put_keyword(:last_codex_diff_artifact_fingerprint, metadata[:last_codex_diff_artifact_fingerprint])
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        artifact_nudge_counts: Map.delete(state.artifact_nudge_counts, issue_id)
    }
  end

  defp artifact_nudge_count(%State{} = state, issue_id, running_entry) do
    persisted_count = Map.get(state.artifact_nudge_counts, issue_id, 0)
    running_count = Map.get(running_entry, :artifact_nudge_count, 0)

    [persisted_count, running_count]
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp put_artifact_nudge_count(%State{} = state, issue_id, count)
       when is_binary(issue_id) and is_integer(count) and count > 0 do
    %{state | artifact_nudge_counts: Map.put(state.artifact_nudge_counts, issue_id, count)}
  end

  defp put_artifact_nudge_count(%State{} = state, _issue_id, _count), do: state

  defp clear_artifact_nudge_count(%State{} = state, issue_id) when is_binary(issue_id) do
    %{state | artifact_nudge_counts: Map.delete(state.artifact_nudge_counts, issue_id)}
  end

  defp clear_artifact_nudge_count(%State{} = state, _issue_id), do: state

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case metadata[:delay_type] do
      :artifact_nudge ->
        @artifact_nudge_retry_delay_ms

      :continuation when attempt == 1 ->
        @continuation_retry_delay_ms

      _ ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_delay_type(previous_retry, metadata) do
    metadata[:delay_type] || Map.get(previous_retry, :delay_type)
  end

  defp pick_retry_artifact_nudge_count(previous_retry, metadata) do
    metadata[:artifact_nudge_count] || Map.get(previous_retry, :artifact_nudge_count)
  end

  defp pick_retry_artifact_nudge(previous_retry, metadata) do
    metadata[:artifact_nudge] || Map.get(previous_retry, :artifact_nudge)
  end

  defp pick_retry_value(previous_retry, metadata, key) when is_map(previous_retry) and is_map(metadata) do
    Map.get(metadata, key) || Map.get(previous_retry, key)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp durable_local_issue_session_enabled?(nil) do
    settings = Config.settings!()
    settings.runtime_profile == "local_trusted" and settings.tracker.kind == "github"
  end

  defp durable_local_issue_session_enabled?(_worker_host), do: false

  defp durable_session_entry?(%{session_kind: :durable}), do: true
  defp durable_session_entry?(_entry), do: false

  defp parked_durable_issue_session?(%{session_kind: :durable, session_state: :parked}), do: true
  defp parked_durable_issue_session?(_entry), do: false

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{session_state: :parked}} -> false
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        active_running_count(state.running),
      0
    )
  end

  defp active_running_count(running) when is_map(running) do
    Enum.count(running, fn
      {_issue_id, %{session_state: :parked}} -> false
      _entry -> true
    end)
  end

  defp active_running_count(_running), do: 0

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if server_available?(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec cancel_run(String.t()) :: {:ok, map()} | {:error, :run_not_found | :unavailable}
  def cancel_run(run_id), do: cancel_run(run_id, __MODULE__)

  @spec cancel_run(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :run_not_found | :unavailable}
  def cancel_run(run_id, server) when is_binary(run_id) do
    if server_available?(server) do
      GenServer.call(server, {:cancel_run, run_id})
    else
      {:error, :unavailable}
    end
  end

  @spec rerun_issue(String.t(), String.t() | integer()) :: {:ok, map()} | {:error, :unavailable}
  def rerun_issue(repo_id, number), do: rerun_issue(repo_id, number, __MODULE__)

  @spec rerun_issue(String.t(), String.t() | integer(), GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def rerun_issue(repo_id, number, server) when is_binary(repo_id) do
    if server_available?(server) do
      GenServer.call(server, {:rerun_issue, repo_id, number})
    else
      {:error, :unavailable}
    end
  end

  @spec merge_issue_pr(String.t(), String.t() | integer()) ::
          {:ok, map()} | {:error, :issue_not_found | :unavailable | {:merge_gate_blocked, [String.t()]} | term()}
  def merge_issue_pr(repo_id, number), do: merge_issue_pr(repo_id, number, __MODULE__)

  @spec merge_issue_pr(String.t(), String.t() | integer(), GenServer.server()) ::
          {:ok, map()} | {:error, :issue_not_found | :unavailable | {:merge_gate_blocked, [String.t()]} | term()}
  def merge_issue_pr(repo_id, number, server) when is_binary(repo_id) do
    if server_available?(server) do
      GenServer.call(server, {:merge_issue_pr, repo_id, number})
    else
      {:error, :unavailable}
    end
  end

  @spec stop_issue_session(String.t(), String.t() | integer()) ::
          {:ok, map()} | {:error, :session_not_found | :unavailable}
  def stop_issue_session(repo_id, number), do: stop_issue_session(repo_id, number, __MODULE__)

  @spec stop_issue_session(String.t(), String.t() | integer(), GenServer.server()) ::
          {:ok, map()} | {:error, :session_not_found | :unavailable}
  def stop_issue_session(repo_id, number, server) when is_binary(repo_id) do
    if server_available?(server) do
      GenServer.call(server, {:stop_issue_session, repo_id, number})
    else
      {:error, :unavailable}
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if server_available?(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp server_available?(_server), do: false

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          repo_id: metadata.issue.repo_id,
          issue_number: metadata.issue.number,
          run_id: Map.get(metadata, :run_id),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          issue_session_id: Map.get(metadata, :issue_session_id),
          session_kind: Map.get(metadata, :session_kind),
          session_state: Map.get(metadata, :session_state),
          health: Map.get(metadata, :health, ["healthy"]),
          thread_id: Map.get(metadata, :thread_id),
          pr_url: metadata.issue.pr_url,
          pr_state: metadata.issue.pr_state,
          check_state: metadata.issue.check_state,
          review_state: metadata.issue.review_state,
          parked_at: Map.get(metadata, :parked_at),
          stop_reason: Map.get(metadata, :stop_reason),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          tokens_without_artifact: tokens_without_artifact(metadata),
          tokens_without_repo_artifact: tokens_without_repo_artifact(metadata),
          last_artifact_timestamp: Map.get(metadata, :last_artifact_timestamp),
          last_artifact_reason: Map.get(metadata, :last_artifact_reason),
          last_repo_artifact_timestamp: Map.get(metadata, :last_repo_artifact_timestamp),
          last_repo_artifact_reason: Map.get(metadata, :last_repo_artifact_reason),
          artifact_nudge_count: Map.get(metadata, :artifact_nudge_count, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          last_semantic_activity_timestamp: Map.get(metadata, :last_semantic_activity_timestamp),
          last_semantic_activity_reason: Map.get(metadata, :last_semantic_activity_reason),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       operator_paused_issue_ids: MapSet.to_list(state.operator_paused_issue_ids),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    case Enum.find(state.running, fn {_issue_id, entry} -> Map.get(entry, :run_id) == run_id end) do
      {issue_id, running_entry} ->
        _ = Storage.append_event(run_id, "warning", "cancel requested", %{issue_id: issue_id})
        _ = Storage.update_run(run_id, %{state: "cancelled", error: "cancel requested"})
        pause_result = pause_issue_for_operator(issue_id, running_entry, :run_cancelled)
        state = terminate_running_issue(state, issue_id, false)
        state = add_operator_paused_issue(state, issue_id)
        notify_dashboard()

        {:reply,
         {:ok,
          %{
            run_id: run_id,
            issue_id: issue_id,
            issue_identifier: running_entry.identifier,
            paused: true,
            pause_state: "Needs Input",
            pause_result: pause_result
          }}, state}

      nil ->
        {:reply, {:error, :run_not_found}, state}
    end
  end

  def handle_call({:rerun_issue, repo_id, number}, _from, state) do
    number = to_string(number)
    composite_issue_id = "#{repo_id}##{number}"
    legacy_issue_id = number
    transition_result = resume_issue_from_operator_pause(composite_issue_id)

    state =
      state
      |> clear_issue_runtime_state(composite_issue_id)
      |> clear_issue_runtime_state(legacy_issue_id)
      |> schedule_tick(0)

    notify_dashboard()
    {:reply, {:ok, %{repo_id: repo_id, number: number, queued: true, transition_result: transition_result}}, state}
  end

  def handle_call({:merge_issue_pr, repo_id, number}, _from, state) do
    {reply, state} =
      case merge_issue_pr_now(repo_id, number) do
        {:ok, payload} ->
          state = mark_merged_issue_complete(state, Map.fetch!(payload, :repo_id), Map.fetch!(payload, :number))
          notify_dashboard()
          {{:ok, payload}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:stop_issue_session, repo_id, number}, _from, state) do
    number = number |> to_string() |> String.to_integer()

    case Enum.find(state.running, fn
           {_issue_id, %{issue: %Issue{repo_id: ^repo_id, number: ^number}, session_kind: :durable}} -> true
           _ -> false
         end) do
      {issue_id, running_entry} ->
        _ = Storage.append_event(Map.get(running_entry, :run_id), "warning", "manual issue session stop requested", %{issue_id: issue_id})
        _ = Storage.update_issue_session(Map.get(running_entry, :issue_session_id), %{state: "stopped", stop_reason: "manual stop", health: ["parked"]})
        pause_result = pause_issue_for_operator(issue_id, running_entry, :session_stopped)
        state = terminate_running_issue(state, issue_id, false)
        state = add_operator_paused_issue(state, issue_id)
        notify_dashboard()

        {:reply,
         {:ok,
          %{
            repo_id: repo_id,
            number: number,
            issue_id: issue_id,
            issue_session_id: Map.get(running_entry, :issue_session_id),
            paused: true,
            pause_state: "Needs Input",
            pause_result: pause_result
          }}, state}

      nil ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  defp merge_issue_pr_now(repo_id, number) do
    with {:ok, number} <- issue_number(number),
         {:ok, issue_snapshot} <- stored_issue_snapshot(repo_id, number),
         issue = AutonomousReview.issue_from_snapshot(issue_snapshot),
         latest_review = latest_autonomous_review_for_issue(repo_id, number),
         gate = AutonomousReview.merge_gate(issue, latest_review),
         :ok <- ensure_merge_gate_ready(gate),
         {:ok, merge_response} <- GitHub.Client.merge_pull_request(issue) do
      merged_issue = %{issue | state: "Done", pr_state: "MERGED"}
      post_merge_update = persist_successful_merge(merged_issue)

      append_issue_event(issue, "info", "cockpit merge requested", %{
        pr_url: issue.pr_url,
        head_sha: issue.head_sha,
        merge_gate_reasons: gate.reasons,
        merge_response: merge_response,
        post_merge_update: post_merge_update
      })

      {:ok,
       %{
         repo_id: repo_id,
         number: number,
         issue_identifier: issue.identifier,
         pr_url: issue.pr_url,
         head_sha: issue.head_sha,
         merge_response: merge_response,
         post_merge_update: post_merge_update
       }}
    else
      {:error, {:merge_gate_blocked, reasons}} = error ->
        append_issue_event(repo_id, number, "warning", "cockpit merge blocked", %{reasons: reasons})
        error

      {:error, reason} = error ->
        append_issue_event(repo_id, number, "error", "cockpit merge failed", %{reason: inspect(reason)})
        error
    end
  end

  defp ensure_merge_gate_ready(%{ready?: true}), do: :ok
  defp ensure_merge_gate_ready(%{reasons: reasons}), do: {:error, {:merge_gate_blocked, reasons}}

  defp persist_successful_merge(%Issue{} = merged_issue) do
    tracker_result = update_tracker_issue_done(merged_issue)
    snapshot_result = Storage.record_issue_snapshot(issue_snapshot_attrs(merged_issue))
    latest_run = latest_run_for_issue(merged_issue.repo_id, merged_issue.number)
    run_result = persist_merged_run(latest_run, merged_issue)
    issue_session_result = persist_merged_issue_session(latest_run)

    result = %{
      tracker: inspect(tracker_result),
      issue_snapshot: inspect(snapshot_result),
      run: inspect(run_result),
      issue_session: inspect(issue_session_result),
      run_id: latest_run && Map.get(latest_run, "id"),
      issue_session_id: latest_run && Map.get(latest_run, "issue_session_id")
    }

    warn_if_post_merge_update_failed(merged_issue, result)
    result
  end

  defp update_tracker_issue_done(%Issue{id: issue_id}) when is_binary(issue_id) do
    Tracker.update_issue_state(issue_id, "Done")
  end

  defp persist_merged_run(%{"id" => run_id} = run, %Issue{} = merged_issue) when is_binary(run_id) do
    Storage.update_run(run_id, %{
      state: "completed",
      issue_session_id: Map.get(run, "issue_session_id"),
      session_state: "stopped",
      health: ["merged"],
      pr_url: merged_issue.pr_url,
      pr_state: merged_issue.pr_state,
      check_state: merged_issue.check_state,
      review_state: merged_issue.review_state,
      error: nil
    })
  end

  defp persist_merged_run(_run, _merged_issue), do: :ok

  defp persist_merged_issue_session(%{"issue_session_id" => issue_session_id} = run) when is_binary(issue_session_id) do
    Storage.update_issue_session(issue_session_id, %{
      state: "stopped",
      current_run_id: Map.get(run, "id"),
      health: ["merged"],
      stop_reason: "merged"
    })
  end

  defp persist_merged_issue_session(_run), do: :ok

  defp warn_if_post_merge_update_failed(%Issue{} = issue, result) do
    failed =
      result
      |> Map.take([:tracker, :issue_snapshot, :run, :issue_session])
      |> Enum.reject(fn {_key, value} -> value == ":ok" end)

    if failed != [] do
      Logger.warning("Cockpit merge post-update was partially applied for #{issue_context(issue)}: #{inspect(Map.new(failed))}")
    end
  end

  defp issue_snapshot_attrs(%Issue{} = issue) do
    %{
      repo_id: issue.repo_id,
      number: issue.number,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      url: issue.url,
      labels: issue.labels,
      pr_url: issue.pr_url,
      head_sha: issue.head_sha,
      pr_state: issue.pr_state,
      check_state: issue.check_state,
      review_state: issue.review_state
    }
  end

  defp mark_merged_issue_complete(%State{} = state, repo_id, number) do
    number = to_string(number)

    ["#{repo_id}##{number}", number]
    |> Enum.uniq()
    |> Enum.reduce(state, fn issue_id, state_acc ->
      state_acc
      |> maybe_terminate_running_issue(issue_id)
      |> clear_issue_runtime_state(issue_id)
      |> complete_issue(issue_id)
      |> clear_operator_pause(issue_id)
    end)
  end

  defp maybe_terminate_running_issue(%State{} = state, issue_id) do
    if Map.has_key?(state.running, issue_id), do: terminate_running_issue(state, issue_id, false), else: state
  end

  defp clear_operator_pause(%State{} = state, issue_id) do
    %{state | operator_paused_issue_ids: MapSet.delete(state.operator_paused_issue_ids, issue_id)}
  end

  defp stored_issue_snapshot(repo_id, number) do
    case Enum.find(Storage.list_issues(), &stored_issue_snapshot_match?(&1, repo_id, number)) do
      nil -> {:error, :issue_not_found}
      issue_snapshot -> {:ok, issue_snapshot}
    end
  end

  defp stored_issue_snapshot_match?(%{"repo_id" => repo_id, "number" => number}, repo_id, number), do: true
  defp stored_issue_snapshot_match?(_issue_snapshot, _repo_id, _number), do: false

  defp latest_autonomous_review_for_issue(repo_id, number) do
    Enum.find(Storage.list_autonomous_reviews(250), fn review ->
      Map.get(review, "repo_id") == repo_id and stored_issue_number(Map.get(review, "issue_number")) == number
    end)
  end

  defp stored_issue_number(number) when is_integer(number), do: number

  defp stored_issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp stored_issue_number(_number), do: nil

  defp append_issue_event(%Issue{repo_id: repo_id, number: number}, level, message, data) do
    append_issue_event(repo_id, number, level, message, data)
  end

  defp append_issue_event(repo_id, number, level, message, data) do
    case latest_run_for_issue(repo_id, number) do
      %{"id" => run_id} -> Storage.append_event(run_id, level, message, data)
      _run -> :ok
    end
  end

  defp latest_run_for_issue(repo_id, number) do
    Enum.find(Storage.list_runs(250), fn run ->
      Map.get(run, "repo_id") == repo_id and Map.get(run, "issue_number") == number
    end)
  end

  defp issue_number(number) when is_integer(number), do: {:ok, number}

  defp issue_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_issue_number}
    end
  end

  defp issue_number(_number), do: {:error, :invalid_issue_number}

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    next_codex_total_tokens = codex_total_tokens + token_delta.total_tokens
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    updated_running_entry =
      running_entry
      |> Map.merge(%{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        thread_id: thread_id_for_update(Map.get(running_entry, :thread_id), update),
        last_codex_event: event,
        last_semantic_activity_timestamp: semantic_activity_timestamp_for_update(running_entry, update),
        last_semantic_activity_reason: semantic_activity_reason_for_update(running_entry, update),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: next_codex_total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        codex_activity_trace: append_codex_activity(Map.get(running_entry, :codex_activity_trace, []), update)
      })
      |> maybe_reset_artifact_progress_for_update(update, next_codex_total_tokens, timestamp)
      |> maybe_reset_handoff_progress_for_update(update, next_codex_total_tokens, timestamp)

    {updated_running_entry, token_delta}
  end

  defp semantic_activity_timestamp_for_update(running_entry, update) do
    update[:semantic_activity_at] ||
      Map.get(update, :semantic_activity_at) ||
      Map.get(running_entry, :last_semantic_activity_timestamp)
  end

  defp semantic_activity_reason_for_update(running_entry, update) do
    update[:semantic_activity_reason] ||
      Map.get(update, :semantic_activity_reason) ||
      Map.get(running_entry, :last_semantic_activity_reason)
  end

  defp append_codex_activity(trace, update) when is_list(trace) and is_map(update) do
    case codex_activity_summary(update) do
      nil ->
        trace

      summary ->
        trace
        |> Kernel.++([summary])
        |> Enum.take(-@codex_activity_trace_limit)
    end
  end

  defp append_codex_activity(_trace, update) when is_map(update), do: append_codex_activity([], update)

  defp codex_activity_summary(update) when is_map(update) do
    payload = update[:payload] || Map.get(update, "payload")
    method = payload_value(payload, "method")
    event = update[:event] || Map.get(update, "event")
    params = payload_value(payload, "params")
    summary = codex_activity_text(method, event, params)

    if is_binary(summary) do
      %{
        "event" => event_to_string(event),
        "method" => method,
        "summary" => summary
      }
    else
      nil
    end
  end

  defp codex_activity_text("item/commandExecution/requestApproval", _event, params) do
    "command approval requested: #{truncate_activity(command_from_params(params) || "unknown command")}"
  end

  defp codex_activity_text("item/tool/requestUserInput", _event, params) do
    "tool input requested: #{truncate_activity(question_from_params(params) || "unknown question")}"
  end

  defp codex_activity_text("item/tool/call", _event, params) do
    "tool call: #{truncate_activity(tool_name_from_params(params) || "unknown tool")}"
  end

  defp codex_activity_text("turn/diff/updated", _event, _params), do: "repo diff updated"
  defp codex_activity_text("turn/completed", _event, _params), do: "turn completed"
  defp codex_activity_text(_method, event, _params) when is_atom(event), do: event |> Atom.to_string() |> String.replace("_", " ")
  defp codex_activity_text(_method, event, _params) when is_binary(event), do: event
  defp codex_activity_text(_method, _event, _params), do: nil

  defp command_from_params(params) when is_map(params) do
    payload_value(params, "command") ||
      params
      |> payload_value("commandActions")
      |> first_command_action()
  end

  defp command_from_params(_params), do: nil

  defp first_command_action([first | _rest]) when is_map(first), do: payload_value(first, "command")
  defp first_command_action(_actions), do: nil

  defp question_from_params(params) when is_map(params) do
    params
    |> payload_value("questions")
    |> first_question()
  end

  defp question_from_params(_params), do: nil

  defp first_question([first | _rest]) when is_map(first), do: payload_value(first, "question")
  defp first_question(_questions), do: nil

  defp tool_name_from_params(params) when is_map(params) do
    payload_value(params, "tool") || payload_value(params, "name")
  end

  defp tool_name_from_params(_params), do: nil

  defp event_to_string(event) when is_atom(event), do: Atom.to_string(event)
  defp event_to_string(event) when is_binary(event), do: event
  defp event_to_string(_event), do: nil

  defp truncate_activity(value, max_length \\ 180)

  defp truncate_activity(value, max_length) when is_binary(value) and byte_size(value) > max_length do
    String.slice(value, 0, max_length) <> "..."
  end

  defp truncate_activity(value, _max_length) when is_binary(value), do: value
  defp truncate_activity(value, _max_length), do: inspect(value)

  defp maybe_reset_artifact_progress_for_update(running_entry, update, total_tokens, timestamp) do
    case codex_diff_artifact_fingerprint(update) do
      {:artifact, fingerprint} ->
        if fingerprint != Map.get(running_entry, :last_codex_diff_artifact_fingerprint) do
          Map.merge(running_entry, %{
            artifact_baseline_total_tokens: total_tokens,
            last_artifact_timestamp: timestamp,
            last_artifact_reason: "codex diff updated",
            repo_artifact_baseline_total_tokens: total_tokens,
            last_repo_artifact_timestamp: timestamp,
            last_repo_artifact_reason: "codex diff updated",
            artifact_nudge_count: 0,
            last_codex_diff_artifact_fingerprint: fingerprint,
            health: health_after_artifact_progress(running_entry)
          })
        else
          running_entry
        end

      _ ->
        running_entry
    end
  end

  defp codex_diff_artifact_fingerprint(update) when is_map(update) do
    payload = update[:payload] || Map.get(update, "payload")
    method = payload_value(payload, "method")
    diff = payload_params_value(payload, "diff")

    if method == "turn/diff/updated" and non_empty_string?(diff) do
      {:artifact, {:codex_diff, :erlang.phash2(diff)}}
    else
      :clean
    end
  end

  defp normalize_health_flags(flags) do
    non_healthy =
      flags
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 in ["", "healthy"]))
      |> Enum.uniq()

    case non_healthy do
      [] -> ["healthy"]
      values -> values
    end
  end

  defp maybe_reset_handoff_progress_for_update(running_entry, update, total_tokens, timestamp) do
    case handoff_progress_marker(update) do
      {:progress, reason, fingerprint} ->
        if handoff_progress_candidate?(running_entry) and fingerprint != Map.get(running_entry, :last_handoff_progress_fingerprint) do
          Map.merge(running_entry, %{
            handoff_progress_baseline_total_tokens: total_tokens,
            last_handoff_progress_timestamp: timestamp,
            last_handoff_progress_reason: reason,
            last_handoff_progress_fingerprint: fingerprint
          })
        else
          running_entry
        end

      :none ->
        running_entry
    end
  end

  defp handoff_progress_marker(update) when is_map(update) do
    payload = update[:payload] || Map.get(update, "payload")
    method = payload_value(payload, "method")
    params = payload_value(payload, "params")

    cond do
      method == "item/commandExecution/requestApproval" ->
        handoff_progress_from_command_candidates(params)

      method in ["item/started", "item/completed"] and command_execution_item?(params) ->
        handoff_progress_from_command_candidates(params)

      true ->
        :none
    end
  end

  defp handoff_progress_from_command_candidates(params) do
    params
    |> command_candidates()
    |> Enum.find_value(fn command ->
      case handoff_progress_command_reason(command) do
        nil ->
          nil

        reason ->
          normalized = normalize_command(command)
          {:progress, reason, {:handoff_command, :erlang.phash2(normalized)}}
      end
    end) || :none
  end

  defp command_execution_item?(params) when is_map(params) do
    item = payload_value(params, "item")
    payload_value(item, "type") == "commandExecution"
  end

  defp command_execution_item?(_params), do: false

  defp command_candidates(params) when is_map(params) do
    item = payload_value(params, "item")

    params
    |> direct_command_candidates()
    |> Kernel.++(direct_command_candidates(item))
    |> Kernel.++(command_action_commands(payload_value(params, "commandActions")))
    |> Kernel.++(command_action_commands(payload_value(item, "commandActions")))
    |> Enum.filter(&is_binary/1)
  end

  defp command_candidates(_params), do: []

  defp direct_command_candidates(source) when is_map(source) do
    [
      payload_value(source, "command"),
      payload_value(source, "parsedCmd"),
      payload_value(source, "cmd"),
      normalize_argv(payload_value(source, "argv")),
      normalize_argv(payload_value(source, "args"))
    ]
  end

  defp direct_command_candidates(_source), do: []

  defp normalize_argv(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      Enum.join(values, " ")
    else
      nil
    end
  end

  defp normalize_argv(_values), do: nil

  defp command_action_commands(actions) when is_list(actions) do
    actions
    |> Enum.map(fn
      %{"command" => command} when is_binary(command) -> command
      %{command: command} when is_binary(command) -> command
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end

  defp command_action_commands(_actions), do: []

  defp handoff_progress_command_reason(command) when is_binary(command) do
    normalized = normalize_command(command)

    cond do
      validation_command?(normalized) ->
        "validation command: #{truncate_activity(normalized, 96)}"

      handoff_command?(normalized) ->
        "handoff command: #{truncate_activity(normalized, 96)}"

      true ->
        nil
    end
  end

  defp handoff_progress_command_reason(_command), do: nil

  defp normalize_command(command) when is_binary(command) do
    command
    |> unwrap_shell_command()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp unwrap_shell_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    case Regex.run(~r/\A(?:\/bin\/)?(?:zsh|bash|sh)\s+-lc\s+'([^']+)'\z/, trimmed) do
      [_, inner] -> inner
      _ -> trimmed
    end
  end

  defp validation_command?(command) when is_binary(command) do
    String.match?(command, ~r/\A(?:npm|pnpm|yarn) (?:run )?(?:build|test|typecheck|lint)(?:\s|\z)/) or
      String.match?(command, ~r/\Anode --test(?:\s|\z)/) or
      String.match?(command, ~r/\Amix (?:test|specs\.check)(?:\s|\z)/) or
      String.match?(command, ~r/\A(?:cargo|go|swift) test(?:\s|\z)/) or
      String.match?(command, ~r/\A(?:pytest|python -m pytest|python3 -m pytest)(?:\s|\z)/) or
      String.match?(command, ~r/\Abundle exec rspec(?:\s|\z)/)
  end

  defp handoff_command?(command) when is_binary(command) do
    String.match?(command, ~r/\Agit (?:status|diff|add|commit|push)(?:\s|\z)/) or
      String.match?(command, ~r/\Agh pr (?:create|edit|view|checks|status)(?:\s|\z)/) or
      String.match?(command, ~r/\Agh issue (?:comment|edit|view)(?:\s|\z)/)
  end

  defp maybe_clear_artifact_nudge_count_after_repo_artifact(
         %State{} = state,
         issue_id,
         previous_entry,
         updated_entry
       ) do
    previous_marker = {
      Map.get(previous_entry, :last_repo_artifact_reason),
      Map.get(previous_entry, :last_repo_artifact_timestamp)
    }

    updated_marker = {
      Map.get(updated_entry, :last_repo_artifact_reason),
      Map.get(updated_entry, :last_repo_artifact_timestamp)
    }

    if previous_marker != updated_marker and repo_artifact_reason?(Map.get(updated_entry, :last_repo_artifact_reason)) do
      clear_artifact_nudge_count(state, issue_id)
    else
      state
    end
  end

  defp payload_params_value(payload, key) when is_map(payload) and is_binary(key) do
    params = payload_value(payload, "params")

    case params do
      %{} -> payload_value(params, key)
      _ -> nil
    end
  end

  defp payload_params_value(_payload, _key), do: nil

  defp payload_value(payload, key) when is_map(payload) and is_binary(key) do
    Map.get(payload, key) || Map.get(payload, String.to_atom(key))
  end

  defp payload_value(_payload, _key), do: nil

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp thread_id_for_update(_existing, %{thread_id: thread_id}) when is_binary(thread_id),
    do: thread_id

  defp thread_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp demonitor_running_entry(%{ref: ref}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp demonitor_running_entry(_running_entry), do: :ok

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
