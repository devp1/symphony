defmodule SymphonyElixir.IssueSessionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueSession

  test "durable issue session applies verified needs-input handoff and stops" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-handoff-needs-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-needs-input"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-needs-input"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"needs-input","reason":"target unavailable","summary":"blocked by missing service"}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-handoff-needs-input",
        identifier: "GH-HANDOFF-INPUT",
        title: "Needs input handoff",
        description: "The worker found a real external blocker.",
        state: "In Progress",
        url: "https://example.org/issues/GH-HANDOFF-INPUT",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Needs Input"}]}
      end

      assert {:ok, "issue-session-handoff-needs-input"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-handoff-needs-input",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-handoff-needs-input"
               })

      assert {:ok, "run-handoff-needs-input"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-handoff-needs-input",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-handoff-needs-input",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-handoff-needs-input",
                 run_id: "run-handoff-needs-input",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:memory_tracker_state_update, "issue-handoff-needs-input", "Needs Input"}, 5_000

      assert_receive {:issue_session_state, "issue-handoff-needs-input", %{session_state: :stopped, health: ["needs-input"], stop_reason: "needs-input"}},
                     5_000

      stored_run = SymphonyElixir.Storage.get_run("run-handoff-needs-input")
      assert stored_run["state"] == "completed"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "worker handoff state verified"))
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(test_root)
    end
  end

  test "durable issue session applies verified human-review handoff and parks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-handoff-human-review-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-human-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-human-review"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/44"}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-handoff-human-review",
        identifier: "GH-HANDOFF-REVIEW",
        title: "Human review handoff",
        description: "The worker opened a review-ready PR.",
        state: "In Progress",
        url: "https://example.org/issues/GH-HANDOFF-REVIEW",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review"}]}
      end

      assert {:ok, "issue-session-handoff-human-review"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-handoff-human-review",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-handoff-human-review"
               })

      assert {:ok, "run-handoff-human-review"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-handoff-human-review",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-handoff-human-review",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-handoff-human-review",
                 run_id: "run-handoff-human-review",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:memory_tracker_state_update, "issue-handoff-human-review", "Human Review"}, 5_000

      assert_receive {:issue_session_state, "issue-handoff-human-review", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}},
                     5_000

      stored_run = SymphonyElixir.Storage.get_run("run-handoff-human-review")
      assert stored_run["state"] == "parked"
      assert stored_run["session_state"] == "parked"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "worker handoff state verified"))
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(test_root)
    end
  end

  test "durable issue session runs autonomous PR review before human-review parking" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-autonomous-review-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-autonomous-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-autonomous-review"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://github.com/devp1/Beacon/pull/25"}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_owner: "devp1",
        tracker_repo: "Beacon",
        github_builder_token: "builder-token",
        github_reviewer_token: "reviewer-token",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
        send(parent, {:gh_args, args, env})
        {"{}", 0}
      end)

      issue = %Issue{
        id: "25",
        identifier: "GH-25",
        title: "Autonomous review handoff",
        description: "The worker opened a review-ready PR.",
        state: "In Progress",
        url: "https://github.com/devp1/Beacon/issues/25",
        repo_id: "github",
        repo_owner: "devp1",
        repo_name: "Beacon",
        number: 25,
        head_sha: "abc123",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review", pr_url: "https://github.com/devp1/Beacon/pull/25"}]}
      end

      assert {:ok, "issue-session-autonomous-review"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-autonomous-review",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-autonomous-review"
               })

      assert {:ok, "run-autonomous-review"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-autonomous-review",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-autonomous-review",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-autonomous-review",
                 run_id: "run-autonomous-review",
                 issue_state_fetcher: issue_state_fetcher,
                 autonomous_review_runner: fn _workspace, review_issue ->
                   send(parent, {:autonomous_review_runner, review_issue.pr_url, review_issue.pr_number})

                   {:ok,
                    %{
                      verdict: "pass",
                      summary: "autonomous review accepted the PR",
                      head_sha: "abc123",
                      output_path: ".symphony/autonomous-reviews/review.json"
                    }}
                 end
               )

      assert_receive {:autonomous_review_runner, "https://github.com/devp1/Beacon/pull/25", 25}, 5_000

      assert_receive {:issue_session_state, "25", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}}, 5_000

      assert_received {:gh_args, ["api", "repos/devp1/Beacon/issues/25" | _], _env}

      stored_run = SymphonyElixir.Storage.get_run("run-autonomous-review")
      assert stored_run["state"] == "parked"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "autonomous review passed"))
      assert Enum.any?(stored_run["events"], &(&1["message"] == "worker handoff state verified"))
    after
      Application.delete_env(:symphony_elixir, :github_command_fun)
      File.rm_rf(test_root)
    end
  end

  test "durable issue session routes autonomous review changes back to same executor thread" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-autonomous-review-rework-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-autonomous-review-rework.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-autonomous-review-rework"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-autonomous-review-rework-1"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://github.com/devp1/Beacon/pull/26"}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-autonomous-review-rework-2"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"review-fixed","pr_url":"https://github.com/devp1/Beacon/pull/26"}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_owner: "devp1",
        tracker_repo: "Beacon",
        github_builder_token: "builder-token",
        github_reviewer_token: "reviewer-token",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()
      {:ok, review_attempts} = Agent.start_link(fn -> 0 end)

      Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
        send(parent, {:gh_args, args, env})
        {"{}", 0}
      end)

      issue = %Issue{
        id: "26",
        identifier: "GH-26",
        title: "Autonomous review rework",
        description: "The worker should address autonomous review feedback in the same thread.",
        state: "In Progress",
        url: "https://github.com/devp1/Beacon/issues/26",
        repo_id: "github",
        repo_owner: "devp1",
        repo_name: "Beacon",
        number: 26,
        head_sha: "def456",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review", pr_url: "https://github.com/devp1/Beacon/pull/26"}]}
      end

      assert {:ok, "issue-session-autonomous-review-rework"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-autonomous-review-rework",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-autonomous-review-rework"
               })

      assert {:ok, "run-autonomous-review-rework"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-autonomous-review-rework",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-autonomous-review-rework",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-autonomous-review-rework",
                 run_id: "run-autonomous-review-rework",
                 issue_state_fetcher: issue_state_fetcher,
                 autonomous_review_runner: fn _workspace, _review_issue ->
                   attempt = Agent.get_and_update(review_attempts, fn attempt -> {attempt + 1, attempt + 1} end)
                   send(parent, {:autonomous_review_attempt, attempt})

                   if attempt == 1 do
                     {:ok,
                      %{
                        verdict: "request_changes",
                        summary: "Fix the unchecked edge case",
                        head_sha: "def456",
                        findings: [%{title: "Unchecked edge case", body: "Add the missing guard."}]
                      }}
                   else
                     {:ok,
                      %{
                        verdict: "pass",
                        summary: "review feedback addressed",
                        head_sha: "def456"
                      }}
                   end
                 end
               )

      assert_receive {:autonomous_review_attempt, 1}, 5_000
      assert_receive {:autonomous_review_attempt, 2}, 5_000

      assert_receive {:issue_session_state, "26", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}}, 5_000

      stored_run = SymphonyElixir.Storage.get_run("run-autonomous-review-rework")
      assert stored_run["state"] == "parked"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "autonomous review requested changes"))
      assert Enum.any?(stored_run["events"], &(&1["message"] == "autonomous review passed"))

      feedback_path =
        Path.join([
          workspace_root,
          "GH-26",
          ".symphony",
          "autonomous-reviews",
          "review-feedback.md"
        ])

      assert File.read!(feedback_path) =~ "Fix the unchecked edge case"

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 1) =~ "Autonomous PR review feedback:"
      assert Enum.at(turn_texts, 1) =~ "write a fresh `.symphony/handoff.json`"
    after
      Application.delete_env(:symphony_elixir, :github_command_fun)
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "durable issue session applies ready startup handoff before starting Codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-startup-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "GH-STARTUP-HANDOFF")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join([workspace, ".symphony", "handoff.json"]),
        ~s({"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/88"}\n)
      )

      File.write!(codex_binary, """
      #!/bin/sh
      printf 'started\\n' >> "${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-startup-handoff.trace}"
      exit 1
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-startup-handoff",
        identifier: "GH-STARTUP-HANDOFF",
        title: "Startup handoff",
        description: "A recovered session should apply an already-ready handoff before a new turn.",
        state: "In Progress",
        url: "https://example.org/issues/GH-STARTUP-HANDOFF",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review"}]}
      end

      assert {:ok, "issue-session-startup-handoff"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-startup-handoff",
                 issue_identifier: issue.identifier,
                 workspace_path: workspace,
                 state: "running",
                 current_run_id: "run-startup-handoff"
               })

      assert {:ok, "run-startup-handoff"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-startup-handoff",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-startup-handoff",
                 workspace_path: workspace,
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-startup-handoff",
                 run_id: "run-startup-handoff",
                 workspace_path: workspace,
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:memory_tracker_state_update, "issue-startup-handoff", "Human Review"}, 5_000

      assert_receive {:issue_session_state, "issue-startup-handoff", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}},
                     5_000

      refute File.exists?(trace_file)
      refute File.exists?(Path.join([workspace, ".symphony", "handoff.json"]))

      stored_run = SymphonyElixir.Storage.get_run("run-startup-handoff")
      assert stored_run["state"] == "parked"
      assert stored_run["session_state"] == "parked"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "worker handoff state verified"))
      assert Enum.any?(stored_run["events"], &(&1["message"] == "cleared verified worker handoff file"))
      refute Enum.any?(stored_run["events"], &(&1["message"] == "cleared stale worker handoff file"))
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "durable issue session reviews ready startup handoff evidence before starting Codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-startup-evidence-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "GH-STARTUP-EVIDENCE")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      evidence_dir = Path.join([workspace, ".symphony", "evidence", "startup"])

      File.mkdir_p!(evidence_dir)

      File.write!(
        Path.join([workspace, ".symphony", "handoff.json"]),
        ~s({"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/89","evidence":{"required":true,"bundle_path":".symphony/evidence/startup/manifest.json"}}\n)
      )

      File.write!(Path.join(evidence_dir, "npm-test.log"), "npm test passed\n")

      File.write!(
        Path.join(evidence_dir, "manifest.json"),
        ~s({"schema_version":"symphony.evidence.v1","summary":"startup handoff evidence is ready","artifacts":[],"commands":[{"command":"npm test","status":"passed","exit_code":0,"output_path":"npm-test.log"}]}\n)
      )

      File.write!(codex_binary, """
      #!/bin/sh
      printf 'started\\n' >> "${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-startup-evidence-handoff.trace}"
      exit 1
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-startup-evidence",
        identifier: "GH-STARTUP-EVIDENCE",
        title: "Startup evidence handoff",
        description: "A recovered session should review an already-ready evidence handoff before a new turn.",
        state: "In Progress",
        url: "https://example.org/issues/GH-STARTUP-EVIDENCE",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review"}]}
      end

      assert {:ok, "issue-session-startup-evidence"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-startup-evidence",
                 issue_identifier: issue.identifier,
                 workspace_path: workspace,
                 state: "running",
                 current_run_id: "run-startup-evidence"
               })

      assert {:ok, "run-startup-evidence"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-startup-evidence",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-startup-evidence",
                 workspace_path: workspace,
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-startup-evidence",
                 run_id: "run-startup-evidence",
                 workspace_path: workspace,
                 issue_state_fetcher: issue_state_fetcher,
                 evidence_review_runner: fn _workspace, _issue, _handoff, _bundle ->
                   {:ok,
                    %{
                      verdict: "pass",
                      summary: "startup evidence supports the handoff",
                      feedback: %{concerns: []},
                      session_id: "review-session-startup",
                      thread_id: "review-thread-startup"
                    }}
                 end
               )

      assert_receive {:memory_tracker_state_update, "issue-startup-evidence", "Human Review"}, 5_000

      assert_receive {:issue_session_state, "issue-startup-evidence", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}},
                     5_000

      refute File.exists?(trace_file)
      refute File.exists?(Path.join([workspace, ".symphony", "handoff.json"]))

      stored_run = SymphonyElixir.Storage.get_run("run-startup-evidence")
      assert stored_run["state"] == "parked"
      assert stored_run["session_state"] == "parked"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "evidence review passed"))
      assert Enum.any?(stored_run["events"], &(&1["message"] == "worker handoff state verified"))
      refute Enum.any?(stored_run["events"], &(&1["message"] == "cleared stale worker handoff file"))
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "durable issue session interrupts a live turn for verified human-review handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-live-handoff-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-issue-session-live-handoff.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-live-handoff"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-live-handoff"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/55"}' > .symphony/handoff.json
            ;;
          5)
            printf '%s\\n' '{"id":4,"result":{}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-live-handoff","turn":{"id":"turn-live-handoff","status":"interrupted"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-live-handoff",
        identifier: "GH-LIVE-HANDOFF",
        title: "Live handoff",
        description: "The worker should stop drifting after PR-ready handoff.",
        state: "In Progress",
        url: "https://example.org/issues/GH-LIVE-HANDOFF",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review"}]}
      end

      assert {:ok, "issue-session-live-handoff"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-live-handoff",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-live-handoff"
               })

      assert {:ok, "run-live-handoff"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-live-handoff",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-live-handoff",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-live-handoff",
                 run_id: "run-live-handoff",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:codex_worker_update, "issue-live-handoff", %{event: :turn_interrupt_requested}},
                     5_000

      assert_receive {:memory_tracker_state_update, "issue-live-handoff", "Human Review"}, 5_000

      assert_receive {:issue_session_state, "issue-live-handoff", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}},
                     5_000

      stored_run = SymphonyElixir.Storage.get_run("run-live-handoff")
      assert stored_run["state"] == "parked"
      assert Enum.any?(stored_run["events"], &(&1["message"] == "worker handoff state verified"))

      lines =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(lines, fn payload ->
               payload["method"] == "turn/interrupt" &&
                 get_in(payload, ["params", "threadId"]) == "thread-live-handoff" &&
                 get_in(payload, ["params", "turnId"]) == "turn-live-handoff"
             end)
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "durable issue session asks the executor to repair missing evidence before human-review" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-evidence-repair-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-issue-session-evidence-repair.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-evidence-repair"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-evidence-missing"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/66","evidence":{"required":true,"bundle_path":".symphony/evidence/missing/manifest.json"}}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-evidence-fixed"}}}'
            mkdir -p .symphony/evidence/fixed
            printf '%s\\n' 'trace bytes' > .symphony/evidence/fixed/trace.zip
            printf '%s\\n' 'npm test passed' > .symphony/evidence/fixed/npm-test.log
            printf '%s\\n' '{"schema_version":"symphony.evidence.v1","summary":"dashboard flow covered","artifacts":[{"kind":"playwright-trace","path":"trace.zip","label":"dashboard trace"}],"commands":[{"command":"npm test","status":"passed","exit_code":0,"output_path":"npm-test.log"}]}' > .symphony/evidence/fixed/manifest.json
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/66","evidence":{"required":true,"bundle_path":".symphony/evidence/fixed/manifest.json"}}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-evidence-repair",
        identifier: "GH-EVIDENCE-REPAIR",
        title: "Repair evidence",
        description: "The worker must repair a missing evidence bundle before review.",
        state: "In Progress",
        url: "https://example.org/issues/GH-EVIDENCE-REPAIR",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Human Review"}]}
      end

      assert {:ok, "issue-session-evidence-repair"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-evidence-repair",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-evidence-repair"
               })

      assert {:ok, "run-evidence-repair"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-evidence-repair",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-evidence-repair",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-evidence-repair",
                 run_id: "run-evidence-repair",
                 issue_state_fetcher: issue_state_fetcher,
                 evidence_review_runner: fn _workspace, _issue, _handoff, _bundle ->
                   {:ok,
                    %{
                      verdict: "pass",
                      summary: "evidence manifest supports the handoff",
                      feedback: %{concerns: []},
                      session_id: "review-session",
                      thread_id: "review-thread"
                    }}
                 end
               )

      assert_receive {:memory_tracker_state_update, "issue-evidence-repair", "Human Review"}, 5_000

      assert_receive {:issue_session_state, "issue-evidence-repair", %{session_state: :parked, health: ["parked"], stop_reason: "human_review"}},
                     5_000

      stored_run = SymphonyElixir.Storage.get_run("run-evidence-repair")
      assert stored_run["state"] == "parked"
      assert Enum.count(stored_run["evidence_reviews"]) == 2
      assert Enum.any?(stored_run["events"], &(&1["message"] == "evidence review did not pass"))
      assert Enum.any?(stored_run["events"], &(&1["message"] == "evidence review passed"))

      turn_texts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 1) =~ "Evidence review feedback:"
      assert Enum.at(turn_texts, 1) =~ "write a fresh `.symphony/handoff.json`"
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "durable issue session moves to needs-input after repeated evidence failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-evidence-needs-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-evidence-needs-input"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-evidence-missing-1"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/67","evidence":{"required":true,"bundle_path":".symphony/evidence/missing/manifest.json"}}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-evidence-missing-2"}}}'
            mkdir -p .symphony
            printf '%s\\n' '{"ready":true,"state":"human-review","reason":"pr-ready","pr_url":"https://example.org/pull/67","evidence":{"required":true,"bundle_path":".symphony/evidence/still-missing/manifest.json"}}' > .symphony/handoff.json
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        evidence_max_review_attempts: 2
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-evidence-needs-input",
        identifier: "GH-EVIDENCE-INPUT",
        title: "Evidence needs input",
        description: "Repeated missing evidence should stop for operator review.",
        state: "In Progress",
        url: "https://example.org/issues/GH-EVIDENCE-INPUT",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] ->
        {:ok, [%{issue | state: "Needs Input"}]}
      end

      assert {:ok, "issue-session-evidence-needs-input"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-evidence-needs-input",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-evidence-needs-input"
               })

      assert {:ok, "run-evidence-needs-input"} =
               SymphonyElixir.Storage.start_run(%{
                 id: "run-evidence-needs-input",
                 issue_identifier: issue.identifier,
                 issue_session_id: "issue-session-evidence-needs-input",
                 state: "running",
                 session_state: "running"
               })

      assert {:ok, _pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-evidence-needs-input",
                 run_id: "run-evidence-needs-input",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:memory_tracker_state_update, "issue-evidence-needs-input", "Needs Input"}, 5_000

      assert_receive {:issue_session_state, "issue-evidence-needs-input", %{session_state: :stopped, health: ["needs-input"], stop_reason: "needs_input"}},
                     5_000

      stored_run = SymphonyElixir.Storage.get_run("run-evidence-needs-input")
      assert stored_run["state"] == "completed"
      assert Enum.count(stored_run["evidence_reviews"]) == 2
      assert Enum.all?(stored_run["evidence_reviews"], &(&1["verdict"] == "request_changes"))
      assert_receive {:memory_tracker_comment, "issue-evidence-needs-input", comment}
      assert comment =~ "Symphony evidence review needs input"
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(test_root)
    end
  end

  test "durable issue session parks at human-review and resumes the same Codex thread for rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-session-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(test_root)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/symphony-issue-session.trace}"
      count=0
      printf 'RUN:%s\\n' "$$" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-durable"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      issue = %Issue{
        id: "issue-durable",
        identifier: "GH-77",
        title: "Keep thread alive",
        description: "Prove durable issue sessions reuse a Codex thread.",
        state: "In Progress",
        url: "https://example.org/issues/GH-77",
        labels: []
      }

      {:ok, state_agent} = Agent.start_link(fn -> ["human-review", "Done"] end)

      issue_state_fetcher = fn [_issue_id] ->
        state_name =
          Agent.get_and_update(state_agent, fn
            [next | rest] -> {next, rest}
            [] -> {"Done", []}
          end)

        {:ok, [%{issue | state: state_name}]}
      end

      assert {:ok, pid} =
               IssueSession.start_link(
                 issue: issue,
                 recipient: self(),
                 issue_session_id: "issue-session-test",
                 run_id: "run-1",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:issue_session_state, "issue-durable", %{session_state: :parked, thread_id: "thread-durable"}}, 5_000

      assert :ok =
               IssueSession.resume(pid, %{issue | state: "Rework"},
                 issue_session_id: "issue-session-test",
                 run_id: "run-2",
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:issue_session_state, "issue-durable", %{session_state: :stopped, thread_id: "thread-durable"}}, 5_000

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Rework continuation:"
      assert Enum.at(turn_texts, 1) =~ "same durable Codex issue session"
      assert Enum.at(turn_texts, 1) =~ "Before broad rediscovery"
      assert Enum.at(turn_texts, 1) =~ "PR-ready handoff"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end
end
