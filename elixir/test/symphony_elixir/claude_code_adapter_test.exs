defmodule SymphonyElixir.ClaudeCodeAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CodingAgent.ClaudeCodeAdapter
  alias SymphonyElixir.{Config, Linear.Issue, Workflow}

  test "builds Claude CLI argv without bare mode" do
    test_root = tmp_dir("claude-argv")
    fake = fake_claude(test_root, "cat >/dev/null")

    write_workflow_file!(Workflow.workflow_file_path(),
      claude_code_command: "#{fake} --base",
      claude_code_model: "sonnet",
      claude_code_extra_args: ["--include-partial-messages"]
    )

    session_id = "11111111-1111-4111-8111-111111111111"
    assert {:ok, [^fake | args]} = ClaudeCodeAdapter.cli_argv(session_id, Config.settings!())

    assert args == [
             "--base",
             "-p",
             "--verbose",
             "--output-format",
             "stream-json",
             "--input-format",
             "text",
             "--permission-mode",
             "bypassPermissions",
             "--session-id",
             session_id,
             "--model",
             "sonnet",
             "--setting-sources",
             "user,project,local",
             "--include-partial-messages"
           ]

    refute "--bare" in args
  end

  test "phase profile overrides Claude model, effort, permission mode, and extra args" do
    test_root = tmp_dir("claude-profile-argv")
    fake = fake_claude(test_root, "cat >/dev/null")

    write_workflow_file!(Workflow.workflow_file_path(),
      claude_code_command: fake,
      claude_code_model: "global-sonnet",
      claude_code_extra_args: ["--global-arg"]
    )

    session_id = "33333333-3333-4333-8333-333333333333"

    assert {:ok, [^fake | args]} =
             ClaudeCodeAdapter.cli_argv(session_id, Config.settings!(), %{
               provider: "claude_code",
               model: "task-opus",
               effort: "high",
               permission_mode: "acceptEdits",
               extra_args: ["--profile-arg"]
             })

    assert Enum.chunk_every(args, 2, 1, :discard)
           |> Enum.any?(fn [left, right] -> left == "--model" and right == "task-opus" end)

    assert Enum.chunk_every(args, 2, 1, :discard)
           |> Enum.any?(fn [left, right] -> left == "--effort" and right == "high" end)

    assert Enum.chunk_every(args, 2, 1, :discard)
           |> Enum.any?(fn [left, right] -> left == "--permission-mode" and right == "acceptEdits" end)

    assert "--profile-arg" in args
    assert "--global-arg" in args
    refute "--bare" in args
  end

  test "fake Claude stream success records session ids, stdin prompt, assistant update, and result" do
    test_root = tmp_dir("claude-success")
    workspace = Path.join(test_root, "workspaces/GH-1")
    File.mkdir_p!(workspace)

    argv_path = Path.join(test_root, "argv.txt")
    stdin_path = Path.join(test_root, "stdin.txt")

    fake =
      fake_claude(test_root, """
      printf '%s\\n' "$@" > "$ARGV_PATH"
      cat > "$STDIN_PATH"
      printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}'
      printf '%s\\n' '{"type":"result","is_error":false,"result":"done"}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      claude_code_command: fake
    )

    issue = %Issue{id: "beacon#1", identifier: "GH-1", repo_id: "beacon", number: 1}

    assert {:ok, session} = ClaudeCodeAdapter.start_session(:executor, workspace, [])

    assert {:ok, %{session_id: session_id, thread_id: thread_id, result: %{"result" => "done"}}} =
             ClaudeCodeAdapter.run_turn(:executor, session, "rendered prompt", issue,
               on_message: fn message -> send(self(), {:claude_message, message}) end,
               env: [{"ARGV_PATH", argv_path}, {"STDIN_PATH", stdin_path}]
             )

    assert session_id == session.thread_id
    assert thread_id == session.thread_id
    assert File.read!(stdin_path) == "rendered prompt"
    argv = argv_path |> File.read!() |> String.split("\n", trim: true)
    refute "--bare" in argv
    assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.any?(fn [left, right] -> left == "--session-id" and right == session.thread_id end)

    assert_receive {:claude_message, %{event: :session_started, session_id: ^session_id, thread_id: ^thread_id}}
    assert_receive {:claude_message, %{event: :"claude/event/assistant", payload: %{"type" => "assistant"}}}
    assert_receive {:claude_message, %{event: :"claude/event/result", payload: %{"type" => "result", "is_error" => false}}}
  end

  test "resume uses the same UUID on later turns" do
    test_root = tmp_dir("claude-resume")
    workspace = Path.join(test_root, "workspaces/GH-2")
    File.mkdir_p!(workspace)

    argv_path = Path.join(test_root, "argv.txt")

    fake =
      fake_claude(test_root, """
      printf '%s\\n' "$@" > "$ARGV_PATH"
      cat >/dev/null
      printf '%s\\n' '{"type":"result","is_error":false,"result":"ok"}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      claude_code_command: fake
    )

    uuid = "22222222-2222-4222-8222-222222222222"
    assert {:ok, session} = ClaudeCodeAdapter.start_session(:executor, workspace, resume_thread_id: uuid)
    assert session.thread_id == uuid

    assert {:ok, %{thread_id: ^uuid}} =
             ClaudeCodeAdapter.run_turn(:executor, session, "again", %Issue{identifier: "GH-2"}, env: [{"ARGV_PATH", argv_path}])

    argv = argv_path |> File.read!() |> String.split("\n", trim: true)
    assert Enum.chunk_every(argv, 2, 1, :discard) |> Enum.any?(fn [left, right] -> left == "--session-id" and right == uuid end)
  end

  test "system init needs-auth MCP metadata does not count as Claude auth failure" do
    test_root = tmp_dir("claude-system-needs-auth")
    workspace = Path.join(test_root, "workspaces/GH-needs-auth")
    File.mkdir_p!(workspace)

    fake =
      fake_claude(test_root, """
      cat >/dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","mcp_servers":[{"name":"Gmail","status":"needs-auth"}]}'
      printf '%s\\n' '{"type":"result","is_error":false,"result":"ok"}'
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      claude_code_command: fake
    )

    assert {:ok, session} = ClaudeCodeAdapter.start_session(:executor, workspace, [])
    assert {:ok, %{result: %{"result" => "ok"}}} = ClaudeCodeAdapter.run_turn(:executor, session, "prompt", %Issue{identifier: "GH-needs-auth"})
  end

  test "remote worker is unsupported for Claude Code" do
    assert {:error, {:unsupported_agent_provider, :claude_code, :remote_worker}} =
             ClaudeCodeAdapter.start_session(:executor, "/remote/workspace", worker_host: "worker-a")
  end

  test "Claude result errors, nonzero exit, malformed JSON, auth failure, and timeout are actionable" do
    assert_claude_error(
      "result-error",
      ~s(printf '%s\\n' '{"type":"result","is_error":true,"message":"bad"}'),
      {:claude_code_result_error, %{"is_error" => true, "message" => "bad", "type" => "result"}}
    )

    assert_claude_error("nonzero", "cat >/dev/null\nexit 7", {:claude_code_exit, 7, []})
    assert_claude_error("malformed", "printf '%s\\n' 'not json'", {:malformed_claude_json, "not json"})
    assert_claude_error("auth", "printf '%s\\n' 'OAuth login required'", {:claude_code_auth_failed, "OAuth login required"})

    test_root = tmp_dir("claude-timeout")
    workspace = Path.join(test_root, "workspaces/GH-timeout")
    File.mkdir_p!(workspace)

    fake =
      fake_claude(test_root, """
      cat >/dev/null
      sleep 1
      """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      claude_code_command: fake,
      codex_stall_timeout_ms: 20,
      codex_turn_timeout_ms: 1_000
    )

    assert {:ok, session} = ClaudeCodeAdapter.start_session(:executor, workspace, [])

    assert {:error, {:claude_code_timeout, :stall, 20}} =
             ClaudeCodeAdapter.run_turn(:executor, session, "prompt", %Issue{identifier: "GH-timeout"})
  end

  defp assert_claude_error(name, script, expected) do
    test_root = tmp_dir("claude-#{name}")
    workspace = Path.join(test_root, "workspaces/GH-error")
    File.mkdir_p!(workspace)
    fake = fake_claude(test_root, script)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "workspaces"),
      claude_code_command: fake
    )

    assert {:ok, session} = ClaudeCodeAdapter.start_session(:executor, workspace, [])
    assert {:error, ^expected} = ClaudeCodeAdapter.run_turn(:executor, session, "prompt", %Issue{identifier: "GH-error"})
  end

  defp fake_claude(test_root, body) do
    path = Path.join(test_root, "fake-claude")

    File.write!(path, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
