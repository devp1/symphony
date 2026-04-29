defmodule SymphonyElixir.IssueSession do
  @moduledoc """
  Durable local owner for one issue workspace, Codex app-server process, and thread.

  This process intentionally owns the Codex app-server port because the app-server
  client receives port messages in the caller process. A parked session keeps that
  port and thread alive until the issue is moved back to active work or explicitly
  stopped.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AutonomousReview, CodingAgent, Config, Evidence, Handoff, Linear.Issue, PromptBuilder}
  alias SymphonyElixir.{Storage, Tracker, Workpad, Workspace}

  @type worker_host :: String.t() | nil
  @type session_state :: :starting | :running | :parked | :stopped | :failed

  defstruct [
    :issue,
    :recipient,
    :opts,
    :worker_host,
    :workspace,
    :app_session,
    :issue_session_id,
    :run_id,
    :cycle_kind,
    :status,
    turn_count: 0
  ]

  @type t :: %__MODULE__{
          issue: Issue.t(),
          recipient: pid() | nil,
          opts: keyword(),
          worker_host: worker_host(),
          workspace: String.t() | nil,
          app_session: CodingAgent.session() | nil,
          issue_session_id: String.t() | nil,
          run_id: String.t() | nil,
          cycle_kind: :initial | :resume | :restart | {:evidence_feedback, String.t()},
          status: session_state(),
          turn_count: non_neg_integer()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    issue = Keyword.fetch!(opts, :issue)

    %{
      id: {__MODULE__, issue.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 15_000,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec resume(pid(), Issue.t(), keyword()) :: :ok | {:error, term()}
  def resume(pid, %Issue{} = issue, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:resume, issue, opts})
  end

  @spec stop(pid(), term()) :: :ok | {:error, term()}
  def stop(pid, reason \\ :manual_stop) when is_pid(pid) do
    GenServer.call(pid, {:stop, reason}, 5_000)
  end

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    issue = Keyword.fetch!(opts, :issue)
    recipient = Keyword.get(opts, :recipient)
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    state = %__MODULE__{
      issue: issue,
      recipient: recipient,
      opts: opts,
      worker_host: worker_host,
      issue_session_id: Keyword.get(opts, :issue_session_id),
      run_id: Keyword.get(opts, :run_id),
      cycle_kind: initial_cycle_kind(opts),
      status: :starting
    }

    send(self(), :start_cycle)
    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), t()) :: {:reply, term(), t()} | {:stop, term(), term(), t()}
  def handle_call({:resume, %Issue{} = issue, opts}, _from, %{status: :parked} = state) do
    state =
      %{
        state
        | issue: issue,
          opts: Keyword.merge(state.opts, opts),
          run_id: Keyword.get(opts, :run_id, state.run_id),
          cycle_kind: :resume,
          status: :running
      }

    send(self(), :start_cycle)
    {:reply, :ok, state}
  end

  def handle_call({:resume, _issue, _opts}, _from, state) do
    {:reply, {:error, {:not_parked, state.status}}, state}
  end

  def handle_call({:stop, reason}, _from, state) do
    publish_session_state(state, :stopped, %{health: ["parked"], stop_reason: inspect(reason)})
    state = stop_app_session(state)
    {:stop, :normal, :ok, %{state | status: :stopped}}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_info(:start_cycle, state) do
    case run_active_cycle(state) do
      {:park, state, reason} ->
        state = %{state | status: :parked}
        publish_session_state(state, :parked, %{health: parked_health(reason), stop_reason: to_string(reason)})
        {:noreply, state}

      {:stop, state, reason} ->
        publish_session_state(state, :stopped, %{health: stop_health(reason), stop_reason: to_string(reason)})
        state = stop_app_session(state)
        {:stop, :normal, %{state | status: :stopped}}

      {:error, state, reason} ->
        publish_session_state(state, :failed, %{health: ["failed"], stop_reason: inspect(reason)})
        state = stop_app_session(state)
        {:stop, {:issue_session_failed, reason}, %{state | status: :failed}}
    end
  rescue
    error ->
      reason = {error.__struct__, Exception.message(error)}
      publish_session_state(state, :failed, %{health: ["failed"], stop_reason: inspect(reason)})
      state = stop_app_session(state)
      {:stop, {:issue_session_crashed, reason}, %{state | status: :failed}}
  catch
    kind, reason ->
      publish_session_state(state, :failed, %{health: ["failed"], stop_reason: inspect({kind, reason})})
      state = stop_app_session(state)
      {:stop, {:issue_session_crashed, {kind, reason}}, %{state | status: :failed}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, state) do
    _ = stop_app_session(state)
    :ok
  end

  defp run_active_cycle(%__MODULE__{} = state) do
    case ensure_workspace(state) do
      {:ok, state} ->
        run_active_cycle_with_workspace(state)

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp run_active_cycle_with_workspace(%__MODULE__{} = state) do
    case apply_startup_handoff(state) do
      {:continue, state} ->
        run_cycle_after_startup_handoff(state)

      {:continue_with_prompt, state, prompt} ->
        state
        |> Map.put(:cycle_kind, {:evidence_feedback, prompt})
        |> run_cycle_after_startup_handoff()

      {:park, state, reason} ->
        {:park, state, reason}

      {:stop, state, reason} ->
        {:stop, state, reason}

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp run_cycle_after_startup_handoff(%__MODULE__{} = state) do
    with :ok <- clear_stale_handoff(state),
         :ok <- Workspace.run_before_run_hook(state.workspace, state.issue, state.worker_host),
         :ok <- maybe_bootstrap_workpad(state.workspace, state.issue, state.worker_host),
         {:ok, state} <- ensure_app_session(state) do
      publish_session_state(state, :running, %{health: current_session_health(state), stop_reason: nil})

      try do
        run_turn_loop(state, 1, max_turns(state.opts))
      after
        Workspace.run_after_run_hook(state.workspace, state.issue, state.worker_host)
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp apply_startup_handoff(%{workspace: workspace, worker_host: nil} = state)
       when is_binary(workspace) do
    case Handoff.read(workspace) do
      {:ok, handoff} ->
        case apply_verified_handoff(state, handoff) do
          {:ok, state} -> classify_applied_startup_handoff(state)
          {:continue_with_prompt, state, prompt} -> {:continue_with_prompt, state, prompt}
          {:stop, state, reason} -> {:stop, state, reason}
          {:error, reason} -> {:error, reason}
        end

      :missing ->
        {:continue, state}

      {:error, :handoff_not_ready} ->
        {:continue, state}

      {:error, _reason} ->
        {:continue, state}
    end
  end

  defp apply_startup_handoff(state), do: {:continue, state}

  defp classify_applied_startup_handoff(%{issue: issue} = state) do
    case classify_issue_state(issue) do
      {:active, refreshed_issue} -> {:continue, %{state | issue: refreshed_issue}}
      {:park, refreshed_issue} -> {:park, %{state | issue: refreshed_issue}, :human_review}
      {:stop, refreshed_issue, reason} -> {:stop, %{state | issue: refreshed_issue}, reason}
    end
  end

  defp ensure_workspace(%{workspace: workspace} = state) when is_binary(workspace) do
    {:ok, state}
  end

  defp ensure_workspace(%{opts: opts, worker_host: nil} = state) do
    case Keyword.get(opts, :workspace_path) do
      workspace_path when is_binary(workspace_path) ->
        expanded_workspace = Path.expand(workspace_path)

        if File.dir?(expanded_workspace) do
          send_worker_runtime_info(state.recipient, state.issue, nil, expanded_workspace)

          Storage.update_issue_session(state.issue_session_id, %{
            workspace_path: expanded_workspace,
            state: "starting",
            current_run_id: state.run_id,
            health: current_session_health(state)
          })

          Storage.update_run(state.run_id, %{
            workspace_path: expanded_workspace,
            issue_session_id: state.issue_session_id,
            session_state: "starting",
            health: current_session_health(state)
          })

          {:ok, %{state | workspace: expanded_workspace}}
        else
          create_workspace(state)
        end

      _ ->
        create_workspace(state)
    end
  end

  defp ensure_workspace(%{issue: issue, worker_host: worker_host} = state) do
    create_workspace(state, issue, worker_host)
  end

  defp create_workspace(%{issue: issue, worker_host: worker_host} = state) do
    create_workspace(state, issue, worker_host)
  end

  defp create_workspace(%{issue: issue, worker_host: worker_host} = state, issue, worker_host) do
    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(state.recipient, issue, worker_host, workspace)

        Storage.update_issue_session(state.issue_session_id, %{
          workspace_path: workspace,
          state: "starting",
          current_run_id: state.run_id,
          health: ["healthy"]
        })

        Storage.update_run(state.run_id, %{
          workspace_path: workspace,
          issue_session_id: state.issue_session_id,
          session_state: "starting",
          health: ["healthy"]
        })

        {:ok, %{state | workspace: workspace}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_app_session(%{app_session: %{} = _app_session} = state), do: {:ok, state}

  defp ensure_app_session(%{workspace: workspace, worker_host: worker_host} = state) do
    case CodingAgent.start_session(:executor, workspace,
           worker_host: worker_host,
           resume_thread_id: Keyword.get(state.opts, :resume_thread_id)
         ) do
      {:ok, app_session} ->
        state = %{state | app_session: app_session}
        record_resume_metadata(state, app_session)
        publish_session_state(state, :running, %{health: current_session_health(state), stop_reason: nil})
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_bootstrap_workpad(workspace, issue, worker_host) do
    case Workpad.bootstrap(workspace, issue, worker_host) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp clear_stale_handoff(%{workspace: workspace, worker_host: nil} = state) when is_binary(workspace) do
    handoff_path = Handoff.path(workspace)

    case Handoff.read(workspace) do
      {:ok, handoff} ->
        _ =
          Storage.append_event(state.run_id, "info", "preserved ready worker handoff file", %{
            issue_session_id: state.issue_session_id,
            handoff_path: handoff_path,
            handoff: Handoff.storage_payload(handoff)
          })

        :ok

      :missing ->
        :ok

      {:error, _reason} ->
        remove_stale_handoff_file(state, handoff_path)
    end
  end

  defp clear_stale_handoff(_state), do: :ok

  defp remove_stale_handoff_file(state, handoff_path) do
    if File.regular?(handoff_path) do
      case File.rm(handoff_path) do
        :ok ->
          _ =
            Storage.append_event(state.run_id, "info", "cleared stale worker handoff file", %{
              issue_session_id: state.issue_session_id,
              handoff_path: handoff_path
            })

          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, {:stale_handoff_cleanup_failed, reason}}
      end
    else
      :ok
    end
  end

  defp run_turn_loop(%{app_session: app_session} = state, turn_number, max_turns) do
    prompt = build_turn_prompt(state.issue, state.opts, state.cycle_kind, turn_number, max_turns)

    case CodingAgent.run_turn(:executor, app_session, prompt, state.issue,
           on_message: codex_message_handler(state.recipient, state.issue),
           turn_interrupt_sentinel: handoff_interrupt_sentinel(state)
         ) do
      {:ok, turn_session} ->
        state = %{state | turn_count: state.turn_count + 1}

        Storage.update_run(state.run_id, %{
          session_id: turn_session[:session_id],
          thread_id: turn_session[:thread_id],
          turn_count: state.turn_count,
          session_state: "running",
          health: current_session_health(state)
        })

        Logger.info("Completed issue session turn for #{issue_context(state.issue)} session_id=#{turn_session[:session_id]} turn=#{turn_number}/#{max_turns}")

        continue_after_turn(state, turn_number, max_turns)

      {:error, reason} ->
        maybe_report_human_needed(state.issue, state.workspace, reason)
        |> case do
          :ok -> {:stop, state, :needs_input}
          {:error, reason} -> {:error, state, reason}
        end
    end
  end

  defp continue_after_turn(state, turn_number, max_turns) do
    case maybe_apply_verified_handoff(state) do
      {:ok, state} ->
        continue_after_issue_status(state, turn_number, max_turns)

      {:continue_with_prompt, state, prompt} when turn_number < max_turns ->
        state
        |> Map.put(:cycle_kind, {:evidence_feedback, prompt})
        |> run_turn_loop(turn_number + 1, max_turns)

      {:continue_with_prompt, state, _prompt} ->
        {:park, state, :max_turns_reached}

      {:stop, state, reason} ->
        {:stop, state, reason}

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp continue_after_issue_status(state, turn_number, max_turns) do
    case issue_flow_status(state.issue, issue_state_fetcher(state.opts)) do
      {:active, refreshed_issue} when turn_number < max_turns ->
        run_turn_loop(%{state | issue: refreshed_issue, cycle_kind: :initial}, turn_number + 1, max_turns)

      {:active, refreshed_issue} ->
        {:park, %{state | issue: refreshed_issue}, :max_turns_reached}

      {:park, refreshed_issue} ->
        {:park, %{state | issue: refreshed_issue}, :human_review}

      {:stop, refreshed_issue, reason} ->
        {:stop, %{state | issue: refreshed_issue}, reason}

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp maybe_apply_verified_handoff(%{workspace: workspace} = state) when is_binary(workspace) do
    case Handoff.read(workspace) do
      {:ok, handoff} ->
        apply_verified_handoff(state, handoff)

      :missing ->
        {:ok, state}

      {:error, :handoff_not_ready} ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:invalid_handoff_file, reason}}
    end
  end

  defp handoff_interrupt_sentinel(%{workspace: workspace, worker_host: nil} = state)
       when is_binary(workspace) do
    fn ->
      case Handoff.read(workspace) do
        {:ok, handoff} ->
          {:interrupt, :worker_handoff_ready,
           %{
             issue_session_id: state.issue_session_id,
             handoff: Handoff.storage_payload(handoff),
             fingerprint: Handoff.fingerprint(handoff)
           }}

        _ ->
          :continue
      end
    end
  end

  defp handoff_interrupt_sentinel(_state), do: nil

  defp apply_verified_handoff(%{issue: %Issue{id: issue_id}} = state, handoff)
       when is_binary(issue_id) do
    target_state = Handoff.tracker_state(handoff)
    payload = Handoff.storage_payload(handoff)

    _ =
      Storage.append_event(state.run_id, "info", "worker handoff file detected", %{
        issue_session_id: state.issue_session_id,
        handoff: payload
      })

    with {:ok, state} <- maybe_gate_human_review_handoff(state, handoff, target_state, payload),
         {:ok, state} <- maybe_run_autonomous_pr_review_handoff(state, handoff, target_state, payload),
         :ok <- Tracker.update_issue_state(issue_id, target_state),
         {:ok, refreshed_issue} <- fetch_single_issue_state(state),
         :ok <- verify_handoff_state(refreshed_issue, target_state) do
      _ = clear_verified_handoff_marker(state, payload)

      _ =
        Storage.append_event(state.run_id, "info", "worker handoff state verified", %{
          issue_session_id: state.issue_session_id,
          target_state: target_state,
          observed_state: refreshed_issue.state,
          handoff: payload
        })

      {:ok, %{state | issue: refreshed_issue}}
    else
      {:continue_with_prompt, state, prompt} ->
        {:continue_with_prompt, state, prompt}

      {:stop, state, reason} ->
        {:stop, state, reason}

      {:error, reason} ->
        _ =
          Storage.append_event(state.run_id, "error", "worker handoff state verification failed", %{
            issue_session_id: state.issue_session_id,
            target_state: target_state,
            handoff: payload,
            reason: inspect(reason)
          })

        {:error, {:handoff_state_verification_failed, reason}}
    end
  end

  defp apply_verified_handoff(state, _handoff), do: {:ok, state}

  defp clear_verified_handoff_marker(%{workspace: workspace} = state, payload) when is_binary(workspace) do
    case remove_handoff_marker(state) do
      :ok ->
        _ =
          Storage.append_event(state.run_id, "info", "cleared verified worker handoff file", %{
            issue_session_id: state.issue_session_id,
            handoff_path: Handoff.path(workspace),
            handoff: payload
          })

        :ok

      {:error, reason} ->
        _ =
          Storage.append_event(state.run_id, "warning", "verified worker handoff cleanup failed", %{
            issue_session_id: state.issue_session_id,
            handoff_path: Handoff.path(workspace),
            reason: inspect(reason)
          })

        :ok
    end
  end

  defp maybe_gate_human_review_handoff(state, handoff, "Human Review", payload) do
    decision = Evidence.decision(state.workspace, state.issue, handoff)
    attempt = Evidence.next_attempt(state.run_id)
    bundle_id = "evidence-bundle-#{state.run_id || "unknown"}-#{attempt}"

    _ =
      Storage.upsert_evidence_bundle(%{
        id: bundle_id,
        run_id: state.run_id,
        issue_session_id: state.issue_session_id,
        issue_identifier: state.issue.identifier,
        workspace_path: state.workspace,
        manifest_path: Map.get(decision, :manifest_path) || Map.get(decision, :bundle_path),
        required: decision.required,
        status: decision.status,
        reason: decision.reason
      })

    cond do
      not decision.required ->
        _ =
          Storage.append_event(state.run_id, "info", "evidence gate skipped", %{
            issue_session_id: state.issue_session_id,
            evidence: decision,
            handoff: payload
          })

        {:ok, state}

      not Evidence.blocking?(decision) ->
        _ =
          Storage.append_event(state.run_id, "info", "evidence gate recorded as advisory", %{
            issue_session_id: state.issue_session_id,
            evidence: decision,
            handoff: payload
          })

        {:ok, state}

      true ->
        run_blocking_evidence_gate(state, handoff, decision, bundle_id, attempt)
    end
  end

  defp maybe_gate_human_review_handoff(state, _handoff, _target_state, _payload), do: {:ok, state}

  defp maybe_run_autonomous_pr_review_handoff(state, handoff, "Human Review", payload) do
    issue = issue_with_handoff_pr(state.issue, handoff)

    cond do
      Config.settings!().tracker.kind != "github" ->
        {:ok, state}

      not reviewable_pr?(issue) ->
        _ =
          Storage.append_event(state.run_id, "info", "autonomous review skipped", %{
            issue_session_id: state.issue_session_id,
            reason: "missing-pr",
            handoff: payload
          })

        {:ok, state}

      not Config.independent_github_reviewer?() ->
        _ =
          Storage.append_event(state.run_id, "info", "autonomous review skipped", %{
            issue_session_id: state.issue_session_id,
            reason: "missing-independent-reviewer-token",
            handoff: payload
          })

        {:ok, %{state | issue: issue}}

      true ->
        run_autonomous_pr_review(%{state | issue: issue}, handoff)
    end
  end

  defp maybe_run_autonomous_pr_review_handoff(state, _handoff, _target_state, _payload), do: {:ok, state}

  defp run_autonomous_pr_review(state, handoff) do
    review_runner =
      Keyword.get(state.opts, :autonomous_review_runner, fn workspace, issue ->
        AutonomousReview.review_and_publish(workspace, issue,
          run_id: state.run_id,
          issue_session_id: state.issue_session_id
        )
      end)

    case review_runner.(state.workspace, state.issue) do
      {:ok, review} ->
        handle_autonomous_review_result(state, handoff, review)

      {:error, reason} ->
        review = %{
          verdict: "needs_input",
          summary: "Autonomous PR review failed to complete",
          findings: [%{reason: inspect(reason)}]
        }

        report_autonomous_review_needs_input(state, handoff, review, reason)
    end
  end

  defp handle_autonomous_review_result(state, handoff, review) do
    verdict = AutonomousReview.normalize_verdict(review_value(review, :verdict) || "needs_input")

    case verdict do
      "pass" ->
        _ =
          Storage.append_event(state.run_id, "info", "autonomous review passed", %{
            issue_session_id: state.issue_session_id,
            verdict: verdict,
            summary: review_value(review, :summary),
            output_path: review_value(review, :output_path)
          })

        {:ok, state}

      "request_changes" ->
        handle_autonomous_review_rework(state, handoff, review, :autonomous_review_requested_changes)

      "needs_input" ->
        report_autonomous_review_needs_input(state, handoff, review, :autonomous_review_needs_input)
    end
  end

  defp handle_autonomous_review_rework(state, handoff, review, reason) do
    _ =
      Storage.append_event(state.run_id, "warning", "autonomous review requested changes", %{
        issue_session_id: state.issue_session_id,
        verdict: review_value(review, :verdict),
        summary: review_value(review, :summary),
        output_path: review_value(review, :output_path),
        reason: inspect(reason)
      })

    prompt = autonomous_review_feedback_prompt(state.issue, handoff, review, reason)
    _ = write_autonomous_review_feedback_file(state.workspace, review, reason)
    _ = remove_handoff_marker(state)
    {:continue_with_prompt, state, prompt}
  end

  defp autonomous_review_feedback_prompt(%Issue{} = issue, handoff, review, reason) do
    """
    Autonomous PR review feedback:

    - Issue: #{issue.identifier || issue.id} — #{issue.title}
    - PR URL, if known: #{issue.pr_url || Map.get(handoff, :pr_url) || "unknown"}
    - Verdict: #{review_value(review, :verdict) || "request_changes"}
    - Summary: #{review_value(review, :summary) || inspect(reason)}

    The independent autonomous reviewer requested changes before the issue could park at human-review.
    Continue in this same durable executor thread. Inspect `.symphony/autonomous-reviews/review-feedback.md`, the PR diff, checks, comments, and the issue acceptance criteria. Fix the implementation or evidence as needed.

    When the PR is genuinely ready again, push the branch if needed and write a fresh `.symphony/handoff.json` with `ready: true`, `state: "human-review"`, `pr_url`, and current validation/evidence metadata.
    """
  end

  defp write_autonomous_review_feedback_file(workspace, review, reason) when is_binary(workspace) do
    feedback_path = Path.join([workspace, ".symphony", "autonomous-reviews", "review-feedback.md"])

    :ok = File.mkdir_p(Path.dirname(feedback_path))

    File.write(feedback_path, """
    # Symphony Autonomous PR Review

    The PR-ready handoff did not pass autonomous review.

    Summary:
    #{review_value(review, :summary) || inspect(reason)}

    Raw review:
    ```json
    #{Jason.encode!(review, pretty: true)}
    ```
    """)
  end

  defp report_autonomous_review_needs_input(%{issue: %Issue{id: issue_id}} = state, handoff, review, reason)
       when is_binary(issue_id) do
    _ =
      Storage.append_event(state.run_id, "warning", "autonomous review needs input", %{
        issue_session_id: state.issue_session_id,
        verdict: review_value(review, :verdict) || "needs_input",
        summary: review_value(review, :summary),
        output_path: review_value(review, :output_path),
        reason: inspect(reason)
      })

    comment =
      autonomous_review_needs_input_comment(state, handoff, review, reason)

    comment_result = Tracker.create_comment(issue_id, comment)
    state_result = Tracker.update_issue_state(issue_id, "Needs Input")

    case {comment_result, state_result} do
      {:ok, :ok} ->
        refreshed_issue =
          case fetch_single_issue_state(state) do
            {:ok, issue} -> issue
            _ -> %{state.issue | state: "Needs Input"}
          end

        {:stop, %{state | issue: refreshed_issue}, :needs_input}

      {comment_error, state_error} ->
        errors = %{comment_result: comment_error, state_result: state_error}

        {:error, {:autonomous_review_needs_input_report_failed, errors}}
    end
  end

  defp autonomous_review_needs_input_comment(state, handoff, review, reason) do
    """
    ## Symphony autonomous review needs input

    Symphony kept this executor session autonomous through PR handoff, but the autonomous PR review could not produce a passing verdict.

    - Issue: `#{state.issue.identifier || state.issue.id}`
    - Run: `#{state.run_id || "unknown"}`
    - Issue session: `#{state.issue_session_id || "unknown"}`
    - Workspace: `#{state.workspace}`
    - PR: `#{state.issue.pr_url || Map.get(handoff, :pr_url) || "unknown"}`
    - Review verdict: `#{review_value(review, :verdict) || "needs_input"}`
    - Summary: #{review_value(review, :summary) || inspect(reason)}

    The issue was moved to `needs-input` so an operator can inspect the workspace, PR, review artifact, and GitHub credentials.
    """
  end

  defp issue_with_handoff_pr(%Issue{} = issue, handoff) when is_map(handoff) do
    pr_url = first_present(issue.pr_url, Map.get(handoff, :pr_url))

    %{issue | pr_url: pr_url, pr_number: issue.pr_number || pr_number_from_url(pr_url)}
  end

  defp reviewable_pr?(%Issue{pr_url: pr_url, pr_number: pr_number}) do
    (is_binary(pr_url) and String.trim(pr_url) != "") or not is_nil(pr_number)
  end

  defp pr_number_from_url(pr_url) when is_binary(pr_url) do
    case Regex.run(~r{/pull/(\d+)(?:\z|[/?#])}, pr_url) do
      [_match, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp pr_number_from_url(_pr_url), do: nil

  defp first_present(left, right) when is_binary(left) do
    if String.trim(left) == "", do: first_present(nil, right), else: left
  end

  defp first_present(_left, right) when is_binary(right) do
    if String.trim(right) == "", do: nil, else: right
  end

  defp first_present(left, right), do: left || right

  defp review_value(%{} = review, key) do
    Map.get(review, key) || Map.get(review, Atom.to_string(key))
  rescue
    ArgumentError -> Map.get(review, key)
  end

  defp review_value(_review, _key), do: nil

  defp run_blocking_evidence_gate(state, handoff, decision, bundle_id, attempt) do
    case Evidence.load_bundle(state.workspace, decision) do
      {:ok, bundle} ->
        _ = Storage.put_artifact(state.run_id, %{kind: "evidence_manifest", path: bundle.manifest_path, label: "evidence manifest"})

        review_runner =
          Keyword.get(state.opts, :evidence_review_runner, fn workspace, issue, handoff, bundle ->
            Evidence.review_bundle(workspace, issue, handoff, bundle)
          end)

        case review_runner.(state.workspace, state.issue, handoff, bundle) do
          {:ok, %{verdict: "pass"} = review} ->
            record_evidence_review(state, bundle_id, attempt, review)
            record_evidence_bundle_status(state, bundle_id, bundle, "review_passed", "pass", Map.get(review, :summary))

            _ =
              Storage.append_event(state.run_id, "info", "evidence review passed", %{
                issue_session_id: state.issue_session_id,
                bundle_id: bundle_id,
                attempt: attempt,
                manifest_path: bundle.manifest_path,
                summary: Map.get(review, :summary)
              })

            {:ok, state}

          {:ok, review} ->
            record_evidence_review(state, bundle_id, attempt, review)
            record_evidence_bundle_status(state, bundle_id, bundle, "review_failed", "fail", Map.get(review, :summary))
            handle_evidence_gate_failure(state, handoff, bundle_id, attempt, review, :evidence_review_failed)

          {:error, reason} ->
            review = %{verdict: "request_changes", summary: "Evidence review failed to complete", feedback: %{reason: inspect(reason)}}
            record_evidence_review(state, bundle_id, attempt, review)
            record_evidence_bundle_status(state, bundle_id, bundle, "review_failed", "fail", review.summary)
            handle_evidence_gate_failure(state, handoff, bundle_id, attempt, review, reason)
        end

      {:error, reason} ->
        review = %{
          verdict: "request_changes",
          summary: "Required evidence bundle is missing or invalid",
          feedback: %{reason: inspect(reason), required_action: "Create a valid evidence manifest and write a fresh handoff marker."}
        }

        record_evidence_review(state, bundle_id, attempt, review)

        _ =
          Storage.upsert_evidence_bundle(%{
            id: bundle_id,
            run_id: state.run_id,
            issue_session_id: state.issue_session_id,
            issue_identifier: state.issue.identifier,
            workspace_path: state.workspace,
            manifest_path: Map.get(decision, :manifest_path) || Map.get(decision, :bundle_path),
            required: true,
            status: "missing_or_invalid",
            reason: inspect(reason),
            verdict: "fail",
            summary: review.summary
          })

        handle_evidence_gate_failure(state, handoff, bundle_id, attempt, review, reason)
    end
  end

  defp record_evidence_bundle_status(state, bundle_id, bundle, status, verdict, summary) do
    Storage.upsert_evidence_bundle(%{
      id: bundle_id,
      run_id: state.run_id,
      issue_session_id: state.issue_session_id,
      issue_identifier: state.issue.identifier,
      workspace_path: state.workspace,
      manifest_path: bundle.manifest_path,
      required: true,
      status: status,
      reason: "blocking evidence review",
      verdict: verdict,
      summary: summary
    })
  end

  defp record_evidence_review(state, bundle_id, attempt, review) do
    Storage.record_evidence_review(%{
      bundle_id: bundle_id,
      run_id: state.run_id,
      issue_session_id: state.issue_session_id,
      attempt: attempt,
      agent_kind: "review-agent",
      session_id: Map.get(review, :session_id),
      thread_id: Map.get(review, :thread_id),
      verdict: Map.get(review, :verdict, "request_changes"),
      summary: Map.get(review, :summary),
      feedback: Map.get(review, :feedback, %{}),
      output_path: Map.get(review, :output_path)
    })
  end

  defp handle_evidence_gate_failure(state, handoff, bundle_id, attempt, review, reason) do
    max_attempts = Evidence.max_attempts()

    _ =
      Storage.append_event(state.run_id, "warning", "evidence review did not pass", %{
        issue_session_id: state.issue_session_id,
        bundle_id: bundle_id,
        attempt: attempt,
        max_attempts: max_attempts,
        verdict: Map.get(review, :verdict, "request_changes"),
        summary: Map.get(review, :summary),
        reason: inspect(reason)
      })

    if attempt < max_attempts do
      prompt = evidence_feedback_prompt(state.issue, handoff, review, reason, attempt, max_attempts)
      _ = write_evidence_feedback_file(state.workspace, review, reason)
      _ = remove_handoff_marker(state)
      {:continue_with_prompt, state, prompt}
    else
      report_evidence_needs_input(state, handoff, review, reason)
    end
  end

  defp evidence_feedback_prompt(%Issue{} = issue, handoff, review, reason, attempt, max_attempts) do
    """
    Evidence review feedback:

    - Issue: #{issue.identifier || issue.id} — #{issue.title}
    - PR URL, if known: #{issue.pr_url || Map.get(handoff, :pr_url) || "unknown"}
    - Evidence review attempt: #{attempt} of #{max_attempts}
    - Verdict: #{Map.get(review, :verdict, "request_changes")}
    - Summary: #{Map.get(review, :summary) || inspect(reason)}

    The review agent did not accept the evidence bundle for human-review handoff.
    Continue in this same durable executor thread. Inspect `.symphony/evidence/review-feedback.md`, the evidence bundle, the PR/diff/checks, and the issue acceptance criteria. Fix the implementation or regenerate evidence as needed.

    When the PR is genuinely ready again, write a fresh `.symphony/handoff.json` with `ready: true`, `state: "human-review"`, `pr_url`, and an `evidence` object pointing at the updated bundle manifest.
    """
  end

  defp write_evidence_feedback_file(workspace, review, reason) when is_binary(workspace) do
    feedback_path = Path.join([workspace, ".symphony", "evidence", "review-feedback.md"])

    :ok = File.mkdir_p(Path.dirname(feedback_path))
    File.write(feedback_path, Evidence.feedback_markdown(review, reason))
  end

  defp remove_handoff_marker(%{workspace: workspace}) when is_binary(workspace) do
    case File.rm(Handoff.path(workspace)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp report_evidence_needs_input(%{issue: %Issue{id: issue_id}} = state, handoff, review, reason)
       when is_binary(issue_id) do
    comment_result = Tracker.create_comment(issue_id, evidence_needs_input_comment(state, handoff, review, reason))
    state_result = Tracker.update_issue_state(issue_id, "Needs Input")

    case {comment_result, state_result} do
      {:ok, :ok} ->
        refreshed_issue =
          case fetch_single_issue_state(state) do
            {:ok, issue} -> issue
            _ -> %{state.issue | state: "Needs Input"}
          end

        {:stop, %{state | issue: refreshed_issue}, :needs_input}

      {comment_error, state_error} ->
        {:error, {:evidence_needs_input_report_failed, %{comment_result: comment_error, state_result: state_error}}}
    end
  end

  defp evidence_needs_input_comment(state, handoff, review, reason) do
    """
    ## Symphony evidence review needs input

    Symphony kept this executor session autonomous through the configured evidence review attempts, but the evidence gate still did not pass.

    - Issue: `#{state.issue.identifier || state.issue.id}`
    - Run: `#{state.run_id || "unknown"}`
    - Issue session: `#{state.issue_session_id || "unknown"}`
    - Workspace: `#{state.workspace}`
    - PR: `#{state.issue.pr_url || Map.get(handoff, :pr_url) || "unknown"}`
    - Review verdict: `#{Map.get(review, :verdict, "request_changes")}`
    - Summary: #{Map.get(review, :summary) || inspect(reason)}

    The issue was moved to `needs-input` so an operator can inspect the workspace, PR, and evidence bundle.
    """
  end

  defp fetch_single_issue_state(%{issue: %Issue{id: issue_id}, opts: opts}) when is_binary(issue_id) do
    case issue_state_fetcher(opts).([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} -> {:ok, refreshed_issue}
      {:ok, []} -> {:error, :issue_missing_after_handoff}
      {:error, reason} -> {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp fetch_single_issue_state(_state), do: {:error, :issue_missing_id}

  defp verify_handoff_state(%Issue{state: observed_state}, target_state) do
    if normalize_issue_state(observed_state) == normalize_issue_state(target_state) do
      :ok
    else
      {:error, {:handoff_state_mismatch, %{expected: target_state, observed: observed_state}}}
    end
  end

  defp issue_flow_status(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        classify_issue_state(refreshed_issue)

      {:ok, []} ->
        {:stop, issue, :issue_missing}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp issue_flow_status(issue, _issue_state_fetcher), do: {:stop, issue, :issue_missing_id}

  defp classify_issue_state(%Issue{state: state_name} = issue) do
    normalized = normalize_issue_state(state_name)

    cond do
      normalized in active_state_names() ->
        {:active, issue}

      normalized == "human-review" ->
        {:park, issue}

      normalized in terminal_state_names() ->
        {:stop, issue, :terminal_issue_state}

      normalized in ["needs-input", "blocked"] ->
        {:stop, issue, String.to_atom(normalized)}

      true ->
        {:stop, issue, :non_active_issue_state}
    end
  end

  defp max_turns(opts) do
    Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  end

  defp initial_cycle_kind(opts) do
    if Keyword.has_key?(opts, :restart_capsule), do: :restart, else: :initial
  end

  defp issue_state_fetcher(opts) do
    Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
  end

  defp build_turn_prompt(issue, opts, :resume, 1, _max_turns), do: rework_prompt(issue, opts)

  defp build_turn_prompt(issue, opts, :restart, 1, _max_turns), do: restart_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, {:evidence_feedback, prompt}, _turn_number, _max_turns), do: prompt

  defp build_turn_prompt(issue, opts, _cycle_kind, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, _cycle_kind, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the GitHub issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current active work cycle.
    - Continue in the same Codex thread and workspace. The prior issue context is already in this thread.
    - Before broad rediscovery, inspect `git status --porcelain`, `git diff`, `.symphony/workpad.md`, and any existing PR. If the workspace already has issue-relevant artifacts, prioritize validation, cleanup, PR update, evidence comment, and handoff.
    - If there are no useful artifacts yet, create the smallest issue-relevant repository artifact first, then expand only as needed.
    - Inspect the repo, tests, issue state, PR state, and GitHub feedback as needed.
    - Keep working autonomously toward a validated PR-ready handoff unless you are blocked by missing auth, missing secrets, required human input, or an actual product decision the issue cannot answer.
    """
  end

  defp rework_prompt(%Issue{} = issue, opts) do
    pr_url = Keyword.get(opts, :pr_url) || issue.pr_url || "unknown"

    """
    Rework continuation:

    - This is the same durable Codex issue session, resumed after the issue moved back to active work.
    - Issue: #{issue.identifier || issue.id} — #{issue.title}
    - Current issue state: #{issue.state}
    - PR URL, if known: #{pr_url}
    - Continue in the current workspace and thread; do not restart discovery unless current evidence requires it.
    - Before broad rediscovery, inspect existing diff, workpad, PR, checks, and review comments. If issue-relevant changes already exist, validate and move them to PR-ready handoff instead of re-planning from scratch.
    - Inspect current issue comments, PR review comments, check failures, and repo status with `gh` and local commands.
    - Address the requested feedback, validate the fix, update or create the PR, comment concise evidence, and move the issue back to `human-review` when it is ready.
    - Stop only for missing auth/secrets, a Codex input request that cannot be answered non-interactively, or a real product decision the ticket cannot resolve.
    """
  end

  defp restart_prompt(%Issue{} = issue, opts) do
    capsule = Keyword.get(opts, :restart_capsule, %{})
    workspace_path = capsule_value(capsule, :workspace_path) || "unknown"
    pr_url = issue.pr_url || capsule_value(capsule, :pr_url) || "unknown"
    stop_reason = capsule_value(capsule, :stop_reason) || "unknown"
    resume_thread_id = Keyword.get(opts, :resume_thread_id) || "unknown"

    """
    Symphony restart continuation:

    - Symphony restarted while this issue session was active or parked.
    - Issue: #{issue.identifier || issue.id} — #{issue.title}
    - Current issue state: #{issue.state}
    - Workspace: #{workspace_path}
    - Prior Codex thread id: #{resume_thread_id}
    - PR URL, if known: #{pr_url}
    - Prior interruption reason: #{stop_reason}

    Continue from the preserved workspace and restored thread if available.

    First, inspect `.symphony/workpad.md`, `git status --porcelain`, `git diff`, any existing PR, issue comments, PR feedback, and recent test output. If the workspace already contains issue-relevant changes, treat them as the current implementation: remove obvious churn, run the focused validation, update or open the PR, comment concise evidence, and move the issue to `human-review`.

    Only restart broad discovery when the workspace has no useful artifact or the existing artifact is clearly wrong. Keep working autonomously toward a validated PR-ready handoff unless you are blocked by missing auth/secrets, required human input, or a real product decision the issue cannot answer.
    """
  end

  defp capsule_value(capsule, key) when is_map(capsule) and is_atom(key) do
    Map.get(capsule, key) || Map.get(capsule, Atom.to_string(key))
  end

  defp capsule_value(_capsule, _key), do: nil

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp maybe_report_human_needed(issue, workspace, {:approval_required, payload}) do
    report_human_needed(issue, workspace, :approval_required, payload)
  end

  defp maybe_report_human_needed(issue, workspace, {:turn_input_required, payload}) do
    report_human_needed(issue, workspace, :turn_input_required, payload)
  end

  defp maybe_report_human_needed(_issue, _workspace, reason), do: {:error, reason}

  defp report_human_needed(%Issue{id: issue_id} = issue, workspace, kind, payload)
       when is_binary(issue_id) do
    comment_result = Tracker.create_comment(issue_id, human_needed_comment(issue, workspace, kind, payload))
    state_result = Tracker.update_issue_state(issue_id, "Needs Input")

    case {comment_result, state_result} do
      {:ok, :ok} ->
        Logger.warning("Issue session paused for human input: #{issue_context(issue)} reason=#{kind}")
        :ok

      {comment_error, state_error} ->
        error = %{reason: kind, comment_result: comment_error, state_result: state_error}
        {:error, {:human_needed_report_failed, error}}
    end
  end

  defp report_human_needed(_issue, _workspace, kind, payload), do: {:error, {kind, payload}}

  defp human_needed_comment(%Issue{} = issue, workspace, kind, payload) do
    """
    ## Symphony needs human input

    Symphony parked this durable Codex issue session because Codex requested human input.

    - Reason: `#{kind}`
    - Issue: `#{issue.identifier || issue.id}`
    - Workspace: `#{workspace}`

    The issue was moved to `needs-input`; the session was stopped because this request cannot be answered non-interactively.

    ```text
    #{human_needed_payload_summary(payload)}
    ```
    """
  end

  defp human_needed_payload_summary(payload) do
    payload
    |> inspect(limit: 20, printable_limit: 2_000)
    |> String.slice(0, 2_000)
  end

  defp publish_session_state(%__MODULE__{} = state, session_state, attrs) do
    health = Map.get(attrs, :health, ["healthy"])
    stop_reason = Map.get(attrs, :stop_reason)
    parked_at = if session_state == :parked, do: timestamp(), else: nil
    app_session = state.app_session || %{}
    metadata = Map.get(app_session, :metadata, %{})
    thread_id = Map.get(app_session, :thread_id)
    app_server_pid = Map.get(metadata, :codex_app_server_pid)

    Storage.update_issue_session(state.issue_session_id, %{
      workspace_path: state.workspace,
      codex_thread_id: thread_id,
      app_server_pid: app_server_pid,
      state: to_string(session_state),
      current_run_id: state.run_id,
      health: health,
      parked_at: parked_at,
      stop_reason: stop_reason
    })

    Storage.update_run(state.run_id, %{
      state: run_state_for_session_state(session_state),
      issue_session_id: state.issue_session_id,
      workspace_path: state.workspace,
      thread_id: thread_id,
      turn_count: state.turn_count,
      session_state: to_string(session_state),
      health: health,
      error: run_error_for_session_state(session_state, stop_reason)
    })

    send_session_state_update(state.recipient, state.issue, %{
      issue_session_id: state.issue_session_id,
      run_id: state.run_id,
      session_state: session_state,
      health: health,
      workspace_path: state.workspace,
      thread_id: thread_id,
      codex_app_server_pid: app_server_pid,
      turn_count: state.turn_count,
      parked_at: parked_at,
      stop_reason: stop_reason,
      cleanup_workspace: Map.get(attrs, :cleanup_workspace, false)
    })

    :ok
  end

  defp send_session_state_update(recipient, %Issue{id: issue_id}, update)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:issue_session_state, issue_id, update})
    :ok
  end

  defp send_session_state_update(_recipient, _issue, _update), do: :ok

  defp stop_app_session(%{app_session: %{} = app_session} = state) do
    CodingAgent.stop_session(:executor, app_session)
    %{state | app_session: nil}
  end

  defp stop_app_session(state), do: state

  defp record_resume_metadata(%__MODULE__{} = state, %{metadata: metadata} = app_session) when is_map(metadata) do
    if Map.get(metadata, :resume_attempted) do
      level = if Map.get(metadata, :resume_succeeded), do: "info", else: "warning"
      message = if Map.get(metadata, :resume_succeeded), do: "codex thread resumed", else: "codex thread resume failed; started new thread"

      Storage.append_event(state.run_id, level, message, %{
        issue_session_id: state.issue_session_id,
        requested_thread_id: Keyword.get(state.opts, :resume_thread_id),
        active_thread_id: Map.get(app_session, :thread_id),
        resume_failure_reason: Map.get(metadata, :resume_failure_reason)
      })
    end

    :ok
  end

  defp record_resume_metadata(_state, _app_session), do: :ok

  defp current_session_health(%{app_session: %{metadata: metadata}}) when is_map(metadata) do
    cond do
      Map.get(metadata, :resume_attempted) && Map.get(metadata, :resume_succeeded) ->
        ["healthy"]

      Map.get(metadata, :resume_attempted) ->
        ["resume-failed-started-new-thread"]

      true ->
        ["healthy"]
    end
  end

  defp current_session_health(_state), do: ["healthy"]

  defp parked_health(:max_turns_reached), do: ["parked", "handoff-lagging"]
  defp parked_health(_reason), do: ["parked"]

  defp stop_health(:needs_input), do: ["needs-input"]
  defp stop_health(:"needs-input"), do: ["needs-input"]
  defp stop_health(:blocked), do: ["failed"]
  defp stop_health(_reason), do: ["healthy"]

  defp run_state_for_session_state(:parked), do: "parked"
  defp run_state_for_session_state(:stopped), do: "completed"
  defp run_state_for_session_state(:failed), do: "failed"
  defp run_state_for_session_state(_state), do: "running"

  defp run_error_for_session_state(:failed, stop_reason), do: stop_reason
  defp run_error_for_session_state(_session_state, _stop_reason), do: nil

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp active_state_names do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp terminal_state_names do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_]+/, "-")
  end

  defp normalize_issue_state(_state_name), do: ""

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
