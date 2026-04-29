# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls GitHub Issues for candidate work across configured repositories
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until it produces a PR-ready handoff or reaches a real blocker

The local Phoenix cockpit shows configured repos, GitHub issue label states, active Codex sessions,
SQLite-backed run history, token usage, and evidence/PR handoff metadata.

For `runtime_profile: local_trusted` GitHub runs, Symphony keeps one durable Codex issue session
alive across implementation, PR handoff parking at `human-review`, and later `rework`. Runs remain
per-active-cycle audit records; the issue session is the durable collaborator identity.

If a claimed issue moves to a terminal state (`Done`), Symphony stops the active agent for that
issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Authenticate the GitHub CLI (`gh auth status`) for the repos Symphony will manage.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, and `land` skills to your repo.
5. Customize the copied `WORKFLOW.md` file for your project.
   - Configure `repos:` with GitHub `owner`, `name`, optional `id`, optional `clone_url`, and
     optional label overrides.
   - The default GitHub label state machine is `agent-ready`, `in-progress`, `human-review`,
     `needs-input`, `blocked`, `rework`, `merging`, plus the managed label `symphony`.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: github
  owner: devp1
  repo: Beacon
repos:
  - id: beacon
    owner: devp1
    name: Beacon
    clone_url: https://github.com/devp1/Beacon.git
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone https://github.com/devp1/Beacon.git .
  before_run: |
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      safe_name="$(printf '%s' "$(basename "$PWD")" | tr -c 'A-Za-z0-9._-' '-')"
      branch="codex/${safe_name:-issue}"
      git switch "$branch" 2>/dev/null || git switch -c "$branch"
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
  artifact_nudge_tokens: 250000
  max_artifact_nudges: 2
  max_tokens_before_first_artifact: 300000
  max_tokens_without_artifact: 750000
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  semantic_inactivity_timeout_ms: 1800000
storage:
  sqlite_path: ./symphony.sqlite3
---

You are working on a GitHub issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `runtime_profile` defaults to `default`. Set `runtime_profile: local_trusted` only for trusted
  local dogfood runs that need Codex workers to push branches, open PRs, and comment on GitHub; it
  runs local Codex sessions with `danger-full-access` so Git handoff is not blocked by sandboxed
  `.git` writes. Remote workers stay workspace-scoped.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony normally passes the map through to
  Codex unchanged. With `runtime_profile: local_trusted`, omitted local turn policy resolves to
  `{"type":"dangerFullAccess"}`. Explicit `dangerFullAccess` stays minimal; explicit workspace
  policies still force network access and include the issue workspace in `writableRoots`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  active work cycle when a turn completes normally but the issue is still in an active state.
  Default: `20`. Local trusted sessions park at that boundary and can resume the same thread.
- `agent.artifact_nudge_tokens`, `agent.max_tokens_before_first_artifact`, and
  `agent.max_tokens_without_artifact` are advisory health budgets for local trusted durable
  sessions. When crossed, Symphony records `stale-proof` or `high-token-no-proof` warnings in the
  SQLite ledger/API/dashboard, but it does not terminate Codex.
- `codex.semantic_inactivity_timeout_ms` defaults to `1800000` (30 minutes). It is the hard
  stuck-run guard for local trusted sessions: Symphony resets it only on meaningful Codex activity
  such as agent message deltas, command output, file-change output, MCP progress, tool calls,
  approval handling, or turn lifecycle events.
- Legacy and remote workers may still use those budgets for restart/pause behavior until durable
  remote sessions are implemented.
- Trusted local dogfood workflows can set larger warning budgets, for example `300000` before the
  first artifact and `750000` after artifact progress starts.
  The watchdog is a visibility surface for no-proof loops, not a substitute for Codex's own
  judgment.
- The workflow prompt should put the kickoff contract near the top: claim already done, verify the
  issue branch, read the smallest useful context, produce one issue-relevant repo artifact before
  broad exploration, then keep the durable issue workpad useful at natural checkpoints.
- A `hooks.before_run` branch switch is recommended for GitHub repos so issue-branch setup is
  Symphony-owned plumbing instead of Codex spending early tokens on it.
- For unattended GitHub bookkeeping, prefer the authenticated `gh` CLI over GitHub MCP/app connector
  tools. Connector elicitation requests are treated as human approval prompts so they do not silently
  stall behind the artifact watchdog.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `repos` is the first-class GitHub repository list for the cockpit and runner. If omitted,
  `tracker.owner`/`tracker.repo` are used as a backward-compatible single repo.
- `storage.sqlite_path` controls the local SQLite ledger used for run history, issue snapshots,
  run events, artifacts, and Codex session metadata.
- `tracker.api_key` reads from `LINEAR_API_KEY`, `GITHUB_TOKEN`, or `GH_TOKEN` when unset or when
  value is an env reference. GitHub mode primarily uses the authenticated `gh` CLI.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- On startup, stale persisted run-ledger rows still marked `running` are changed to `cancelled`
  with an interruption event, and stale persisted issue sessions are marked
  `interrupted-resumable`. For local trusted sessions, the next dispatch reuses the preserved
  workspace and attempts Codex `thread/resume`; if that fails, Symphony records a warning and starts
  a fresh persisted thread.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/repos`, `/api/v1/issues`, `/api/v1/runs/:id`,
  `/api/v1/runs/:run_id/cancel`, `/api/v1/issues/:repo_id/:number/rerun`,
  `/api/v1/issues/:repo_id/:number/stop-session`, `/api/v1/<issue_identifier>`, and
  `/api/v1/refresh`.

## Web dashboard

The cockpit UI runs on a minimal Phoenix stack:

- LiveView for the GitHub cockpit at `/`
- JSON API for operational debugging and runtime data under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

The cockpit surfaces GitHub PR handoff metadata when available: PR URL, head SHA, check state, and
review state. Active run rows include operator controls to request cancellation, rerun an issue, or
stop a parked/running durable issue session. Those controls call the same JSON API used by tests;
they are local trusted control-plane actions, not part of the worker prompt.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end tests only when you want Symphony to touch live external systems
and launch a real `codex app-server` session. The older live harness still exercises the legacy
Linear path; the GitHub cockpit path should use disposable GitHub issues/PRs in a test repository.

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The legacy live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`,
runs a real agent turn, verifies the workspace side effect, requires Codex to comment on and close
the Linear issue, then marks the project completed so the run remains visible in Linear. This is
kept as compatibility coverage while the primary v1 product direction moves to GitHub Issues plus
PR handoff.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
