defmodule SymphonyElixir.TaskRunsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, Storage, TaskRuns}

  defmodule FakePlannerAdapter do
    @behaviour SymphonyElixir.CodingAgent.Adapter

    @impl true
    def run(role, workspace, prompt, issue, opts) do
      send(Keyword.fetch!(opts, :test_pid), {
        :planner_run,
        role,
        workspace,
        prompt,
        issue.repo_id,
        Keyword.fetch!(opts, :agent_profile)
      })

      {:ok, %{result: Keyword.fetch!(opts, :planning_json), thread_id: "planner-thread"}}
    end

    @impl true
    def start_session(_role, _workspace, _opts), do: {:ok, %{thread_id: "fake-thread"}}

    @impl true
    def run_turn(_role, session, _prompt, _issue, _opts), do: {:ok, %{thread_id: session.thread_id}}

    @impl true
    def stop_session(_role, _session, _opts), do: :ok
  end

  defmodule FakeGitHub do
    def create_issue(repo_id, title, body, labels) do
      send(Process.whereis(:task_runs_test), {:create_issue, repo_id, title, body, labels})

      {:ok,
       %{
         "number" => 42,
         "title" => title,
         "html_url" => "https://github.test/devp1/Beacon/issues/42"
       }}
    end

    def publish_approved_plan(issue_identifier, manifest) do
      send(Process.whereis(:task_runs_test), {:publish_approved_plan, issue_identifier, manifest})
      :ok
    end
  end

  setup do
    Process.register(self(), :task_runs_test)

    on_exit(fn ->
      if Process.whereis(:task_runs_test) == self() do
        Process.unregister(:task_runs_test)
      end
    end)

    :ok
  end

  test "native goals stay local through planning and create GitHub issues only on approval" do
    test_root = tmp_dir("task-runs-goal")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      agent_profiles: %{
        planner: %{provider: "claude_code", model: "sonnet"},
        reviewer: %{provider: "codex", model: "gpt-5.4"}
      },
      agent_routes: [
        %{
          labels: ["claude-dogfood"],
          executor: %{provider: "claude_code", model: "opus", effort: "high"}
        }
      ],
      hook_after_create: "printf cloned > repo-marker.txt"
    )

    assert {:ok, task_run} =
             TaskRuns.create_goal(%{
               repo_id: "beacon",
               goal_text: "Dogfood Claude Code on a small Beacon task",
               labels: ["claude-dogfood"],
               creator_notes: "Keep it scoped."
             })

    assert task_run["state"] == "planning_queued"
    assert task_run["issue_number"] == nil
    assert task_run["labels"] == ["claude-dogfood"]

    planning_json =
      Jason.encode!(%{
        status: "ready_for_approval",
        summary: "Exercise the Claude Code provider on Beacon.",
        plan_markdown: "## Plan\n\n1. Pick a tiny Beacon issue.\n2. Execute with Claude Code.",
        acceptance_criteria: ["Claude executor profile is used", "PR closes the created issue"],
        test_plan: ["Run focused Symphony adapter tests"],
        risks: ["OAuth session may be unavailable"],
        out_of_scope: ["Flip all Beacon work to Claude"],
        agent_profiles: %{
          executor: %{provider: "claude_code", model: "opus"}
        }
      })

    assert {:ok, planned} =
             TaskRuns.run_planning(task_run["id"],
               adapter: FakePlannerAdapter,
               test_pid: self(),
               planning_json: planning_json
             )

    assert_receive {:planner_run, :planner, workspace, prompt, "beacon", %{provider: "claude_code", model: "sonnet"}}
    assert workspace =~ "/#{task_run["id"]}"
    assert File.read!(Path.join(workspace, "repo-marker.txt")) == "cloned"
    assert prompt =~ "Work read-only"
    assert prompt =~ "Dogfood Claude Code"

    assert planned["state"] == "awaiting_approval"
    assert planned["planning_manifest"]["status"] == "ready_for_approval"
    assert planned["approved_plan"] == nil
    assert Storage.get_task_run(task_run["id"])["events"] |> Enum.any?(&(&1["message"] == "planning manifest recorded"))

    assert {:ok, approved} = TaskRuns.approve_plan(task_run["id"], github_client: FakeGitHub)

    assert_receive {:create_issue, "beacon", title, body, labels}
    assert title == "Dogfood Claude Code on a small Beacon task"
    assert body =~ "## Approved Plan"
    assert body =~ "Claude executor profile is used"
    assert "claude-dogfood" in labels
    assert "symphony" in labels
    assert "agent-ready" in labels

    assert_receive {:publish_approved_plan, "beacon#42", manifest}
    assert manifest["summary"] == "Exercise the Claude Code provider on Beacon."

    assert approved["state"] == "approved"
    assert approved["issue_number"] == 42
    assert approved["issue_identifier"] == "beacon#42"
    assert approved["approved_plan"] == approved["planning_manifest"]
  end

  test "planner questions move task runs to awaiting input and answers queue replanning" do
    assert {:ok, task_run} =
             TaskRuns.create_goal(%{
               repo_id: "beacon",
               goal_text: "Investigate whether this should be docs or code"
             })

    planning_json =
      Jason.encode!(%{
        status: "needs_input",
        summary: "Need one routing decision.",
        questions: [
          %{id: "scope", question: "Should this include code changes?", why: "The request is ambiguous."}
        ]
      })

    assert {:ok, awaiting_input} =
             TaskRuns.run_planning(task_run["id"],
               adapter: FakePlannerAdapter,
               test_pid: self(),
               planning_json: planning_json
             )

    assert awaiting_input["state"] == "awaiting_input"
    assert [%{"id" => "scope"}] = awaiting_input["questions"]

    assert {:ok, queued} = TaskRuns.submit_answers(task_run["id"], [%{question_id: "scope", answer: "Docs only."}])
    assert queued["state"] == "planning_queued"
    assert queued["answers"] == [%{"question_id" => "scope", "answer" => "Docs only."}]
  end

  test "rerun notes preserve original creator notes" do
    assert {:ok, task_run} =
             TaskRuns.create_goal(%{
               repo_id: "beacon",
               goal_text: "Plan a small Beacon improvement",
               creator_notes: "Original instruction."
             })

    assert {:ok, queued} = TaskRuns.rerun_plan(task_run["id"], "Retry after adapter fix.")

    assert queued["state"] == "planning_queued"
    assert queued["creator_notes"] == "Original instruction.\n\nReplan note: Retry after adapter fix."
  end

  test "execution sync records PR and reviewer manifests on approved task runs" do
    assert {:ok, task_run} =
             TaskRuns.create_goal(%{
               repo_id: "beacon",
               goal_text: "Open a small docs PR"
             })

    assert :ok =
             Storage.update_task_run(task_run["id"], %{
               state: "approved",
               issue_number: 42,
               issue_identifier: "beacon#42",
               approved_plan: %{"summary" => "Approved docs plan"}
             })

    assert {:ok, run_id} =
             Storage.start_run(%{
               repo_id: "beacon",
               issue_number: 42,
               issue_identifier: "beacon#42",
               state: "parked",
               workspace_path: "/tmp/symphony-gh-42",
               thread_id: "claude-session-uuid",
               pr_url: "https://github.test/devp1/Beacon/pull/99",
               pr_state: "OPEN",
               check_state: "passing"
             })

    assert {:ok, _review_id} =
             Storage.record_autonomous_review(%{
               run_id: run_id,
               repo_id: "beacon",
               issue_number: 42,
               issue_identifier: "beacon#42",
               pr_url: "https://github.test/devp1/Beacon/pull/99",
               verdict: "pass",
               summary: "Docs-only PR is ready.",
               check_conclusion: "success",
               output_path: "/tmp/review.json"
             })

    issue = %Issue{
      repo_id: "beacon",
      number: 42,
      identifier: "beacon#42",
      state: "human-review",
      pr_url: "https://github.test/devp1/Beacon/pull/99"
    }

    assert :ok = TaskRuns.sync_issue_execution(issue, run_id)

    synced = Storage.get_task_run(task_run["id"])
    assert synced["state"] == "completed"
    assert synced["outcome"] == "pr_ready_for_human_review"
    assert synced["pr_url"] == "https://github.test/devp1/Beacon/pull/99"
    assert synced["pr_number"] == 99
    assert synced["implementation_manifest"]["thread_id"] == "claude-session-uuid"
    assert synced["implementation_manifest"]["check_state"] == "passing"
    assert synced["review_manifest"]["verdict"] == "pass"
    assert synced["review_manifest"]["summary"] == "Docs-only PR is ready."
    assert Enum.any?(synced["events"], &(&1["message"] == "execution synced from issue run"))
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
