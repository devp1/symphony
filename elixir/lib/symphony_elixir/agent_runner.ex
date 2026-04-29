defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single issue in its workspace with the configured coding agent.
  """

  require Logger
  alias SymphonyElixir.{CodingAgent, Config, Linear.Issue, PromptBuilder, Tracker, Workpad, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          case run_agent_in_workspace(workspace, issue, codex_update_recipient, opts, worker_host) do
            {:error, reason} ->
              maybe_report_human_needed(issue, workspace, reason)

            result ->
              result
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_agent_in_workspace(workspace, issue, codex_update_recipient, opts, worker_host) do
    with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
         :ok <- maybe_bootstrap_workpad(workspace, issue, worker_host) do
      run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp maybe_bootstrap_workpad(workspace, issue, worker_host) do
    case Workpad.bootstrap(workspace, issue, worker_host) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- CodingAgent.start_session(:executor, workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        CodingAgent.stop_session(:executor, session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           CodingAgent.run_turn(
             :executor,
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    base_prompt = PromptBuilder.build_prompt(issue, opts)

    case Keyword.get(opts, :artifact_nudge) do
      nudge when is_map(nudge) ->
        base_prompt <> "\n\n" <> artifact_nudge_prompt(nudge)

      _ ->
        base_prompt
    end
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp artifact_nudge_prompt(nudge) do
    """
    Symphony continuation nudge:

    The previous autonomous run on this same workspace spent #{Map.get(nudge, "tokens_without_repo_artifact", "many")} tokens without producing a repo artifact.

    - This is nudge #{Map.get(nudge, "nudge_count", "n/a")}; continue autonomously, do not wait for a human.
    - Reuse the current workspace state instead of restarting broad discovery.
    - Stop reading broad context unless it is directly needed for the next edit.
    - Do not fetch full issue comments, memory rollout summaries, or old run logs before the next repo artifact unless they directly change the edit path.
    #{artifact_nudge_next_action(nudge)}
    - Then validate that artifact and proceed toward a PR-ready handoff.
    - Only stop for missing external secrets, missing permissions, or an actual product decision the issue cannot answer.

    Last repo artifact marker: #{Map.get(nudge, "last_repo_artifact", "run started")}
    Last Codex event: #{Map.get(nudge, "last_event", "unknown")}
    #{artifact_nudge_capsule_prompt(nudge)}
    """
  end

  defp artifact_nudge_next_action(%{"handoff_candidate" => true}) do
    "- Existing repo changes are already present. Inspect the current diff first, remove unrelated generated churn, run the issue's validation commands, and move directly toward commit/push/PR handoff before broad rediscovery."
  end

  defp artifact_nudge_next_action(_nudge) do
    "- Create the smallest issue-relevant repo artifact now: a code change, focused test, fixture, config, or validation doc that moves the ticket forward."
  end

  defp artifact_nudge_capsule_prompt(nudge) when is_map(nudge) do
    continuation = Map.get(nudge, "continuation")
    capsule_path = Map.get(nudge, "capsule_path")
    capsule_body = continuation_capsule_body(continuation)

    cond do
      is_binary(capsule_path) and capsule_body != "" ->
        """

        Continuation capsule saved at `#{capsule_path}`:
        #{capsule_body}
        """

      capsule_body != "" ->
        """

        Continuation capsule:
        #{capsule_body}
        """

      true ->
        ""
    end
  end

  defp artifact_nudge_capsule_prompt(_nudge), do: ""

  defp continuation_capsule_body(%{} = continuation) do
    [
      continuation_issue_line(Map.get(continuation, "issue")),
      continuation_workspace_line(Map.get(continuation, "workspace")),
      continuation_activity_lines(Map.get(continuation, "recent_activity")),
      continuation_resume_line(Map.get(continuation, "resume_directive"))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp continuation_capsule_body(_continuation), do: ""

  defp continuation_issue_line(%{} = issue) do
    identifier = Map.get(issue, "identifier")
    title = Map.get(issue, "title")
    state = Map.get(issue, "state")

    "- Issue: #{join_present([identifier, title, state], " | ")}"
  end

  defp continuation_issue_line(_issue), do: nil

  defp continuation_workspace_line(%{} = workspace) do
    details =
      [
        Map.get(workspace, "path"),
        prefixed("branch", Map.get(workspace, "branch")),
        prefixed("head", Map.get(workspace, "head")),
        prefixed("status", Map.get(workspace, "status"))
      ]
      |> Enum.reject(&(&1 in [nil, "", "status=clean"]))

    "- Workspace: #{join_present(details, " | ")}"
  end

  defp continuation_workspace_line(_workspace), do: nil

  defp continuation_activity_lines(activity) when is_list(activity) do
    activity
    |> Enum.take(-5)
    |> Enum.map(fn
      %{"summary" => summary} when is_binary(summary) -> "  - #{summary}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> "- Recent activity:\n" <> Enum.join(lines, "\n")
    end
  end

  defp continuation_activity_lines(_activity), do: nil

  defp continuation_resume_line(value) when is_binary(value), do: "- Resume: #{value}"
  defp continuation_resume_line(_value), do: nil

  defp prefixed(_label, nil), do: nil
  defp prefixed(_label, ""), do: nil
  defp prefixed(_label, "unknown"), do: nil
  defp prefixed(label, value) when is_binary(value), do: "#{label}=#{value}"
  defp prefixed(_label, value), do: inspect(value)

  defp join_present(values, separator) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(separator)
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

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
        Logger.warning("Agent paused for human input: #{issue_context(issue)} reason=#{kind}")
        :ok

      {comment_error, state_error} ->
        human_needed_report_error(kind, comment_error, state_error)
    end
  end

  defp report_human_needed(_issue, _workspace, kind, payload), do: {:error, {kind, payload}}

  defp human_needed_report_error(kind, comment_error, state_error) do
    {:error, {:human_needed_report_failed, %{reason: kind, comment_result: comment_error, state_result: state_error}}}
  end

  defp human_needed_comment(%Issue{} = issue, workspace, kind, payload) do
    """
    ## Symphony needs human input

    Symphony paused this autonomous Codex run because Codex requested human input.

    - Reason: `#{kind}`
    - Issue: `#{issue.identifier || issue.id}`
    - Workspace: `#{workspace}`

    The issue was moved to `needs-input` so the daemon will not keep retrying this run blindly.

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

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

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

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
