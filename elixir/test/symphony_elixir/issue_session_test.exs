defmodule SymphonyElixir.IssueSessionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueSession

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
