defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.AppAuth
  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  test "normalizes GitHub issue labels into Symphony states" do
    issue = %{
      "number" => 12,
      "title" => "Runner task",
      "body" => "Do the thing",
      "state" => "open",
      "html_url" => "https://github.com/devp1/Beacon/issues/12",
      "labels" => [%{"name" => "symphony"}, %{"name" => "agent-ready"}],
      "assignee" => %{"login" => "devp1"},
      "created_at" => "2026-04-27T12:00:00Z",
      "updated_at" => "2026-04-27T12:30:00Z"
    }

    normalized = GitHubClient.normalize_issue_for_test(issue)

    assert normalized.id == "12"
    assert normalized.identifier == "GH-12"
    assert normalized.title == "Runner task"
    assert normalized.description == "Do the thing"
    assert normalized.state == "Todo"
    assert normalized.url == "https://github.com/devp1/Beacon/issues/12"
    assert normalized.assignee_id == "devp1"
    assert normalized.labels == ["symphony", "agent-ready"]
  end

  test "normalizes linked pull request metadata from issue closing references" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      [
        "issue",
        "view",
        "13",
        "--repo",
        "devp1/Beacon",
        "--json",
        "closedByPullRequestsReferences"
      ] ->
        {
          Jason.encode!(%{
            "closedByPullRequestsReferences" => [
              %{"number" => 14, "url" => "https://github.com/devp1/Beacon/pull/14"}
            ]
          }),
          0
        }

      ["pr", "view", "14", "--repo", "devp1/Beacon", "--json", "url,number,state,headRefOid,statusCheckRollup,reviewDecision"] ->
        {
          Jason.encode!(%{
            "url" => "https://github.com/devp1/Beacon/pull/14",
            "number" => 14,
            "state" => "OPEN",
            "headRefOid" => "85e7b8f",
            "reviewDecision" => "APPROVED",
            "statusCheckRollup" => [
              %{"name" => "test", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
            ]
          }),
          0
        }
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    issue = %{
      "number" => 13,
      "title" => "Auth fixture proof",
      "state" => "open",
      "labels" => [%{"name" => "symphony"}, %{"name" => "human-review"}]
    }

    normalized = GitHubClient.normalize_issue_for_test(issue)

    assert normalized.pr_url == "https://github.com/devp1/Beacon/pull/14"
    assert normalized.pr_number == 14
    assert normalized.pr_state == "OPEN"
    assert normalized.head_sha == "85e7b8f"
    assert normalized.check_state == "passing"
    assert normalized.review_state == "APPROVED"
  end

  test "linked pull request metadata falls back to issue timeline when issue view lacks references" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      [
        "issue",
        "view",
        "13",
        "--repo",
        "devp1/Beacon",
        "--json",
        "closedByPullRequestsReferences"
      ] ->
        {Jason.encode!(%{"closedByPullRequestsReferences" => []}), 0}

      [
        "api",
        "repos/devp1/Beacon/issues/13/timeline",
        "-H",
        "Accept: application/vnd.github+json",
        "-F",
        "per_page=100"
      ] ->
        {
          Jason.encode!([
            %{"event" => "cross-referenced", "source" => %{"issue" => %{"number" => 14, "pull_request" => %{}}}}
          ]),
          0
        }

      ["pr", "view", "14", "--repo", "devp1/Beacon", "--json", "url,number,state,headRefOid,statusCheckRollup,reviewDecision"] ->
        {
          Jason.encode!(%{
            "url" => "https://github.com/devp1/Beacon/pull/14",
            "number" => 14,
            "state" => "OPEN",
            "headRefOid" => "85e7b8f",
            "statusCheckRollup" => []
          }),
          0
        }
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    normalized =
      GitHubClient.normalize_issue_for_test(%{
        "number" => 13,
        "title" => "Auth fixture proof",
        "state" => "open",
        "labels" => [%{"name" => "symphony"}, %{"name" => "human-review"}]
      })

    assert normalized.pr_url == "https://github.com/devp1/Beacon/pull/14"
    assert normalized.check_state == "none"
  end

  test "linked pull request metadata reports pending and failing checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      [
        "issue",
        "view",
        "15",
        "--repo",
        "devp1/Beacon",
        "--json",
        "closedByPullRequestsReferences"
      ] ->
        {Jason.encode!(%{"closedByPullRequestsReferences" => [%{"number" => 16}]}), 0}

      ["pr", "view", "16", "--repo", "devp1/Beacon", "--json", "url,number,state,headRefOid,statusCheckRollup,reviewDecision"] ->
        send(parent, :first_pr_view)

        {
          Jason.encode!(%{
            "url" => "https://github.com/devp1/Beacon/pull/16",
            "number" => 16,
            "state" => "OPEN",
            "headRefOid" => "pending",
            "statusCheckRollup" => [
              %{"name" => "build", "status" => "IN_PROGRESS", "conclusion" => nil}
            ]
          }),
          0
        }

      [
        "issue",
        "view",
        "17",
        "--repo",
        "devp1/Beacon",
        "--json",
        "closedByPullRequestsReferences"
      ] ->
        {Jason.encode!(%{"closedByPullRequestsReferences" => [%{"number" => 18}]}), 0}

      ["pr", "view", "18", "--repo", "devp1/Beacon", "--json", "url,number,state,headRefOid,statusCheckRollup,reviewDecision"] ->
        {
          Jason.encode!(%{
            "url" => "https://github.com/devp1/Beacon/pull/18",
            "number" => 18,
            "state" => "OPEN",
            "headRefOid" => "failed",
            "statusCheckRollup" => [
              %{"name" => "test", "status" => "COMPLETED", "conclusion" => "FAILURE"}
            ]
          }),
          0
        }
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    pending =
      GitHubClient.normalize_issue_for_test(%{
        "number" => 15,
        "title" => "Pending",
        "state" => "open",
        "labels" => [%{"name" => "symphony"}, %{"name" => "human-review"}]
      })

    failing =
      GitHubClient.normalize_issue_for_test(%{
        "number" => 17,
        "title" => "Failing",
        "state" => "open",
        "labels" => [%{"name" => "symphony"}, %{"name" => "human-review"}]
      })

    assert pending.check_state == "pending"
    assert failing.check_state == "failing"
  end

  test "linked pull request metadata requires configured CI checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_required_check_names: ["ci"]
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      [
        "issue",
        "view",
        issue_number,
        "--repo",
        "devp1/Beacon",
        "--json",
        "closedByPullRequestsReferences"
      ] ->
        {Jason.encode!(%{"closedByPullRequestsReferences" => [%{"number" => String.to_integer(issue_number) + 10}]}), 0}

      ["pr", "view", "31", "--repo", "devp1/Beacon", "--json", "url,number,state,headRefOid,statusCheckRollup,reviewDecision"] ->
        {
          Jason.encode!(%{
            "url" => "https://github.com/devp1/Beacon/pull/31",
            "number" => 31,
            "state" => "OPEN",
            "headRefOid" => "review-only",
            "statusCheckRollup" => [
              %{"name" => "symphony/autonomous-review", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
            ]
          }),
          0
        }

      ["pr", "view", "32", "--repo", "devp1/Beacon", "--json", "url,number,state,headRefOid,statusCheckRollup,reviewDecision"] ->
        {
          Jason.encode!(%{
            "url" => "https://github.com/devp1/Beacon/pull/32",
            "number" => 32,
            "state" => "OPEN",
            "headRefOid" => "ci-pass",
            "statusCheckRollup" => [
              %{"name" => "symphony/autonomous-review", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
              %{"name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
            ]
          }),
          0
        }
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    review_only =
      GitHubClient.normalize_issue_for_test(%{
        "number" => 21,
        "title" => "Review only",
        "state" => "open",
        "labels" => [%{"name" => "symphony"}, %{"name" => "human-review"}]
      })

    ci_pass =
      GitHubClient.normalize_issue_for_test(%{
        "number" => 22,
        "title" => "CI pass",
        "state" => "open",
        "labels" => [%{"name" => "symphony"}, %{"name" => "human-review"}]
      })

    assert review_only.check_state == "none"
    assert ci_pass.check_state == "passing"
  end

  test "closed GitHub issues normalize as Done" do
    issue = %{
      "number" => 13,
      "title" => "Closed task",
      "state" => "closed",
      "labels" => [%{"name" => "symphony"}, %{"name" => "in-progress"}]
    }

    assert GitHubClient.normalize_issue_for_test(issue).state == "Done"
  end

  test "needs-input and blocked labels normalize as non-runnable states" do
    needs_input = %{
      "number" => 14,
      "title" => "Needs a person",
      "state" => "open",
      "labels" => [%{"name" => "symphony"}, %{"name" => "needs-input"}]
    }

    blocked = %{
      "number" => 15,
      "title" => "Blocked",
      "state" => "open",
      "labels" => [%{"name" => "symphony"}, %{"name" => "blocked"}]
    }

    assert GitHubClient.normalize_issue_for_test(needs_input).state == "Needs Input"
    assert GitHubClient.normalize_issue_for_test(blocked).state == "Blocked"
  end

  test "fetches active GitHub issues through gh CLI" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      tracker_active_states: ["Todo"]
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      ["api", "repos/devp1/Beacon/issues", "-X", "GET", "-f", "state=open", "-f", "labels=symphony", "-F", "per_page=100"] ->
        {
          Jason.encode!([
            %{
              "number" => 1,
              "title" => "Ready",
              "state" => "open",
              "labels" => [%{"name" => "symphony"}, %{"name" => "agent-ready"}]
            },
            %{
              "number" => 2,
              "title" => "Backlog",
              "state" => "open",
              "labels" => [%{"name" => "symphony"}]
            },
            %{
              "number" => 3,
              "title" => "PR",
              "state" => "open",
              "pull_request" => %{},
              "labels" => [%{"name" => "symphony"}, %{"name" => "agent-ready"}]
            }
          ]),
          0
        }
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert {:ok, [issue]} = GitHubClient.fetch_candidate_issues()
    assert issue.id == "1"
    assert issue.state == "Todo"
  end

  test "fetches Codex workpad comments as artifact markers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      ["api", "repos/devp1/Beacon/issues/10/comments", "-X", "GET", "-F", "per_page=100"] ->
        {
          Jason.encode!([
            %{
              "body" => "ordinary note",
              "created_at" => "2026-04-28T15:00:00Z",
              "updated_at" => "2026-04-28T15:00:00Z"
            },
            %{
              "body" => "## Codex Workpad\n\n- [x] planned",
              "created_at" => "2026-04-28T15:01:00Z",
              "updated_at" => "2026-04-28T15:02:00Z"
            }
          ]),
          0
        }
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert {:ok, "github codex workpad updated", {:github_workpad, fingerprint}} =
             GitHubClient.fetch_artifact_marker("10")

    assert is_integer(fingerprint)
  end

  test "preflight verifies gh auth and required repository labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    labels =
      [
        "agent-ready",
        "in-progress",
        "human-review",
        "needs-input",
        "blocked",
        "rework",
        "merging",
        "symphony"
      ]
      |> Enum.map(&%{"name" => &1})

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      ["auth", "status", "-h", "github.com"] ->
        {"Logged in to github.com", 0}

      ["api", "repos/devp1/Beacon/labels", "-X", "GET", "-F", "per_page=100"] ->
        {Jason.encode!(labels), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert :ok = GitHubClient.preflight()
  end

  test "github command environment selects builder and reviewer tokens" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token"
    )

    assert [{"GH_TOKEN", "builder-token"}, {"GITHUB_TOKEN", "builder-token"}] =
             GitHubClient.command_env_for_test(:builder)

    assert [{"GH_TOKEN", "reviewer-token"}, {"GITHUB_TOKEN", "reviewer-token"}] =
             GitHubClient.command_env_for_test(:reviewer)
  end

  test "github command environment mints installation tokens for configured apps" do
    AppAuth.clear_cache_for_test()
    key_dir = Path.join(System.tmp_dir!(), "symphony-elixir-github-app-key-#{System.unique_integer([:positive])}")
    private_key_path = Path.join(key_dir, "app.pem")
    File.mkdir_p!(key_dir)
    File.write!(private_key_path, test_private_key_pem())
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_app: %{
        app_id: "100",
        installation_id: "200",
        private_key_path: private_key_path
      },
      github_reviewer_app: %{
        app_id: "101",
        installation_id: "201",
        private_key_path: private_key_path
      }
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
      send(parent, {:mint_args, args, env})

      case args do
        ["api", "app/installations/200/access_tokens" | _] ->
          {Jason.encode!(%{"token" => "builder-installation-token", "expires_at" => "2099-01-01T00:00:00Z"}), 0}

        ["api", "app/installations/201/access_tokens" | _] ->
          {Jason.encode!(%{"token" => "reviewer-installation-token", "expires_at" => "2099-01-01T00:00:00Z"}), 0}
      end
    end)

    on_exit(fn ->
      AppAuth.clear_cache_for_test()
      Application.delete_env(:symphony_elixir, :github_command_fun)
      File.rm_rf(key_dir)
    end)

    assert Config.independent_github_reviewer?()

    assert [{"GH_TOKEN", "builder-installation-token"}, {"GITHUB_TOKEN", "builder-installation-token"}] =
             GitHubClient.command_env_for_test(:builder)

    assert [{"GH_TOKEN", "reviewer-installation-token"}, {"GITHUB_TOKEN", "reviewer-installation-token"}] =
             GitHubClient.command_env_for_test(:reviewer)

    assert_receive {:mint_args, ["api", "app/installations/200/access_tokens" | builder_args], []}
    assert_receive {:mint_args, ["api", "app/installations/201/access_tokens" | reviewer_args], []}
    builder_jwt = bearer_jwt_from_args(builder_args)
    reviewer_jwt = bearer_jwt_from_args(reviewer_args)
    assert builder_jwt =~ "."
    assert reviewer_jwt =~ "."
  end

  test "autonomous review check is written with reviewer identity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
      send(parent, {:gh_args, args, env})
      {Jason.encode!(%{"id" => 123}), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    issue = %Issue{
      id: "25",
      identifier: "GH-25",
      title: "Review me",
      repo_owner: "devp1",
      repo_name: "Beacon",
      head_sha: "abc123"
    }

    assert :ok =
             GitHubClient.upsert_autonomous_review_check(issue, %{
               verdict: "request_changes",
               summary: "Needs one fix",
               details: "A specific issue remains."
             })

    assert_received {:gh_args, args, [{"GH_TOKEN", "reviewer-token"}, {"GITHUB_TOKEN", "reviewer-token"}]}
    assert ["api", "repos/devp1/Beacon/check-runs" | _] = args
    assert "conclusion=failure" in args
    assert "name=symphony/autonomous-review" in args
  end

  test "pass review approval requires independent reviewer identity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "same-token",
      github_reviewer_token: "same-token"
    )

    issue = %Issue{
      id: "25",
      identifier: "GH-25",
      title: "Review me",
      repo_owner: "devp1",
      repo_name: "Beacon",
      pr_url: "https://github.com/devp1/Beacon/pull/25"
    }

    assert {:error, :reviewer_identity_not_independent} =
             GitHubClient.submit_autonomous_pr_review(issue, %{verdict: "pass", summary: "Clean"})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
      send(parent, {:gh_args, args, env})
      {Jason.encode!(%{"id" => 456}), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert :ok = GitHubClient.submit_autonomous_pr_review(issue, %{verdict: "pass", summary: "Clean"})

    assert_received {:gh_args, args, [{"GH_TOKEN", "reviewer-token"}, {"GITHUB_TOKEN", "reviewer-token"}]}
    assert ["api", "repos/devp1/Beacon/pulls/25/reviews" | _] = args
    assert "event=APPROVE" in args
  end

  test "merge_pull_request uses builder identity and pins the reviewed head sha" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon",
      github_builder_token: "builder-token",
      github_reviewer_token: "reviewer-token"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args, env ->
      send(parent, {:gh_args, args, env})
      {Jason.encode!(%{"merged" => true, "sha" => "merge-sha"}), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    issue = %Issue{
      id: "25",
      identifier: "GH-25",
      title: "Merge me",
      repo_owner: "devp1",
      repo_name: "Beacon",
      pr_url: "https://github.com/devp1/Beacon/pull/25",
      head_sha: "abc123"
    }

    assert {:ok, %{"merged" => true, "sha" => "merge-sha"}} = GitHubClient.merge_pull_request(issue)

    assert_received {:gh_args, args, [{"GH_TOKEN", "builder-token"}, {"GITHUB_TOKEN", "builder-token"}]}
    assert ["api", "repos/devp1/Beacon/pulls/25/merge" | _] = args
    assert "merge_method=squash" in args
    assert "sha=abc123" in args
  end

  test "preflight fails when gh auth is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      ["auth", "status", "-h", "github.com"] -> {"not logged in", 1}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert {:error, {:github_auth_preflight_failed, 1, "not logged in"}} = GitHubClient.preflight()
  end

  test "preflight fails when configured workflow labels are missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      ["auth", "status", "-h", "github.com"] ->
        {"Logged in to github.com", 0}

      ["api", "repos/devp1/Beacon/labels", "-X", "GET", "-F", "per_page=100"] ->
        {Jason.encode!([%{"name" => "symphony"}, %{"name" => "agent-ready"}]), 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert {:error, {:github_missing_labels, "devp1/Beacon", missing}} = GitHubClient.preflight()
    assert "in-progress" in missing
    assert "needs-input" in missing
  end

  test "update_issue_state moves GitHub issues to needs-input label" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn args ->
      send(parent, {:gh_args, args})
      {"{}", 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert :ok = GitHubClient.update_issue_state("1", "Needs Input")

    assert_received {:gh_args, ["api", "repos/devp1/Beacon/issues/1", "-X", "PATCH", "-f", "state=open"]}

    assert_received {:gh_args,
                     [
                       "api",
                       "repos/devp1/Beacon/issues/1/labels",
                       "-X",
                       "POST",
                       "-f",
                       "labels[]=symphony"
                     ]}

    assert_received {:gh_args,
                     [
                       "api",
                       "repos/devp1/Beacon/issues/1/labels",
                       "-X",
                       "POST",
                       "-f",
                       "labels[]=needs-input"
                     ]}

    refute_received {:gh_args,
                     [
                       "api",
                       "repos/devp1/Beacon/issues/1/labels/symphony",
                       "-X",
                       "DELETE",
                       "--silent"
                     ]}
  end

  test "update_issue_state treats already closed GitHub issues as done" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_owner: "devp1",
      tracker_repo: "Beacon"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_command_fun, fn
      ["api", "repos/devp1/Beacon/issues/1"] = args ->
        send(parent, {:gh_args, args})
        {Jason.encode!(%{"state" => "closed"}), 0}

      args ->
        send(parent, {:gh_args, args})
        {"{}", 0}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_command_fun) end)

    assert :ok = GitHubClient.update_issue_state("1", "Done")

    assert_received {:gh_args, ["api", "repos/devp1/Beacon/issues/1"]}
    refute_received {:gh_args, ["api", "repos/devp1/Beacon/issues/1", "-X", "PATCH", "-f", "state=closed"]}
  end

  defp bearer_jwt_from_args(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["-H", "Authorization: Bearer " <> jwt] -> jwt
      _other -> nil
    end)
  end

  defp test_private_key_pem do
    {:rsa, 1024, 65_537}
    |> :public_key.generate_key()
    |> then(&:public_key.pem_entry_encode(:RSAPrivateKey, &1))
    |> then(&:public_key.pem_encode([&1]))
  end
end
