defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  defmodule FakeCodingAgentAdapter do
    @behaviour SymphonyElixir.CodingAgent.Adapter

    @impl true
    def run(role, workspace, prompt, issue, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:coding_agent_adapter_run, role, workspace, prompt, issue.identifier})
      maybe_write_autonomous_review(prompt, opts)
      {:ok, %{session_id: "fake-session", thread_id: "fake-thread"}}
    end

    @impl true
    def start_session(role, workspace, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:coding_agent_start_session, role, workspace})
      {:ok, %{thread_id: "fake-thread"}}
    end

    @impl true
    def run_turn(role, session, prompt, issue, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:coding_agent_run_turn, role, session.thread_id, prompt, issue.identifier})
      {:ok, %{session_id: "fake-turn", thread_id: session.thread_id}}
    end

    @impl true
    def stop_session(role, session, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:coding_agent_stop_session, role, session.thread_id})
      :ok
    end

    defp maybe_write_autonomous_review(prompt, opts) do
      case Regex.run(~r/Write exactly this JSON object to ([^,\n]+),/, prompt) do
        [_match, output_path] ->
          File.mkdir_p!(Path.dirname(output_path))

          File.write!(
            output_path,
            Jason.encode!(%{
              verdict: Keyword.get(opts, :review_verdict, "pass"),
              summary: Keyword.get(opts, :review_summary, "fake autonomous review"),
              head_sha: Keyword.get(opts, :review_head_sha, "abc123"),
              findings: Keyword.get(opts, :review_findings, [])
            })
          )

        _ ->
          :ok
      end
    end
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.runtime_profile == "default"
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.github.builder_token == nil
    assert config.github.reviewer_token == nil
    assert config.github.review_check_name == "symphony/autonomous-review"
    assert config.github.required_check_names == []
    assert config.agent.max_turns == 20
    assert config.agent.artifact_nudge_tokens == 250_000
    assert config.agent.max_artifact_nudges == 1
    assert config.agent.max_tokens_before_first_artifact == 200_000
    assert config.agent.max_tokens_without_artifact == 250_000
    assert config.evidence.enabled == true
    assert config.evidence.force_labels == ["evidence-required"]
    assert config.evidence.skip_labels == ["evidence-skip"]
    assert config.evidence.review_gate == "blocking"
    assert config.evidence.max_review_attempts == 2

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), artifact_nudge_tokens: 0)
    assert Config.settings!().agent.artifact_nudge_tokens == 0

    write_workflow_file!(Workflow.workflow_file_path(), artifact_nudge_tokens: 42_000)
    assert Config.settings!().agent.artifact_nudge_tokens == 42_000

    write_workflow_file!(Workflow.workflow_file_path(), artifact_nudge_tokens: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.artifact_nudge_tokens"

    write_workflow_file!(Workflow.workflow_file_path(), max_artifact_nudges: 0)
    assert Config.settings!().agent.max_artifact_nudges == 0

    write_workflow_file!(Workflow.workflow_file_path(), max_artifact_nudges: 2)
    assert Config.settings!().agent.max_artifact_nudges == 2

    write_workflow_file!(Workflow.workflow_file_path(), max_artifact_nudges: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_artifact_nudges"

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_without_artifact: 0)
    assert Config.settings!().agent.max_tokens_without_artifact == 0

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_without_artifact: 42_000)
    assert Config.settings!().agent.max_tokens_without_artifact == 42_000

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_without_artifact: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_tokens_without_artifact"

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_before_first_artifact: 0)
    assert Config.settings!().agent.max_tokens_before_first_artifact == 0

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_before_first_artifact: 42_000)
    assert Config.settings!().agent.max_tokens_before_first_artifact == 42_000

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_before_first_artifact: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_tokens_before_first_artifact"

    write_workflow_file!(Workflow.workflow_file_path(), evidence_review_gate: "advisory")
    assert Config.settings!().evidence.review_gate == "advisory"

    write_workflow_file!(Workflow.workflow_file_path(), evidence_review_gate: "nope")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "evidence.review_gate"

    write_workflow_file!(Workflow.workflow_file_path(), evidence_max_review_attempts: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "evidence.max_review_attempts"

    write_workflow_file!(Workflow.workflow_file_path(),
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token",
      github_review_check_name: "symphony/review",
      github_required_check_names: ["test", " test ", ""]
    )

    assert Config.settings!().github.builder_token == "builder-token"
    assert Config.settings!().github.reviewer_token == "reviewer-token"
    assert Config.settings!().github.review_check_name == "symphony/review"
    assert Config.settings!().github.required_check_names == ["test"]
    assert Config.independent_github_reviewer?()

    write_workflow_file!(Workflow.workflow_file_path(),
      github_builder_token: "same-token",
      github_reviewer_token: "same-token"
    )

    refute Config.independent_github_reviewer?()

    write_workflow_file!(Workflow.workflow_file_path(),
      github_builder_app: %{app_id: "100", installation_id: "200", private_key_path: "/tmp/builder.pem"},
      github_reviewer_app: %{app_id: "101", installation_id: "201", private_key_path: "/tmp/reviewer.pem"}
    )

    assert Config.settings!().github.builder_app.app_id == "100"
    assert Config.settings!().github.reviewer_app.installation_id == "201"
    assert {:app, %{app_id: "101", installation_id: "201"}} = Config.github_auth(:reviewer)
    assert Config.independent_github_reviewer?()

    write_workflow_file!(Workflow.workflow_file_path(),
      github_builder_app: %{app_id: "100", installation_id: "200", private_key_path: "/tmp/builder.pem"},
      github_reviewer_app: %{app_id: "100", installation_id: "200", private_key_path: "/tmp/reviewer.pem"}
    )

    refute Config.independent_github_reviewer?()

    write_workflow_file!(Workflow.workflow_file_path(),
      github_builder_app: %{app_id: "100", installation_id: "200"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "github.builder_app.private_key_path"

    write_workflow_file!(Workflow.workflow_file_path(), runtime_profile: "too_trusting")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "runtime_profile"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: nil,
      tracker_repo: "Beacon"
    )

    assert {:error, :missing_github_owner} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: nil
    )

    assert {:error, :missing_github_repo} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    assert :ok = Config.validate!()
    assert Tracker.adapter() == SymphonyElixir.GitHub.Adapter
  end

  test "coding agent delegates roles through the configured adapter" do
    issue = %Issue{id: "issue-1", identifier: "GH-1", title: "Adapter boundary", state: "In Progress"}

    assert {:ok, %{session_id: "fake-session", thread_id: "fake-thread"}} =
             SymphonyElixir.CodingAgent.run(:reviewer, "/tmp/workspace", "review evidence", issue,
               adapter: FakeCodingAgentAdapter,
               test_pid: self()
             )

    assert_receive {:coding_agent_adapter_run, :reviewer, "/tmp/workspace", "review evidence", "GH-1"}

    assert {:ok, session} =
             SymphonyElixir.CodingAgent.start_session(:executor, "/tmp/workspace",
               adapter: FakeCodingAgentAdapter,
               test_pid: self()
             )

    assert_receive {:coding_agent_start_session, :executor, "/tmp/workspace"}

    assert {:ok, %{session_id: "fake-turn", thread_id: "fake-thread"}} =
             SymphonyElixir.CodingAgent.run_turn(:executor, session, "continue", issue,
               adapter: FakeCodingAgentAdapter,
               test_pid: self()
             )

    assert_receive {:coding_agent_run_turn, :executor, "fake-thread", "continue", "GH-1"}

    assert :ok =
             SymphonyElixir.CodingAgent.stop_session(:executor, session,
               adapter: FakeCodingAgentAdapter,
               test_pid: self()
             )

    assert_receive {:coding_agent_stop_session, :executor, "fake-thread"}

    assert {:error, {:unsupported_agent_role, :planner}} =
             SymphonyElixir.CodingAgent.run(:planner, "/tmp/workspace", "plan", issue,
               adapter: FakeCodingAgentAdapter,
               test_pid: self()
             )
  end

  test "autonomous review normalizes verdicts and gates merge readiness" do
    issue = %Issue{
      id: "beacon#25",
      identifier: "GH-25",
      title: "PR-ready handoff",
      state: "Human Review",
      repo_id: "beacon",
      number: 25,
      pr_url: "https://github.com/devp1/Beacon/pull/25",
      pr_number: 25,
      pr_state: "OPEN",
      head_sha: "abc123",
      check_state: "passing"
    }

    assert SymphonyElixir.AutonomousReview.normalize_verdict("fail") == "request_changes"
    assert SymphonyElixir.AutonomousReview.check_conclusion(:needs_input) == "action_required"

    assert %{ready?: true, reasons: [], review_verdict: "pass", review_stale?: false} =
             SymphonyElixir.AutonomousReview.merge_gate(issue, %{verdict: "pass", head_sha: "abc123"})

    assert %{ready?: false, reasons: reasons, review_stale?: true} =
             SymphonyElixir.AutonomousReview.merge_gate(%{issue | check_state: "pending"}, %{
               verdict: "pass",
               head_sha: "old-sha"
             })

    assert "ci-not-green" in reasons
    assert "autonomous-review-stale" in reasons

    assert %{ready?: false, reasons: no_ci_reasons} =
             SymphonyElixir.AutonomousReview.merge_gate(%{issue | check_state: "none"}, %{verdict: "pass", head_sha: "abc123"})

    assert "ci-not-reported" in no_ci_reasons
    refute "ci-not-green" in no_ci_reasons

    assert {:ok, _review_id} =
             SymphonyElixir.AutonomousReview.record(issue, %{
               run_id: "run-review",
               verdict: :pass,
               summary: "clean",
               head_sha: "abc123"
             })

    assert [%{"run_id" => "run-review", "verdict" => "pass", "stale" => 0} | _] =
             SymphonyElixir.Storage.list_autonomous_reviews()
  end

  test "autonomous review pass publish requires independent reviewer identity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "same-token",
      github_reviewer_token: "same-token"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
      send(parent, {:unexpected_gh_args, args, env})
      {"{}", 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    issue = %Issue{
      id: "beacon#25",
      identifier: "GH-25",
      title: "PR-ready handoff",
      repo_id: "beacon",
      repo_owner: "devp1",
      repo_name: "Beacon",
      number: 25,
      pr_url: "https://github.com/devp1/Beacon/pull/25",
      pr_number: 25,
      head_sha: "abc123"
    }

    assert {:error, :reviewer_identity_not_independent} =
             SymphonyElixir.AutonomousReview.publish(issue, %{verdict: "pass", summary: "clean"})

    refute_received {:unexpected_gh_args, _args, _env}
    assert [] = SymphonyElixir.Storage.list_autonomous_reviews()
  end

  test "autonomous review runs a reviewer agent and publishes the check/review" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-autonomous-review-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_owner: "devp1",
        tracker_repo: "Beacon",
        github_builder_token: "builder-token",
        github_reviewer_token: "reviewer-token"
      )

      issue = %Issue{
        id: "25",
        identifier: "GH-25",
        title: "Review me",
        state: "Human Review",
        repo_id: "beacon",
        repo_owner: "devp1",
        repo_name: "Beacon",
        number: 25,
        pr_url: "https://github.com/devp1/Beacon/pull/25",
        pr_number: 25,
        pr_state: "OPEN",
        head_sha: "abc123",
        check_state: "passing"
      }

      parent = self()

      Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
        send(parent, {:gh_args, args, env})
        {Jason.encode!(%{"id" => 123}), 0}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

      assert {:ok, review} =
               SymphonyElixir.AutonomousReview.review_and_publish(workspace, issue,
                 adapter: FakeCodingAgentAdapter,
                 test_pid: self(),
                 review_verdict: "request_changes",
                 review_summary: "Needs a fix",
                 review_findings: [%{title: "Bug", body: "Fix the edge case."}]
               )

      assert review.verdict == "request_changes"
      assert review.summary == "Needs a fix"
      assert review.head_sha == "abc123"
      assert File.regular?(review.output_path)

      assert_receive {:coding_agent_adapter_run, :reviewer, ^workspace, prompt, "GH-25-autonomous-review"}
      assert prompt =~ "Autonomous PR review contract"
      assert prompt =~ "https://github.com/devp1/Beacon/pull/25"

      assert_received {:gh_args, review_args, [{"GH_TOKEN", "reviewer-token"}, {"GITHUB_TOKEN", "reviewer-token"}]}
      assert ["api", "repos/devp1/Beacon/pulls/25/reviews" | _] = review_args
      assert "event=REQUEST_CHANGES" in review_args

      assert_received {:gh_args, check_args, [{"GH_TOKEN", "reviewer-token"}, {"GITHUB_TOKEN", "reviewer-token"}]}
      assert ["api", "repos/devp1/Beacon/check-runs" | _] = check_args
      assert "conclusion=failure" in check_args

      assert [
               %{
                 "verdict" => "request_changes",
                 "summary" => "Needs a fix",
                 "head_sha" => "abc123",
                 "check_conclusion" => "failure",
                 "stale" => 0
               }
               | _
             ] = SymphonyElixir.Storage.list_autonomous_reviews()
    after
      File.rm_rf(workspace)
    end
  end

  test "handoff parser normalizes evidence metadata" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-handoff-evidence-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(Path.join(workspace, ".symphony"))

      File.write!(
        Path.join([workspace, ".symphony", "handoff.json"]),
        Jason.encode!(%{
          ready: true,
          state: "human-review",
          pr_url: "https://github.com/devp1/Beacon/pull/22",
          evidence: %{
            required: true,
            bundlePath: ".symphony/evidence/run-1/manifest.json",
            reason: "dashboard flow changed"
          }
        })
      )

      assert {:ok,
              %{
                state: "human-review",
                tracker_state: "Human Review",
                evidence: %{
                  required: true,
                  bundle_path: ".symphony/evidence/run-1/manifest.json",
                  reason: "dashboard flow changed"
                }
              } = handoff} = SymphonyElixir.Handoff.read(workspace)

      assert SymphonyElixir.Handoff.storage_payload(handoff).evidence.required == true
    after
      File.rm_rf(workspace)
    end
  end

  test "evidence bundle loader validates and normalizes inspectable manifest entries" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-evidence-manifest-#{System.unique_integer([:positive])}"
      )

    try do
      bundle_dir = Path.join([workspace, ".symphony", "evidence", "run-1"])
      File.mkdir_p!(bundle_dir)
      File.write!(Path.join(bundle_dir, "trace.zip"), "trace bytes\n")
      File.write!(Path.join(bundle_dir, "npm-test.log"), "test output\n")

      File.write!(
        Path.join(bundle_dir, "manifest.json"),
        Jason.encode!(%{
          schema_version: "symphony.evidence.v1",
          summary: "Settings flow is covered by trace and test output.",
          artifacts: [
            %{
              kind: "playwright-trace",
              label: "Settings flow trace",
              path: "trace.zip"
            }
          ],
          commands: [
            %{
              command: "npm test",
              status: "passed",
              exit_code: 0,
              output_path: "npm-test.log"
            }
          ],
          changed_files: ["lib/settings.ex"]
        })
      )

      assert {:ok, bundle} =
               SymphonyElixir.Evidence.load_bundle(workspace, %{
                 required: true,
                 bundle_path: ".symphony/evidence/run-1"
               })

      assert bundle.manifest["schema_version"] == "symphony.evidence.v1"
      assert bundle.manifest["summary"] == "Settings flow is covered by trace and test output."

      assert [
               %{
                 "kind" => "playwright-trace",
                 "path" => "trace.zip",
                 "workspace_path" => ".symphony/evidence/run-1/trace.zip"
               }
             ] = bundle.manifest["artifacts"]

      assert [
               %{
                 "command" => "npm test",
                 "status" => "passed",
                 "exit_code" => 0,
                 "output_path" => "npm-test.log",
                 "workspace_output_path" => ".symphony/evidence/run-1/npm-test.log"
               }
             ] = bundle.manifest["commands"]
    after
      File.rm_rf(workspace)
    end
  end

  test "evidence bundle loader rejects summary-only or escaped manifest entries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-evidence-manifest-invalid-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      bundle_dir = Path.join([workspace, ".symphony", "evidence", "run-1"])
      outside_log = Path.join(test_root, "outside.log")

      File.mkdir_p!(bundle_dir)
      File.write!(outside_log, "outside\n")

      manifest_path = Path.join(bundle_dir, "manifest.json")

      File.write!(
        manifest_path,
        Jason.encode!(%{
          schema_version: "symphony.evidence.v1",
          summary: "No concrete proof yet."
        })
      )

      assert {:error, {:invalid_evidence_manifest, errors}} =
               SymphonyElixir.Evidence.load_bundle(workspace, %{
                 required: true,
                 bundle_path: ".symphony/evidence/run-1"
               })

      assert :missing_proof_entries in errors

      File.write!(
        manifest_path,
        Jason.encode!(%{
          schema_version: "symphony.evidence.v1",
          summary: "Escaped path should not validate.",
          artifacts: [%{kind: "log", path: outside_log}]
        })
      )

      assert {:error, {:invalid_evidence_manifest, errors}} =
               SymphonyElixir.Evidence.load_bundle(workspace, %{
                 required: true,
                 bundle_path: ".symphony/evidence/run-1"
               })

      assert Enum.any?(errors, fn
               {{:artifact_path, 0}, {:path_escape, _escaped_path, _workspace_root}} -> true
               _error -> false
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "local trusted runtime profile grants full local access but keeps remote scoped" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-local-trusted-root-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "GH-1")

    try do
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        runtime_profile: "local_trusted",
        workspace_root: workspace_root
      )

      policy = Config.codex_turn_sandbox_policy(workspace)
      assert policy == %{"type" => "dangerFullAccess"}

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(workspace)
      assert runtime_settings.thread_sandbox == "danger-full-access"
      assert runtime_settings.turn_sandbox_policy == %{"type" => "dangerFullAccess"}

      assert {:ok, remote_runtime_settings} = Config.codex_runtime_settings(workspace, remote: true)
      assert remote_runtime_settings.thread_sandbox == "workspace-write"
      assert remote_runtime_settings.turn_sandbox_policy["type"] == "workspaceWrite"
      assert remote_runtime_settings.turn_sandbox_policy["networkAccess"] == true
      assert workspace in remote_runtime_settings.turn_sandbox_policy["writableRoots"]

      write_workflow_file!(Workflow.workflow_file_path(),
        runtime_profile: "local_trusted",
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{type: "workspaceWrite"}
      )

      policy = Config.codex_turn_sandbox_policy(workspace)
      assert policy["type"] == "workspaceWrite"
      assert policy["networkAccess"] == true
      assert Path.expand(workspace) in policy["writableRoots"]

      write_workflow_file!(Workflow.workflow_file_path(),
        runtime_profile: "local_trusted",
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{type: "dangerFullAccess"}
      )

      assert Config.codex_turn_sandbox_policy(workspace) == %{"type" => "dangerFullAccess"}
    after
      File.rm_rf(workspace_root)
    end
  end

  test "github multi-repo config normalizes labels and workspace roots" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-multi-repo-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      workspace_root: workspace_root,
      repos: [
        %{id: "beacon", owner: "devp1", name: "Beacon", labels: %{queued: "agent-ready"}},
        %{owner: "openai", name: "symphony", workspace_root: "$SYMPHONY_TEST_REPO_ROOT"}
      ]
    )

    previous_root = System.get_env("SYMPHONY_TEST_REPO_ROOT")
    on_exit(fn -> restore_env("SYMPHONY_TEST_REPO_ROOT", previous_root) end)
    System.put_env("SYMPHONY_TEST_REPO_ROOT", Path.join(workspace_root, "custom-symphony"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      workspace_root: workspace_root,
      repos: [
        %{id: "beacon", owner: "devp1", name: "Beacon", labels: %{queued: "agent-ready"}},
        %{owner: "openai", name: "symphony", workspace_root: "$SYMPHONY_TEST_REPO_ROOT"}
      ]
    )

    assert :ok = Config.validate!()
    [beacon, symphony] = Config.repos()

    assert beacon.id == "beacon"
    assert beacon.clone_url == "https://github.com/devp1/Beacon.git"
    assert beacon.workspace_root == Path.join(workspace_root, "beacon")
    assert beacon.labels["managed"] == "symphony"
    assert beacon.labels["queued"] == "agent-ready"

    assert symphony.id == "openai-symphony"
    assert symphony.workspace_root == Path.join(workspace_root, "custom-symphony")
  end

  test "sqlite storage persists repos, issue snapshots, runs, events, and artifacts" do
    assert :ok =
             SymphonyElixir.Storage.upsert_repo(%{
               id: "beacon",
               owner: "devp1",
               name: "Beacon",
               clone_url: "https://github.com/devp1/Beacon.git",
               workspace_root: "/tmp/beacon",
               labels: %{"managed" => "symphony"}
             })

    assert :ok =
             SymphonyElixir.Storage.record_issue_snapshot(%{
               repo_id: "beacon",
               number: 10,
               identifier: "beacon-10",
               title: "Authenticated runner proof",
               state: "Todo",
               url: "https://github.com/devp1/Beacon/issues/10",
               labels: ["symphony", "agent-ready"],
               pr_url: "https://github.com/devp1/Beacon/pull/11",
               head_sha: "abc123",
               pr_state: "OPEN",
               check_state: "passing",
               review_state: "APPROVED"
             })

    assert {:ok, run_id} =
             SymphonyElixir.Storage.start_run(%{
               repo_id: "beacon",
               issue_number: 10,
               issue_identifier: "beacon-10",
               state: "running",
               workspace_path: "/tmp/beacon/GH-10"
             })

    assert :ok = SymphonyElixir.Storage.append_event(run_id, "info", "started", %{tokens: 0})
    assert :ok = SymphonyElixir.Storage.put_artifact(run_id, %{kind: "log", path: "/tmp/log.txt", label: "log"})

    assert {:ok, bundle_id} =
             SymphonyElixir.Storage.upsert_evidence_bundle(%{
               run_id: run_id,
               issue_session_id: "issue-session-10",
               issue_identifier: "beacon-10",
               workspace_path: "/tmp/beacon/GH-10",
               manifest_path: "/tmp/beacon/GH-10/.symphony/evidence/manifest.json",
               required: true,
               status: "review_passed",
               verdict: "pass",
               summary: "trace covers the changed flow"
             })

    assert {:ok, _review_id} =
             SymphonyElixir.Storage.record_evidence_review(%{
               bundle_id: bundle_id,
               run_id: run_id,
               issue_session_id: "issue-session-10",
               attempt: 1,
               verdict: "pass",
               summary: "sufficient evidence",
               feedback: %{concerns: []},
               output_path: "/tmp/beacon/GH-10/.symphony/evidence/reviews/review.json"
             })

    assert {:ok, autonomous_review_id} =
             SymphonyElixir.Storage.record_autonomous_review(%{
               run_id: run_id,
               issue_session_id: "issue-session-10",
               repo_id: "beacon",
               issue_number: 10,
               issue_identifier: "beacon-10",
               pr_url: "https://github.com/devp1/Beacon/pull/11",
               head_sha: "abc123",
               verdict: "pass",
               summary: "ready for human review",
               findings: [],
               check_name: "symphony/autonomous-review",
               check_conclusion: "success"
             })

    assert :ok = SymphonyElixir.Storage.update_run(run_id, %{state: "human_review", pr_url: "https://github.com/devp1/Beacon/pull/11"})

    assert [%{"id" => "beacon"}] = SymphonyElixir.Storage.list_repos()

    assert [
             %{
               "identifier" => "beacon-10",
               "labels" => ["symphony", "agent-ready"],
               "pr_url" => "https://github.com/devp1/Beacon/pull/11",
               "head_sha" => "abc123",
               "pr_state" => "OPEN",
               "check_state" => "passing",
               "review_state" => "APPROVED"
             }
           ] = SymphonyElixir.Storage.list_issues()

    assert [%{"id" => ^run_id, "state" => "human_review"} | _] = SymphonyElixir.Storage.list_runs()

    assert %{
             "events" => [%{"message" => "started", "data" => %{"tokens" => 0}}],
             "evidence_bundles" => [%{"id" => ^bundle_id, "status" => "review_passed", "verdict" => "pass"}],
             "evidence_reviews" => [%{"bundle_id" => ^bundle_id, "verdict" => "pass"}],
             "autonomous_reviews" => [%{"id" => ^autonomous_review_id, "verdict" => "pass", "check_conclusion" => "success"}]
           } =
             SymphonyElixir.Storage.get_run(run_id)

    assert [%{"id" => ^bundle_id, "status" => "review_passed"} | _] = SymphonyElixir.Storage.list_evidence_bundles()
    assert [%{"bundle_id" => ^bundle_id, "verdict" => "pass"} | _] = SymphonyElixir.Storage.list_evidence_reviews()
    assert [%{"id" => ^autonomous_review_id, "verdict" => "pass"} | _] = SymphonyElixir.Storage.list_autonomous_reviews()
  end

  test "sqlite storage marks stale running runs interrupted on startup recovery" do
    assert {:ok, stale_run_id} =
             SymphonyElixir.Storage.start_run(%{
               repo_id: "beacon",
               issue_number: 10,
               issue_identifier: "beacon-10",
               state: "running",
               workspace_path: "/tmp/beacon/GH-10"
             })

    assert {:ok, completed_run_id} =
             SymphonyElixir.Storage.start_run(%{
               repo_id: "beacon",
               issue_number: 11,
               issue_identifier: "beacon-11",
               state: "human_review",
               workspace_path: "/tmp/beacon/GH-11"
             })

    assert {:ok, 1} = SymphonyElixir.Storage.interrupt_running_runs("test startup recovery")

    assert %{
             "state" => "cancelled",
             "error" => "test startup recovery",
             "events" => [%{"message" => "startup recovery marked run interrupted"}]
           } = SymphonyElixir.Storage.get_run(stale_run_id)

    assert %{"state" => "human_review", "error" => nil} = SymphonyElixir.Storage.get_run(completed_run_id)
    assert {:ok, 0} = SymphonyElixir.Storage.interrupt_running_runs("test startup recovery")
  end

  test "sqlite storage marks stale active issue sessions resumable on startup recovery" do
    assert {:ok, stale_session_id} =
             SymphonyElixir.Storage.start_issue_session(%{
               repo_id: "beacon",
               issue_number: 10,
               issue_identifier: "beacon-10",
               workspace_path: "/tmp/beacon/GH-10",
               codex_thread_id: "thread-10",
               state: "running"
             })

    assert {:ok, parked_session_id} =
             SymphonyElixir.Storage.start_issue_session(%{
               repo_id: "beacon",
               issue_number: 11,
               issue_identifier: "beacon-11",
               workspace_path: "/tmp/beacon/GH-11",
               codex_thread_id: "thread-11",
               state: "parked"
             })

    assert {:ok, 1} = SymphonyElixir.Storage.interrupt_running_issue_sessions("test startup recovery")

    sessions = SymphonyElixir.Storage.list_issue_sessions()

    assert %{
             "state" => "interrupted-resumable",
             "stop_reason" => "test startup recovery",
             "health" => ["interrupted-resumable"],
             "codex_thread_id" => "thread-10"
           } = Enum.find(sessions, &(&1["id"] == stale_session_id))

    assert %{
             "state" => "parked",
             "stop_reason" => nil,
             "health" => ["healthy"],
             "codex_thread_id" => "thread-11"
           } = Enum.find(sessions, &(&1["id"] == parked_session_id))

    assert {:ok, 0} = SymphonyElixir.Storage.interrupt_running_issue_sessions("test startup recovery")
  end

  test "startup recovery preserves review-ready stale runs as parked handoffs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "beacon#18",
      identifier: "GH-18",
      title: "Review-ready dogfood issue",
      state: "Human Review",
      repo_id: "beacon",
      number: 18,
      pr_url: "https://github.com/devp1/Beacon/pull/22",
      pr_state: "OPEN",
      check_state: "none",
      review_state: ""
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, "issue-session-review-ready"} =
             SymphonyElixir.Storage.start_issue_session(%{
               id: "issue-session-review-ready",
               repo_id: "beacon",
               issue_number: 18,
               issue_identifier: "GH-18",
               workspace_path: "/tmp/beacon/GH-18",
               codex_thread_id: "thread-18",
               app_server_pid: "12345",
               state: "running",
               current_run_id: "run-review-ready"
             })

    assert {:ok, "run-review-ready"} =
             SymphonyElixir.Storage.start_run(%{
               id: "run-review-ready",
               repo_id: "beacon",
               issue_number: 18,
               issue_identifier: "GH-18",
               issue_session_id: "issue-session-review-ready",
               state: "running",
               workspace_path: "/tmp/beacon/GH-18",
               thread_id: "thread-18",
               turn_count: 3,
               session_state: "running",
               health: ["healthy"]
             })

    assert {:ok, "issue-session-review-ready-interrupted"} =
             SymphonyElixir.Storage.start_issue_session(%{
               id: "issue-session-review-ready-interrupted",
               repo_id: "beacon",
               issue_number: 18,
               issue_identifier: "GH-18",
               workspace_path: "/tmp/beacon/GH-18",
               codex_thread_id: "thread-18b",
               app_server_pid: "67890",
               state: "interrupted-resumable",
               current_run_id: "run-review-ready-interrupted",
               stop_reason: "interrupted on Symphony startup; Codex app-server thread did not survive daemon restart",
               health: ["interrupted-resumable"]
             })

    assert {:ok, "run-review-ready-interrupted"} =
             SymphonyElixir.Storage.start_run(%{
               id: "run-review-ready-interrupted",
               repo_id: "beacon",
               issue_number: 18,
               issue_identifier: "GH-18",
               issue_session_id: "issue-session-review-ready-interrupted",
               state: "cancelled",
               error: "interrupted on Symphony startup before live worker recovery",
               workspace_path: "/tmp/beacon/GH-18",
               thread_id: "thread-18b",
               turn_count: 4,
               session_state: "running",
               health: ["interrupted-resumable"]
             })

    assert :ok = Orchestrator.preserve_human_review_storage_for_test()
    assert {:ok, 0} = SymphonyElixir.Storage.interrupt_running_runs("test startup recovery")
    assert {:ok, 0} = SymphonyElixir.Storage.interrupt_running_issue_sessions("test startup recovery")

    stored_run = SymphonyElixir.Storage.get_run("run-review-ready")

    assert stored_run["state"] == "parked"
    assert stored_run["session_state"] == "parked"
    assert stored_run["error"] == nil
    assert stored_run["pr_url"] == "https://github.com/devp1/Beacon/pull/22"
    assert Enum.any?(stored_run["events"], &(&1["message"] == "startup recovery preserved human-review handoff"))

    stored_interrupted_run = SymphonyElixir.Storage.get_run("run-review-ready-interrupted")

    assert stored_interrupted_run["state"] == "parked"
    assert stored_interrupted_run["session_state"] == "parked"
    assert stored_interrupted_run["error"] == nil
    assert stored_interrupted_run["pr_url"] == "https://github.com/devp1/Beacon/pull/22"

    stored_session =
      Enum.find(SymphonyElixir.Storage.list_issue_sessions(), &(&1["id"] == "issue-session-review-ready"))

    assert stored_session["state"] == "parked"
    assert stored_session["health"] == ["parked"]
    assert stored_session["stop_reason"] == "human_review"
    assert stored_session["app_server_pid"] == nil

    stored_interrupted_session =
      Enum.find(
        SymphonyElixir.Storage.list_issue_sessions(),
        &(&1["id"] == "issue-session-review-ready-interrupted")
      )

    assert stored_interrupted_session["state"] == "parked"
    assert stored_interrupted_session["health"] == ["parked"]
    assert stored_interrupted_session["stop_reason"] == "human_review"
    assert stored_interrupted_session["app_server_pid"] == nil
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "github"
    assert Map.get(tracker, "owner") == "devp1"
    assert Map.get(tracker, "repo") == "Beacon"
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    assert [%{"id" => "beacon", "owner" => "devp1", "name" => "Beacon"}] = Map.get(config, "repos")

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone https://github.com/devp1/Beacon.git ."
    assert Map.get(hooks, "after_create") =~ "mise trust"
    assert Map.get(hooks, "before_run") =~ "git switch"
    assert Map.get(hooks, "before_run") =~ "codex/"
    assert Map.get(hooks, "before_remove") =~ "git status --short"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  test "claim_issue_for_dispatch claims queued and rework issues before worker launch" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      queued_issue = %Issue{id: "issue-claim-todo", identifier: "MT-CLAIM-1", state: "Todo", title: "Claim queued"}
      rework_issue = %Issue{id: "issue-claim-rework", identifier: "MT-CLAIM-2", state: "Rework", title: "Claim rework"}

      assert {:ok, claimed_queued} = Orchestrator.claim_issue_for_dispatch_for_test(queued_issue)
      assert claimed_queued.state == "In Progress"
      assert_receive {:memory_tracker_state_update, "issue-claim-todo", "In Progress"}

      assert {:ok, claimed_rework} = Orchestrator.claim_issue_for_dispatch_for_test(rework_issue)
      assert claimed_rework.state == "In Progress"
      assert_receive {:memory_tracker_state_update, "issue-claim-rework", "In Progress"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "claim_issue_for_dispatch leaves already-running issues unchanged" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{id: "issue-claim-running", identifier: "MT-CLAIM-3", state: "In Progress", title: "Already running"}

      assert {:ok, ^issue} = Orchestrator.claim_issue_for_dispatch_for_test(issue)
      refute_receive {:memory_tracker_state_update, "issue-claim-running", _state}, 50
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "cancel_run moves the issue to needs-input and suppresses immediate redispatch" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-cancel",
        identifier: "MT-CANCEL",
        title: "Cancel should pause",
        description: "A cancelled run should not be redispatched while still labeled in progress.",
        state: "In Progress",
        labels: []
      }

      pid = sleeping_agent_pid()
      ref = Process.monitor(pid)

      assert {:ok, "issue-session-cancel"} =
               SymphonyElixir.Storage.start_issue_session(%{
                 id: "issue-session-cancel",
                 issue_identifier: issue.identifier,
                 state: "running",
                 current_run_id: "run-cancel",
                 workspace_path: "/tmp/symphony-cancel"
               })

      state = %Orchestrator.State{
        running: %{
          "issue-cancel" => %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            run_id: "run-cancel",
            session_kind: :durable,
            session_state: :running,
            issue_session_id: "issue-session-cancel",
            workspace_path: "/tmp/symphony-cancel",
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new(["issue-cancel"]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:reply, {:ok, response}, next_state} =
               Orchestrator.handle_call({:cancel_run, "run-cancel"}, self(), state)

      assert response.paused == true
      assert response.pause_state == "Needs Input"
      refute Map.has_key?(next_state.running, "issue-cancel")
      refute MapSet.member?(next_state.claimed, "issue-cancel")
      assert MapSet.member?(next_state.operator_paused_issue_ids, "issue-cancel")

      assert_receive {:memory_tracker_comment, "issue-cancel", comment}
      assert comment =~ "Symphony paused"
      assert comment =~ "operator cancelled run"
      assert_receive {:memory_tracker_state_update, "issue-cancel", "Needs Input"}

      refute Orchestrator.should_dispatch_issue_for_test(issue, next_state)

      stored_session =
        Enum.find(SymphonyElixir.Storage.list_issue_sessions(), &(&1["id"] == "issue-session-cancel"))

      assert stored_session["state"] == "interrupted-resumable"
      assert stored_session["stop_reason"] == "operator cancelled run"
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "human-review reconciliation persists parked durable session state" do
    issue = %Issue{
      id: "issue-park",
      identifier: "GH-PARK",
      title: "Park cleanly",
      description: "The persisted cockpit state should match the runtime parked state.",
      state: "In Progress",
      repo_id: "beacon",
      number: 13,
      labels: []
    }

    assert {:ok, "issue-session-park"} =
             SymphonyElixir.Storage.start_issue_session(%{
               id: "issue-session-park",
               repo_id: issue.repo_id,
               issue_number: issue.number,
               issue_identifier: issue.identifier,
               state: "running",
               current_run_id: "run-park",
               workspace_path: "/tmp/symphony-park",
               codex_thread_id: "thread-park",
               health: ["healthy"]
             })

    assert {:ok, "run-park"} =
             SymphonyElixir.Storage.start_run(%{
               id: "run-park",
               repo_id: issue.repo_id,
               issue_number: issue.number,
               issue_identifier: issue.identifier,
               issue_session_id: "issue-session-park",
               state: "running",
               workspace_path: "/tmp/symphony-park",
               thread_id: "thread-park",
               turn_count: 2,
               session_state: "running",
               health: ["healthy"]
             })

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: self(),
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          run_id: "run-park",
          session_kind: :durable,
          session_state: :running,
          issue_session_id: "issue-session-park",
          workspace_path: "/tmp/symphony-park",
          thread_id: "thread-park",
          turn_count: 2,
          health: ["healthy"],
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    next_state =
      Orchestrator.reconcile_issue_states_for_test(
        [%{issue | state: "human-review"}],
        state
      )

    assert %{session_state: :parked, health: ["parked"], stop_reason: "human_review"} =
             next_state.running[issue.id]

    assert %DateTime{} = next_state.running[issue.id].parked_at

    stored_session =
      Enum.find(SymphonyElixir.Storage.list_issue_sessions(), &(&1["id"] == "issue-session-park"))

    assert stored_session["state"] == "parked"
    assert stored_session["current_run_id"] == "run-park"
    assert stored_session["codex_thread_id"] == "thread-park"
    assert stored_session["health"] == ["parked"]
    assert stored_session["stop_reason"] == "human_review"

    stored_run = SymphonyElixir.Storage.get_run("run-park")

    assert stored_run["state"] == "parked"
    assert stored_run["session_state"] == "parked"
    assert stored_run["issue_session_id"] == "issue-session-park"
    assert stored_run["thread_id"] == "thread-park"
    assert stored_run["turn_count"] == 2
    assert stored_run["health"] == ["parked"]
    assert is_nil(stored_run["error"])
    assert Enum.any?(stored_run["events"], &(&1["message"] == "durable issue session parked"))

    next_state_after_second_reconcile =
      Orchestrator.reconcile_issue_states_for_test(
        [%{issue | state: "human-review"}],
        next_state
      )

    assert %{session_state: :parked, health: ["parked"], stop_reason: "human_review"} =
             next_state_after_second_reconcile.running[issue.id]

    stored_run_after_second_reconcile = SymphonyElixir.Storage.get_run("run-park")

    assert Enum.count(
             stored_run_after_second_reconcile["events"],
             &(&1["message"] == "durable issue session parked")
           ) == 1
  end

  test "late codex updates do not reopen parked durable run rows" do
    issue = %Issue{
      id: "issue-late-park",
      identifier: "GH-LATE-PARK",
      title: "Late parked update",
      state: "Human Review",
      repo_id: "beacon",
      number: 44,
      pr_url: "https://github.com/devp1/Beacon/pull/44",
      pr_state: "OPEN",
      check_state: "none",
      review_state: ""
    }

    assert {:ok, "run-late-park"} =
             SymphonyElixir.Storage.start_run(%{
               id: "run-late-park",
               repo_id: issue.repo_id,
               issue_number: issue.number,
               issue_identifier: issue.identifier,
               state: "parked",
               session_state: "parked",
               health: ["parked"],
               error: nil
             })

    SymphonyElixir.RunLedger.persist_codex_update(
      %{
        run_id: "run-late-park",
        issue: issue,
        session_state: :parked,
        health: ["parked"],
        stop_reason: "human_review",
        workspace_path: "/tmp/symphony-late-park",
        session_id: "thread-late-turn-late",
        issue_session_id: "issue-session-late-park",
        thread_id: "thread-late",
        turn_count: 1,
        last_codex_message: %{event: :notification, message: %{"method" => "turn/completed"}}
      },
      %{event: "late codex notification"}
    )

    stored_run = SymphonyElixir.Storage.get_run("run-late-park")

    assert stored_run["state"] == "parked"
    assert stored_run["session_state"] == "parked"
    assert is_nil(stored_run["error"])
    assert stored_run["pr_url"] == "https://github.com/devp1/Beacon/pull/44"
  end

  test "rerun_issue moves an operator-paused issue back to in-progress and clears local pause state" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state = %Orchestrator.State{
        completed: MapSet.new(["beacon#13", "13"]),
        claimed: MapSet.new(["beacon#13", "13"]),
        retry_attempts: %{"beacon#13" => %{attempt: 1}, "13" => %{attempt: 1}},
        operator_paused_issue_ids: MapSet.new(["beacon#13", "13"]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:reply, {:ok, response}, next_state} =
               Orchestrator.handle_call({:rerun_issue, "beacon", 13}, self(), state)

      assert response.queued == true
      assert response.transition_result == :ok
      assert_receive {:memory_tracker_state_update, "beacon#13", "In Progress"}
      refute MapSet.member?(next_state.operator_paused_issue_ids, "beacon#13")
      refute MapSet.member?(next_state.operator_paused_issue_ids, "13")
      refute MapSet.member?(next_state.claimed, "beacon#13")
      refute MapSet.member?(next_state.completed, "13")
      refute Map.has_key?(next_state.retry_attempts, "beacon#13")
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
    end
  end

  test "merge_issue_pr blocks before GitHub merge when merge gate is not ready" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token"
    )

    :ok =
      SymphonyElixir.Storage.record_issue_snapshot(%{
        repo_id: "beacon",
        number: 31,
        identifier: "GH-31",
        title: "Blocked merge",
        state: "Human Review",
        labels: ["symphony", "human-review"],
        pr_url: "https://github.com/devp1/Beacon/pull/31",
        head_sha: "abc123",
        pr_state: "OPEN",
        check_state: "pending",
        review_state: "APPROVED"
      })

    assert {:ok, _review_id} =
             SymphonyElixir.Storage.record_autonomous_review(%{
               id: "blocked-review",
               repo_id: "beacon",
               issue_number: 31,
               issue_identifier: "GH-31",
               pr_url: "https://github.com/devp1/Beacon/pull/31",
               head_sha: "abc123",
               reviewer_kind: "review-agent",
               verdict: "pass",
               summary: "clean",
               check_name: "symphony/autonomous-review",
               check_conclusion: "success",
               stale: false
             })

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, _env ->
      send(parent, {:unexpected_gh_merge, args})
      {Jason.encode!(%{"merged" => true}), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    state = %Orchestrator.State{
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:reply, {:error, {:merge_gate_blocked, reasons}}, ^state} =
             Orchestrator.handle_call({:merge_issue_pr, "beacon", 31}, self(), state)

    assert "ci-not-green" in reasons
    refute_receive {:unexpected_gh_merge, _args}
  end

  test "merge_issue_pr merges ready PRs through the builder GitHub identity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token"
    )

    :ok =
      SymphonyElixir.Storage.record_issue_snapshot(%{
        repo_id: "beacon",
        number: 32,
        identifier: "GH-32",
        title: "Ready merge",
        state: "Human Review",
        labels: ["symphony", "human-review"],
        pr_url: "https://github.com/devp1/Beacon/pull/32",
        head_sha: "def456",
        pr_state: "OPEN",
        check_state: "passing",
        review_state: "APPROVED"
      })

    assert {:ok, _review_id} =
             SymphonyElixir.Storage.record_autonomous_review(%{
               id: "ready-review",
               repo_id: "beacon",
               issue_number: 32,
               issue_identifier: "GH-32",
               pr_url: "https://github.com/devp1/Beacon/pull/32",
               head_sha: "def456",
               reviewer_kind: "review-agent",
               verdict: "pass",
               summary: "clean",
               check_name: "symphony/autonomous-review",
               check_conclusion: "success",
               stale: false
             })

    assert {:ok, issue_session_id} =
             SymphonyElixir.Storage.start_issue_session(%{
               id: "issue-session-merge-success",
               repo_id: "beacon",
               issue_number: 32,
               issue_identifier: "GH-32",
               current_run_id: "run-merge-success",
               state: "parked"
             })

    assert {:ok, run_id} =
             SymphonyElixir.Storage.start_run(%{
               id: "run-merge-success",
               repo_id: "beacon",
               issue_number: 32,
               issue_identifier: "GH-32",
               issue_session_id: issue_session_id,
               state: "parked",
               session_state: "parked",
               pr_url: "https://github.com/devp1/Beacon/pull/32",
               pr_state: "OPEN",
               check_state: "passing",
               review_state: "APPROVED"
             })

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
      send(parent, {:gh_merge_args, args, env})
      {Jason.encode!(%{"merged" => true}), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    state = %Orchestrator.State{
      claimed: MapSet.new(["beacon#32", "32"]),
      retry_attempts: %{"beacon#32" => %{attempt: 1}, "32" => %{attempt: 1}},
      operator_paused_issue_ids: MapSet.new(["beacon#32", "32"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:reply, {:ok, payload}, next_state} =
             Orchestrator.handle_call({:merge_issue_pr, "beacon", 32}, self(), state)

    assert payload.issue_identifier == "GH-32"
    assert payload.merge_response == %{"merged" => true}
    assert payload.post_merge_update.tracker == ":ok"
    assert payload.post_merge_update.issue_snapshot == ":ok"
    assert payload.post_merge_update.run == ":ok"
    assert payload.post_merge_update.issue_session == ":ok"

    assert_received {:gh_merge_args, args, [{"GH_TOKEN", "builder-token"}, {"GITHUB_TOKEN", "builder-token"}]}
    assert ["api", "repos/devp1/Beacon/pulls/32/merge" | _] = args
    assert "sha=def456" in args

    assert_received {:gh_merge_args, ["api", "repos/devp1/Beacon/issues/32", "-X", "PATCH", "-f", "state=closed"],
                     [
                       {"GH_TOKEN", "builder-token"},
                       {"GITHUB_TOKEN", "builder-token"}
                     ]}

    assert MapSet.member?(next_state.completed, "beacon#32")
    assert MapSet.member?(next_state.completed, "32")
    refute MapSet.member?(next_state.claimed, "beacon#32")
    refute Map.has_key?(next_state.retry_attempts, "beacon#32")
    refute MapSet.member?(next_state.operator_paused_issue_ids, "32")

    assert %{
             "state" => "completed",
             "session_state" => "stopped",
             "health" => ["merged"],
             "pr_url" => "https://github.com/devp1/Beacon/pull/32",
             "pr_state" => "MERGED",
             "check_state" => "passing",
             "review_state" => "APPROVED",
             "events" => [
               %{
                 "message" => "cockpit merge requested",
                 "data" => %{
                   "merge_response" => %{"merged" => true},
                   "post_merge_update" => %{
                     "tracker" => ":ok",
                     "issue_snapshot" => ":ok",
                     "run" => ":ok",
                     "issue_session" => ":ok"
                   }
                 }
               }
             ]
           } = SymphonyElixir.Storage.get_run(run_id)

    assert %{"state" => "stopped", "health" => ["merged"], "stop_reason" => "merged"} =
             Enum.find(SymphonyElixir.Storage.list_issue_sessions(), &(&1["id"] == issue_session_id))

    assert %{
             "identifier" => "GH-32",
             "state" => "Done",
             "pr_state" => "MERGED",
             "check_state" => "passing",
             "review_state" => "APPROVED"
           } = Enum.find(SymphonyElixir.Storage.list_issues(), &(&1["identifier"] == "GH-32"))
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)
    scheduling_tolerance_ms = 500

    assert remaining_ms >= min_remaining_ms - scheduling_tolerance_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp sleeping_agent_pid do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp watchdog_state(issue_id, agent_pid, overrides) do
    issue_identifier = Keyword.get(overrides, :identifier, "MT-WATCH")
    now = DateTime.utc_now()

    running_entry =
      %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "In Progress",
          title: "Artifact watchdog"
        },
        started_at: now,
        worker_host: Keyword.get(overrides, :worker_host),
        workspace_path: Keyword.get(overrides, :workspace_path),
        session_id: Keyword.get(overrides, :session_id, "thread-watch-turn-watch"),
        run_id: Keyword.get(overrides, :run_id),
        issue_session_id: Keyword.get(overrides, :issue_session_id),
        session_kind: Keyword.get(overrides, :session_kind, :legacy),
        session_state: Keyword.get(overrides, :session_state, :running),
        health: Keyword.get(overrides, :health, ["healthy"]),
        last_codex_event: Keyword.get(overrides, :last_codex_event, :notification),
        codex_total_tokens: Keyword.get(overrides, :codex_total_tokens, 0),
        artifact_baseline_total_tokens: Keyword.get(overrides, :artifact_baseline_total_tokens, 0),
        last_artifact_timestamp: Keyword.get(overrides, :last_artifact_timestamp, now),
        last_artifact_reason: Keyword.get(overrides, :last_artifact_reason, "run started"),
        repo_artifact_baseline_total_tokens: Keyword.get(overrides, :repo_artifact_baseline_total_tokens, 0),
        last_repo_artifact_timestamp: Keyword.get(overrides, :last_repo_artifact_timestamp, now),
        last_repo_artifact_reason: Keyword.get(overrides, :last_repo_artifact_reason, "run started"),
        handoff_progress_baseline_total_tokens: Keyword.get(overrides, :handoff_progress_baseline_total_tokens, 0),
        last_handoff_progress_timestamp: Keyword.get(overrides, :last_handoff_progress_timestamp),
        last_handoff_progress_reason: Keyword.get(overrides, :last_handoff_progress_reason),
        last_handoff_progress_fingerprint: Keyword.get(overrides, :last_handoff_progress_fingerprint),
        artifact_nudge_count: Keyword.get(overrides, :artifact_nudge_count, 0),
        last_workspace_artifact_fingerprint: Keyword.get(overrides, :last_workspace_artifact_fingerprint),
        last_codex_diff_artifact_fingerprint: Keyword.get(overrides, :last_codex_diff_artifact_fingerprint),
        codex_activity_trace: Keyword.get(overrides, :codex_activity_trace, [])
      }

    %Orchestrator.State{
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      artifact_nudge_counts: Keyword.get(overrides, :artifact_nudge_counts, %{})
    }
  end

  test "artifact watchdog pauses runs that spend too many tokens without artifact evidence" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-pause"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-PAUSE",
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      assert updated_state.retry_attempts == %{}
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Symphony paused: no inspectable artifact"
      assert comment =~ "Tokens without artifact: `101`"
      assert comment =~ "MT-WATCH-PAUSE"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
      Process.sleep(10)
      refute Process.alive?(agent_pid)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog nudges by restarting the same workspace before pausing" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-nudge"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 500,
        max_tokens_without_artifact: 500
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-NUDGE",
          workspace_path: "/tmp/symphony-nudge-workspace",
          codex_total_tokens: 101,
          repo_artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      assert %{^issue_id => retry} = updated_state.retry_attempts
      assert retry.delay_type == :artifact_nudge
      assert retry.artifact_nudge_count == 1
      assert retry.artifact_nudge["tokens_without_repo_artifact"] == 101
      assert retry.artifact_nudge["workspace"] == "/tmp/symphony-nudge-workspace"
      assert updated_state.artifact_nudge_counts[issue_id] == 1
      assert_due_in_range(retry.due_at_ms, 0, 1_100)
      refute_receive {:memory_tracker_comment, ^issue_id, _comment}, 50
      refute_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}, 50
      Process.cancel_timer(retry.timer_ref)
      Process.sleep(10)
      refute Process.alive?(agent_pid)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog nudge carries a continuation capsule for autonomous retries" do
    issue_id = "issue-watchdog-nudge-capsule"
    agent_pid = sleeping_agent_pid()

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-nudge-capsule-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "MT-WATCH-CAPSULE")
      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 500,
        max_tokens_without_artifact: 500
      )

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-CAPSULE",
          workspace_path: workspace,
          codex_total_tokens: 101,
          repo_artifact_baseline_total_tokens: 0,
          codex_activity_trace: [
            %{
              "event" => "notification",
              "method" => "item/commandExecution/requestApproval",
              "summary" => "command approval requested: gh issue view 10 --repo devp1/Beacon"
            }
          ]
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      assert %{^issue_id => retry} = updated_state.retry_attempts
      assert retry.artifact_nudge_count == 1
      assert retry.artifact_nudge["capsule_path"] == Path.join([workspace, ".symphony", "continuation.json"])
      assert retry.artifact_nudge["continuation"]["workspace"]["path"] == workspace
      assert retry.artifact_nudge["continuation"]["workspace"]["branch"] == "main"
      assert retry.artifact_nudge["continuation"]["workspace"]["status"] == "clean"

      assert [%{"summary" => "command approval requested: gh issue view 10 --repo devp1/Beacon"}] =
               retry.artifact_nudge["continuation"]["recent_activity"]

      capsule = retry.artifact_nudge["capsule_path"] |> File.read!() |> Jason.decode!()
      assert capsule["continuation"] == retry.artifact_nudge["continuation"]
      assert capsule["tokens_without_repo_artifact"] == 101

      Process.cancel_timer(retry.timer_ref)
      Process.sleep(10)
      refute Process.alive?(agent_pid)
    after
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog restores nudge count from continuation capsule after restart" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-nudge-restore-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-watchdog-nudge-restore"
    agent_pid = sleeping_agent_pid()

    try do
      workspace = Path.join(test_root, "MT-WATCH-NUDGE-RESTORE")
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "proof.txt"), "artifact evidence\n")
      File.write!(Path.join([workspace, ".symphony", "continuation.json"]), ~s({"nudge_count":1}\n))

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-NUDGE-RESTORE",
          workspace_path: nil,
          artifact_nudge_count: 0
        )

      assert {:noreply, updated_state} =
               Orchestrator.handle_info(
                 {:worker_runtime_info, issue_id, %{worker_host: nil, workspace_path: workspace}},
                 state
               )

      running_entry = updated_state.running[issue_id]
      assert running_entry.artifact_nudge_count == 1
      assert updated_state.artifact_nudge_counts[issue_id] == 1
      assert match?({:git_status, value} when is_integer(value), running_entry.last_workspace_artifact_fingerprint)
    after
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog carries nudge budget across restarted runs before pausing" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-nudge-budget"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 750,
        max_tokens_without_artifact: 750
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-NUDGE-BUDGET",
          workspace_path: "/tmp/symphony-nudge-budget-workspace",
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0,
          artifact_nudge_count: 0,
          artifact_nudge_counts: %{issue_id => 1}
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Symphony paused: no inspectable artifact"
      assert comment =~ "Watchdog: `artifact-nudge`"
      assert comment =~ "Artifact nudges sent: `1`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
      Process.sleep(10)
      refute Process.alive?(agent_pid)
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog preserves repo artifact fingerprints on nudge retries" do
    issue_id = "issue-watchdog-nudge-fingerprints"
    agent_pid = sleeping_agent_pid()
    workspace_fingerprint = {:git_status, 123_456}
    diff_fingerprint = {:codex_diff, 654_321}

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 250_000,
        max_tokens_without_artifact: 250_000
      )

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-NUDGE-FINGERPRINTS",
          workspace_path: "/tmp/symphony-nudge-fingerprint-workspace",
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0,
          last_workspace_artifact_fingerprint: workspace_fingerprint,
          last_codex_diff_artifact_fingerprint: diff_fingerprint
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)
      retry = updated_state.retry_attempts[issue_id]

      assert retry.artifact_nudge_count == 1
      assert retry.artifact_nudge["handoff_candidate"] == true
      assert retry.last_workspace_artifact_fingerprint == workspace_fingerprint
      assert retry.last_codex_diff_artifact_fingerprint == diff_fingerprint
      assert updated_state.artifact_nudge_counts[issue_id] == 1
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog does not clear nudge budget for inherited dirty workspace evidence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-watchdog-inherited-dirty-#{System.unique_integer([:positive])}"
      )

    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-inherited-dirty"
    agent_pid = sleeping_agent_pid()

    try do
      workspace = Path.join(test_root, "MT-WATCH-INHERITED-DIRTY")
      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "proof.txt"), "artifact evidence\n")
      assert {status_output, 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true)
      workspace_fingerprint = {:git_status, :erlang.phash2(String.trim(status_output))}
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(Path.join([workspace, ".symphony", "continuation.json"]), ~s({"source":"watchdog"}\n))

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 750,
        max_tokens_without_artifact: 750
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-INHERITED-DIRTY",
          workspace_path: workspace,
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0,
          artifact_nudge_count: 1,
          artifact_nudge_counts: %{issue_id => 1},
          last_workspace_artifact_fingerprint: workspace_fingerprint
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Tokens without artifact: `101`"
      assert comment =~ "Watchdog: `artifact-nudge`"
      assert comment =~ "Artifact nudges sent: `1`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog lets inherited dirty work continue after validation progress" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-handoff-validation"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 750,
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-HANDOFF-VALIDATION",
          workspace_path: "/tmp/symphony-handoff-validation-workspace",
          codex_total_tokens: 0,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0,
          artifact_nudge_count: 1,
          artifact_nudge_counts: %{issue_id => 1},
          last_workspace_artifact_fingerprint: {:git_status, 123_456}
        )

      update = %{
        event: :approval_auto_approved,
        timestamp: DateTime.utc_now(),
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{
            "command" => "/bin/zsh -lc 'npm run build'",
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 120, "output_tokens" => 30, "total_tokens" => 150}
            }
          }
        }
      }

      assert {:noreply, updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

      running_entry = updated_state.running[issue_id]
      assert running_entry.codex_total_tokens == 150
      assert running_entry.handoff_progress_baseline_total_tokens == 150
      assert running_entry.last_handoff_progress_reason == "validation command: npm run build"

      reconciled_state = Orchestrator.reconcile_artifact_watchdog_for_test(updated_state)

      assert Map.has_key?(reconciled_state.running, issue_id)
      assert MapSet.member?(reconciled_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      refute_receive {:memory_tracker_comment, ^issue_id, _comment}, 50
      refute_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}, 50
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog counts trusted command execution lifecycle events as handoff progress" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-handoff-command-lifecycle"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 750,
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-HANDOFF-LIFECYCLE",
          workspace_path: "/tmp/symphony-handoff-lifecycle-workspace",
          codex_total_tokens: 0,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0,
          artifact_nudge_count: 1,
          artifact_nudge_counts: %{issue_id => 1},
          last_workspace_artifact_fingerprint: {:git_status, 123_456}
        )

      update = %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{
          "method" => "item/started",
          "params" => %{
            "item" => %{
              "type" => "commandExecution",
              "status" => "running",
              "command" => "git diff --stat && git diff --name-status"
            },
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 130, "output_tokens" => 20, "total_tokens" => 150}
            }
          }
        }
      }

      assert {:noreply, updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

      running_entry = updated_state.running[issue_id]
      assert running_entry.codex_total_tokens == 150
      assert running_entry.handoff_progress_baseline_total_tokens == 150
      assert running_entry.last_handoff_progress_reason == "handoff command: git diff --stat && git diff --name-status"

      reconciled_state = Orchestrator.reconcile_artifact_watchdog_for_test(updated_state)

      assert Map.has_key?(reconciled_state.running, issue_id)
      assert Process.alive?(agent_pid)
      refute_receive {:memory_tracker_comment, ^issue_id, _comment}, 50
      refute_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}, 50
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog does not let one repeated validation command reset handoff progress forever" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-handoff-repeated-validation"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 100,
        max_artifact_nudges: 1,
        max_tokens_before_first_artifact: 750,
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      timestamp = DateTime.utc_now()

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-HANDOFF-REPEATED",
          workspace_path: "/tmp/symphony-handoff-repeated-workspace",
          codex_total_tokens: 150,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0,
          handoff_progress_baseline_total_tokens: 150,
          last_handoff_progress_timestamp: timestamp,
          last_handoff_progress_reason: "validation command: npm run build",
          last_handoff_progress_fingerprint: {:handoff_command, :erlang.phash2("npm run build")},
          artifact_nudge_count: 1,
          artifact_nudge_counts: %{issue_id => 1},
          last_workspace_artifact_fingerprint: {:git_status, 123_456}
        )

      repeated_update = %{
        event: :approval_auto_approved,
        timestamp: DateTime.add(timestamp, 1, :second),
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{
            "command" => "/bin/zsh -lc 'npm run build'",
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 260, "output_tokens" => 40, "total_tokens" => 300}
            }
          }
        }
      }

      assert {:noreply, updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, repeated_update}, state)

      assert updated_state.running[issue_id].handoff_progress_baseline_total_tokens == 150

      paused_state = Orchestrator.reconcile_artifact_watchdog_for_test(updated_state)

      refute Map.has_key?(paused_state.running, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Watchdog: `artifact-nudge`"
      assert comment =~ "Last handoff progress: `validation command: npm run build"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog ignores Symphony control files as repo proof" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-watchdog-control-files-#{System.unique_integer([:positive])}"
      )

    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-control-files"
    agent_pid = sleeping_agent_pid()

    try do
      workspace = Path.join(test_root, "MT-WATCH-CONTROL-FILES")
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join([workspace, ".symphony", "continuation.json"]), ~s({"source":"watchdog"}\n))

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 0,
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-WATCH-CONTROL-FILES",
          workspace_path: workspace,
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0,
          repo_artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      refute Map.has_key?(updated_state.running, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Tokens without artifact: `101`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog keeps runs below the token threshold" do
    issue_id = "issue-watchdog-below"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_without_artifact: 100
      )

      state =
        watchdog_state(issue_id, agent_pid,
          codex_total_tokens: 100,
          artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      assert Map.has_key?(updated_state.running, issue_id)
      assert MapSet.member?(updated_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "first-artifact watchdog pauses before the standard artifact budget" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-first-artifact-pause"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_before_first_artifact: 100,
        max_tokens_without_artifact: 250
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "MT-FIRST-ARTIFACT",
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0,
          last_artifact_reason: "run started"
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      refute Map.has_key?(updated_state.running, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Watchdog: `first-artifact`"
      assert comment =~ "first-artifact budget"
      assert comment =~ "Threshold: `100`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "first-artifact watchdog disabled falls back to the standard artifact budget" do
    issue_id = "issue-first-artifact-disabled"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_before_first_artifact: 0,
        max_tokens_without_artifact: 250
      )

      state =
        watchdog_state(issue_id, agent_pid,
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0,
          last_artifact_reason: "run started"
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      assert Map.has_key?(updated_state.running, issue_id)
      assert Process.alive?(agent_pid)
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "standard artifact budget applies after the first artifact" do
    issue_id = "issue-standard-artifact-after-first"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_before_first_artifact: 100,
        max_tokens_without_artifact: 250
      )

      state =
        watchdog_state(issue_id, agent_pid,
          codex_total_tokens: 350,
          artifact_baseline_total_tokens: 200,
          last_artifact_reason: "codex diff updated"
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      assert Map.has_key?(updated_state.running, issue_id)
      assert Process.alive?(agent_pid)
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog baseline resets on non-empty codex diff events" do
    issue_id = "issue-watchdog-diff"
    agent_pid = sleeping_agent_pid()
    now = DateTime.utc_now()

    try do
      state =
        watchdog_state(issue_id, agent_pid,
          codex_total_tokens: 0,
          artifact_baseline_total_tokens: 0,
          health: ["stale-proof", "high-token-no-proof"]
        )

      update = %{
        event: :notification,
        timestamp: now,
        payload: %{
          "method" => "turn/diff/updated",
          "params" => %{
            "diff" => "diff --git a/file b/file\n",
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 150, "output_tokens" => 50, "total_tokens" => 200}
            }
          }
        }
      }

      assert {:noreply, updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, update}, state)

      running_entry = updated_state.running[issue_id]
      assert running_entry.codex_total_tokens == 200
      assert running_entry.artifact_baseline_total_tokens == 200
      assert running_entry.last_artifact_timestamp == now
      assert running_entry.last_artifact_reason == "codex diff updated"
      assert running_entry.repo_artifact_baseline_total_tokens == 200
      assert running_entry.last_repo_artifact_timestamp == now
      assert running_entry.last_repo_artifact_reason == "codex diff updated"
      assert running_entry.health == ["healthy"]
      assert match?({:codex_diff, value} when is_integer(value), running_entry.last_codex_diff_artifact_fingerprint)
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog does not repeatedly reset for the same Codex diff" do
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-same-diff"
    agent_pid = sleeping_agent_pid()
    now = DateTime.utc_now()
    diff = "diff --git a/file b/file\n+first artifact\n"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 0,
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state =
        watchdog_state(issue_id, agent_pid,
          codex_total_tokens: 0,
          artifact_baseline_total_tokens: 0
        )

      first_update = %{
        event: :notification,
        timestamp: now,
        payload: %{
          "method" => "turn/diff/updated",
          "params" => %{
            "diff" => diff,
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 150, "output_tokens" => 50, "total_tokens" => 200}
            }
          }
        }
      }

      assert {:noreply, first_updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, first_update}, state)

      first_running_entry = first_updated_state.running[issue_id]
      assert first_running_entry.artifact_baseline_total_tokens == 200
      assert first_running_entry.repo_artifact_baseline_total_tokens == 200

      second_update = %{
        event: :notification,
        timestamp: DateTime.add(now, 1, :second),
        payload: %{
          "method" => "turn/diff/updated",
          "params" => %{
            "diff" => diff,
            "tokenUsage" => %{
              "total" => %{"input_tokens" => 300, "output_tokens" => 50, "total_tokens" => 350}
            }
          }
        }
      }

      assert {:noreply, second_updated_state} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, second_update}, first_updated_state)

      second_running_entry = second_updated_state.running[issue_id]
      assert second_running_entry.codex_total_tokens == 350
      assert second_running_entry.artifact_baseline_total_tokens == 200
      assert second_running_entry.repo_artifact_baseline_total_tokens == 200

      paused_state = Orchestrator.reconcile_artifact_watchdog_for_test(second_updated_state)
      refute Map.has_key?(paused_state.running, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Tokens without artifact: `150`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog baseline resets on local workspace git changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-watchdog-dirty-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-watchdog-dirty"
    agent_pid = sleeping_agent_pid()

    try do
      workspace = Path.join(test_root, "MT-WATCH-DIRTY")
      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "proof.txt"), "artifact evidence\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_without_artifact: 100
      )

      state =
        watchdog_state(issue_id, agent_pid,
          workspace_path: workspace,
          codex_total_tokens: 200,
          artifact_baseline_total_tokens: 0,
          health: ["stale-proof", "handoff-lagging"]
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)
      running_entry = updated_state.running[issue_id]

      assert Map.has_key?(updated_state.running, issue_id)
      assert running_entry.artifact_baseline_total_tokens == 200
      assert running_entry.last_artifact_reason == "workspace git status changed"
      assert running_entry.repo_artifact_baseline_total_tokens == 200
      assert running_entry.last_repo_artifact_reason == "workspace git status changed"
      assert running_entry.health == ["handoff-lagging"]
      assert match?({:git_status, value} when is_integer(value), running_entry.last_workspace_artifact_fingerprint)
      assert Process.alive?(agent_pid)
    after
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "durable artifact health warnings are idempotent while no new proof appears" do
    issue_id = "issue-watchdog-durable-health"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_without_artifact: 100
      )

      state =
        watchdog_state(issue_id, agent_pid,
          session_kind: :durable,
          codex_total_tokens: 101,
          artifact_baseline_total_tokens: 0
        )

      first_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)
      assert first_state.running[issue_id].health == ["high-token-no-proof"]

      second_state = Orchestrator.reconcile_artifact_watchdog_for_test(first_state)
      assert second_state.running[issue_id].health == ["high-token-no-proof"]
      assert Process.alive?(agent_pid)
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog does not repeatedly reset for the same dirty workspace state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-watchdog-same-dirty-#{System.unique_integer([:positive])}"
      )

    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-watchdog-same-dirty"
    agent_pid = sleeping_agent_pid()

    try do
      workspace = Path.join(test_root, "MT-WATCH-SAME-DIRTY")
      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.write!(Path.join(workspace, "proof.txt"), "artifact evidence\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      first_state =
        watchdog_state(issue_id, agent_pid,
          workspace_path: workspace,
          codex_total_tokens: 200,
          artifact_baseline_total_tokens: 0
        )

      first_updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(first_state)
      first_running_entry = first_updated_state.running[issue_id]

      assert first_running_entry.artifact_baseline_total_tokens == 200

      assert match?(
               {:git_status, value} when is_integer(value),
               first_running_entry.last_workspace_artifact_fingerprint
             )

      second_running_entry = %{first_running_entry | codex_total_tokens: 350}
      second_state = %{first_updated_state | running: %{issue_id => second_running_entry}}

      second_updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(second_state)

      refute Map.has_key?(second_updated_state.running, issue_id)
      assert_receive {:memory_tracker_comment, ^issue_id, comment}
      assert comment =~ "Tokens without artifact: `150`"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Needs Input"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog baseline resets on local Symphony workpad changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-artifact-watchdog-workpad-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-watchdog-workpad"
    agent_pid = sleeping_agent_pid()

    try do
      workspace = Path.join(test_root, "MT-WATCH-WORKPAD")
      File.mkdir_p!(workspace)
      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
      File.mkdir_p!(Path.join(workspace, ".git/info"))
      File.write!(Path.join(workspace, ".git/info/exclude"), ".symphony/\n")
      File.mkdir_p!(Path.join(workspace, ".symphony"))
      File.write!(Path.join(workspace, ".symphony/workpad.md"), "# Symphony Workpad\n\n- proof\n")
      assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        max_tokens_without_artifact: 100
      )

      state =
        watchdog_state(issue_id, agent_pid,
          workspace_path: workspace,
          codex_total_tokens: 200,
          artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)
      running_entry = updated_state.running[issue_id]

      assert Map.has_key?(updated_state.running, issue_id)
      assert running_entry.artifact_baseline_total_tokens == 200
      assert running_entry.last_artifact_reason == "symphony workpad updated"
      assert running_entry.repo_artifact_baseline_total_tokens == 0
      assert running_entry.last_repo_artifact_reason == "run started"
      assert match?({:workpad, value} when is_integer(value), running_entry.last_workspace_artifact_fingerprint)
      assert Process.alive?(agent_pid)
    after
      File.rm_rf(test_root)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog baseline resets on durable GitHub Codex workpad updates" do
    previous_command_fun = Application.get_env(:symphony_elixir, :github_command_fun)
    issue_id = "10"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_owner: "devp1",
        tracker_repo: "Beacon",
        max_tokens_without_artifact: 100
      )

      Application.put_env(:symphony_elixir, :github_command_fun, fn
        ["api", "repos/devp1/Beacon/issues/10/comments", "-X", "GET", "-F", "per_page=100"] ->
          {
            Jason.encode!([
              %{
                "body" => "## Codex Workpad\n\n- [x] plan updated",
                "created_at" => "2026-04-28T15:00:00Z",
                "updated_at" => "2026-04-28T15:01:00Z"
              }
            ]),
            0
          }
      end)

      state =
        watchdog_state(issue_id, agent_pid,
          identifier: "GH-10",
          codex_total_tokens: 200,
          artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)
      running_entry = updated_state.running[issue_id]

      assert Map.has_key?(updated_state.running, issue_id)
      assert running_entry.artifact_baseline_total_tokens == 200
      assert running_entry.last_artifact_reason == "github codex workpad updated"
      assert running_entry.repo_artifact_baseline_total_tokens == 0
      assert running_entry.last_repo_artifact_reason == "run started"
      assert match?({:github_workpad, value} when is_integer(value), running_entry.last_tracker_artifact_fingerprint)
      assert Process.alive?(agent_pid)
    after
      restore_app_env(:github_command_fun, previous_command_fun)

      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "artifact watchdog can be disabled" do
    issue_id = "issue-watchdog-disabled"
    agent_pid = sleeping_agent_pid()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        artifact_nudge_tokens: 0,
        max_tokens_before_first_artifact: 0,
        max_tokens_without_artifact: 0
      )

      state =
        watchdog_state(issue_id, agent_pid,
          codex_total_tokens: 1_000_000,
          artifact_baseline_total_tokens: 0
        )

      updated_state = Orchestrator.reconcile_artifact_watchdog_for_test(state)

      assert Map.has_key?(updated_state.running, issue_id)
      assert Process.alive?(agent_pid)
    after
      if Process.alive?(agent_pid) do
        Process.exit(agent_pid, :kill)
      end
    end
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} labels_text={{ issue.labels_text }} repo={{ issue.repo_full_name }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      repo_owner: "devp1",
      repo_name: "Beacon",
      url: "https://example.org/issues/S-1",
      labels: ["backend", "runner"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backendrunner"
    assert prompt =~ "labels_text=backend, runner"
    assert prompt =~ "repo=devp1/Beacon"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      number: 616,
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      repo_owner: "devp1",
      repo_name: "Beacon",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a GitHub issue `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Issue number: 616"
    assert prompt =~ "Repository: devp1/Beacon"
    assert prompt =~ "Labels: templating, workflow"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "## Kickoff contract"
    assert prompt =~ "Produce a useful repository artifact early"
    assert prompt =~ ".symphony/workpad.md"
    assert prompt =~ "use the authenticated `gh` CLI"
    assert prompt =~ "Prefer targeted comment/PR lookup before the first repo artifact"
    assert prompt =~ "This is an unattended GitHub issue-to-PR run."
    assert prompt =~ "Never ask a human to perform follow-up actions unless"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "in-repo WORKFLOW.md renders partial GitHub issue context without undefined variables" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %{
      identifier: "GH-11",
      title: "Static skip helper",
      description: nil,
      state: "In Progress",
      url: "https://github.com/devp1/Beacon/issues/11",
      labels: ["symphony", "in-progress"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 1)

    assert prompt =~ "You are working on a GitHub issue `GH-11`"
    assert prompt =~ "Issue number:"
    assert prompt =~ "Repository:"
    assert prompt =~ "Labels: symphony, in-progress"
    assert prompt =~ "No description provided."
    refute prompt =~ "symphonyin-progress"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))

      workpad = Path.join(workspace, ".symphony/workpad.md")
      assert File.exists?(workpad)
      assert File.read!(workpad) =~ "Generated by Symphony before Codex starts"
      assert File.read!(workpad) =~ "- Identifier: S-99"
      assert File.read!(workpad) =~ "- Title: Smoke test"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

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
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner pauses and comments when codex requires approval" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-human-needed-#{System.unique_integer([:positive])}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-human"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-human"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"touch outside","reason":"needs approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-human-needed",
        identifier: "MT-HUMAN",
        title: "Needs approval",
        description: "Codex needs an operator decision",
        state: "In Progress",
        url: "https://example.org/issues/MT-HUMAN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue)

      assert_receive {:memory_tracker_comment, "issue-human-needed", comment}
      assert comment =~ "Symphony needs human input"
      assert comment =~ "approval_required"
      assert comment =~ "MT-HUMAN"

      assert_receive {:memory_tracker_state_update, "issue-human-needed", "Needs Input"}
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
