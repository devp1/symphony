defmodule SymphonyElixir.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  defmodule SnapshotServer do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "state payload separates active and parked durable sessions" do
    snapshot = %{
      running: [
        running_entry("issue-run", "GH-RUN", :running),
        running_entry("issue-park", "GH-PARK", :parked)
      ],
      retrying: [],
      codex_totals: %{input_tokens: 10, output_tokens: 2, total_tokens: 12, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, pid} = SnapshotServer.start_link(snapshot)

    payload = Presenter.state_payload(pid, 1_000)

    assert payload.counts.running == 1
    assert payload.counts.parked == 1
    assert [%{issue_identifier: "GH-RUN"}] = payload.running
    assert [%{issue_identifier: "GH-PARK", session_state: :parked}] = payload.parked
  end

  test "issue payload reports parked status for a parked durable session" do
    snapshot = %{
      running: [running_entry("issue-park", "GH-PARK", :parked)],
      retrying: [],
      codex_totals: %{input_tokens: 10, output_tokens: 2, total_tokens: 12, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, pid} = SnapshotServer.start_link(snapshot)

    assert {:ok, payload} = Presenter.issue_payload("GH-PARK", pid, 1_000)
    assert payload.status == "parked"
    assert payload.running.session_state == :parked
  end

  test "issues payload includes explicit merge gate state from latest autonomous review" do
    :ok =
      SymphonyElixir.Storage.record_issue_snapshot(%{
        repo_id: "beacon",
        number: 25,
        identifier: "GH-25",
        title: "Ready PR",
        state: "Human Review",
        labels: ["symphony", "human-review"],
        pr_url: "https://github.com/devp1/Beacon/pull/25",
        head_sha: "abc123",
        pr_state: "OPEN",
        check_state: "passing",
        review_state: "APPROVED"
      })

    :ok =
      SymphonyElixir.Storage.record_issue_snapshot(%{
        repo_id: "beacon",
        number: 26,
        identifier: "GH-26",
        title: "Stale review",
        state: "Human Review",
        labels: ["symphony", "human-review"],
        pr_url: "https://github.com/devp1/Beacon/pull/26",
        head_sha: "new-sha",
        pr_state: "OPEN",
        check_state: "passing",
        review_state: "APPROVED"
      })

    :ok =
      SymphonyElixir.Storage.record_issue_snapshot(%{
        repo_id: "beacon",
        number: 27,
        identifier: "GH-27",
        title: "Failing CI",
        state: "Human Review",
        labels: ["symphony", "human-review"],
        pr_url: "https://github.com/devp1/Beacon/pull/27",
        head_sha: "def456",
        pr_state: "OPEN",
        check_state: "failing",
        review_state: "APPROVED"
      })

    assert {:ok, _} =
             SymphonyElixir.Storage.record_autonomous_review(%{
               id: "review-ready",
               repo_id: "beacon",
               issue_number: 25,
               issue_identifier: "GH-25",
               pr_url: "https://github.com/devp1/Beacon/pull/25",
               head_sha: "abc123",
               reviewer_kind: "review-agent",
               verdict: "pass",
               summary: "clean",
               check_name: "symphony/autonomous-review",
               check_conclusion: "success",
               stale: false
             })

    assert {:ok, _} =
             SymphonyElixir.Storage.record_autonomous_review(%{
               id: "review-stale",
               repo_id: "beacon",
               issue_number: 26,
               issue_identifier: "GH-26",
               pr_url: "https://github.com/devp1/Beacon/pull/26",
               head_sha: "old-sha",
               reviewer_kind: "review-agent",
               verdict: "pass",
               summary: "clean before force-push",
               check_name: "symphony/autonomous-review",
               check_conclusion: "success",
               stale: true
             })

    assert {:ok, _} =
             SymphonyElixir.Storage.record_autonomous_review(%{
               id: "review-failing-ci",
               repo_id: "beacon",
               issue_number: 27,
               issue_identifier: "GH-27",
               pr_url: "https://github.com/devp1/Beacon/pull/27",
               head_sha: "def456",
               reviewer_kind: "review-agent",
               verdict: "pass",
               summary: "review clean",
               check_name: "symphony/autonomous-review",
               check_conclusion: "success",
               stale: false
             })

    issues_by_identifier =
      Presenter.issues_payload()
      |> Map.new(&{&1["identifier"], &1})

    assert %{
             "ready" => true,
             "reasons" => [],
             "review_verdict" => "pass",
             "review_stale" => false,
             "latest_review_id" => "review-ready"
           } = issues_by_identifier["GH-25"]["merge_gate"]

    assert %{
             "ready" => false,
             "reasons" => stale_reasons,
             "review_verdict" => "pass",
             "review_stale" => true,
             "latest_review_head_sha" => "old-sha"
           } = issues_by_identifier["GH-26"]["merge_gate"]

    assert "autonomous-review-stale" in stale_reasons

    assert %{
             "ready" => false,
             "reasons" => failing_reasons,
             "review_verdict" => "pass",
             "review_stale" => false
           } = issues_by_identifier["GH-27"]["merge_gate"]

    assert "ci-not-green" in failing_reasons
  end

  defp running_entry(issue_id, identifier, session_state) do
    now = DateTime.utc_now()

    %{
      issue_id: issue_id,
      identifier: identifier,
      state: if(session_state == :parked, do: "Human Review", else: "In Progress"),
      repo_id: "beacon",
      issue_number: 15,
      run_id: "run-#{issue_id}",
      workspace_path: "/tmp/#{issue_id}",
      issue_session_id: "issue-session-#{issue_id}",
      session_kind: :durable,
      session_state: session_state,
      health: if(session_state == :parked, do: ["parked"], else: ["healthy"]),
      thread_id: "thread-#{issue_id}",
      pr_url: if(session_state == :parked, do: "https://github.com/devp1/Beacon/pull/16", else: nil),
      pr_state: if(session_state == :parked, do: "OPEN", else: nil),
      check_state: "none",
      review_state: "",
      parked_at: if(session_state == :parked, do: now, else: nil),
      stop_reason: if(session_state == :parked, do: "human_review", else: nil),
      session_id: "thread-#{issue_id}-turn-1",
      turn_count: 1,
      last_codex_event: "turn_completed",
      last_codex_message: nil,
      started_at: now,
      last_codex_timestamp: now,
      last_semantic_activity_timestamp: now,
      last_semantic_activity_reason: "turn completed",
      codex_input_tokens: 10,
      codex_output_tokens: 2,
      codex_total_tokens: 12
    }
  end
end
