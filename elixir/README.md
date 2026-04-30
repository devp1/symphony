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
3. Launches the configured coding-agent adapter inside the workspace. The current default adapter is
   Codex in [App Server mode](https://developers.openai.com/codex/app-server/).
4. Sends a workflow prompt to the coding agent
5. Keeps the agent working on the issue until it produces a PR-ready handoff or reaches a real
   blocker

The local Phoenix cockpit shows configured repos, GitHub issue label states, active Codex sessions,
SQLite-backed run history, token usage, and evidence/PR handoff metadata.

For `runtime_profile: local_trusted` GitHub runs, Symphony keeps one durable Codex issue session
alive across implementation, PR handoff parking at `human-review`, and later `rework`. Runs remain
per-active-cycle audit records; the issue session is the durable collaborator identity.
Workers also write a local `.symphony/handoff.json` marker before final handoff. Symphony treats
that file as a controller-actionable signal, applies the requested GitHub label transition itself,
and verifies the refreshed issue state before parking or stopping the session. In local trusted
runs, Symphony watches for a ready marker during an active turn and interrupts that turn through
Codex app-server `turn/interrupt` so the durable thread parks cleanly after handoff instead of
drifting into more work.
If the handoff requests `human-review` with required evidence, Symphony runs a separate review-agent
turn through the same coding-agent adapter boundary before applying the label. Missing or failed
evidence is fed back into the same executor thread; after the configured attempt budget, the issue
moves to `needs-input` for operator inspection.

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

After changing Elixir source, run `mise exec -- mix build` again before dogfooding
`./bin/symphony`. The checked-in escript is static, and the CLI refuses to start
from a source checkout when runtime source files are newer than `bin/symphony`.
Use `--allow-stale-binary` only for deliberate debugging of an older packaged
binary.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--allow-stale-binary` bypasses the source-vs-escript freshness guard. This
  should be rare; normal local dogfood should rebuild with `mise exec -- mix build`.
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
github:
  builder_token: $SYMPHONY_GITHUB_BUILDER_TOKEN
  reviewer_token: $SYMPHONY_GITHUB_REVIEWER_TOKEN
  # Prefer GitHub Apps for local dogfood so check-runs and approvals use
  # independent identities. Symphony also auto-loads these canonical variables
  # from ~/.config/symphony/github-apps/env when they are not already set.
  # builder_app:
  #   app_id: $SYMPHONY_GITHUB_BUILDER_APP_ID
  #   installation_id: $SYMPHONY_GITHUB_BUILDER_INSTALLATION_ID
  #   private_key_path: $SYMPHONY_GITHUB_BUILDER_PRIVATE_KEY_PATH
  # reviewer_app:
  #   app_id: $SYMPHONY_GITHUB_REVIEWER_APP_ID
  #   installation_id: $SYMPHONY_GITHUB_REVIEWER_INSTALLATION_ID
  #   private_key_path: $SYMPHONY_GITHUB_REVIEWER_PRIVATE_KEY_PATH
  review_check_name: symphony/autonomous-review
  required_check_names:
    - ci
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
evidence:
  enabled: true
  review_gate: blocking
  force_labels: [evidence-required]
  skip_labels: [evidence-skip]
  max_review_attempts: 2
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
- Prefer `github.builder_app` and `github.reviewer_app` for the full independent-review path. Each
  block takes `app_id`, `installation_id`, and either `private_key_path` or `private_key`; the
  checked-in `github-builder-app-manifest.json` and `github-reviewer-app-manifest.json` files are
  starting points for private app creation. Symphony mints short-lived installation tokens for its
  own GitHub writes and keeps App private keys out of coding-agent sessions.
- `github.builder_token` and `github.reviewer_token` remain optional `$VAR` token references for
  existing setups. App blocks take precedence over tokens when configured. The builder identity owns
  Symphony issue labels/comments and normal worker handoff bookkeeping. The reviewer identity owns
  autonomous PR review checks and PR review comments/approvals.
- `github.review_check_name` defaults to `symphony/autonomous-review`. Symphony records autonomous
  reviewer verdicts in SQLite and can publish a GitHub check with conclusion `success`,
  `failure`, or `action_required` for `pass`, `request_changes`, or `needs_input`.
- `github.required_check_names` names the normal CI checks required for cockpit merge. When it is
  non-empty, `symphony/autonomous-review` alone is not enough; missing required checks are reported
  as `ci-not-reported`.
- Symphony refuses pass-style PR approvals unless the configured reviewer identity is present and
  distinct from the builder identity. When an independent reviewer identity is configured, GitHub
  human-review handoffs run the autonomous reviewer before parking the durable session. `pass`
  parks at `human-review`; `request_changes` writes
  `.symphony/autonomous-reviews/review-feedback.md` and prompts the same executor thread; review
  infrastructure failures move the issue to `needs-input`. If the reviewer identity is not
  configured yet, Symphony records a local `needs_input` autonomous-review verdict instead of
  pretending an independent gate ran.
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
- `.symphony/handoff.json` is the machine-readable worker handoff marker. It is runtime state and
  must not be committed. The supported final states are `human-review`, `needs-input`, `blocked`,
  and `done`; Symphony maps those to the configured tracker labels/state and verifies the result.
  Stale handoff markers are cleared at the start of each active local work cycle, so rework must
  write a fresh marker when it becomes review-ready again.
- For `human-review`, workers may include an `evidence` object in the handoff marker:
  `{"required": true, "bundle_path": ".symphony/evidence/<run>/manifest.json", "reason": "UI changed"}`.
  In the default blocking gate, Symphony records the bundle, runs a review-agent turn through the
  coding-agent adapter with full repo read/network access and write access only to its review
  artifact, and only then applies `human-review`. Failed or missing evidence creates
  `.symphony/evidence/review-feedback.md`, removes the stale handoff marker, and prompts the same
  executor thread to fix the work or evidence.
- Required evidence manifests use `schema_version: "symphony.evidence.v1"`, a non-empty `summary`,
  and at least one inspectable `artifacts` or `commands` entry. Local artifact/log paths resolve
  from the manifest directory, must exist, and must stay inside the issue workspace. `http://` and
  `https://` URLs are allowed for externally hosted artifacts. Artifact `kind` values are flexible
  so agents can add new proof types without controller changes.
- `evidence.enabled`, `evidence.review_gate`, `evidence.force_labels`, `evidence.skip_labels`, and
  `evidence.max_review_attempts` configure that gate. `review_gate: advisory` records evidence
  metadata without blocking handoff; `review_gate: off` disables it.
- `agent.artifact_nudge_tokens`, `agent.max_tokens_before_first_artifact`, and
  `agent.max_tokens_without_artifact` are advisory health budgets for local trusted durable
  sessions. When crossed, Symphony records `stale-proof` or `high-token-no-proof` warnings in the
  SQLite ledger/API/dashboard, but it does not terminate Codex.
- These token totals are observability counters, not cost counters. Upstream prompt caching can make
  repeated input-prefix tokens cheaper and faster, but output/reasoning and dynamic command/GitHub
  output still represent real runtime and context churn. Large no-artifact or post-handoff token
  spends should be treated as workflow/prompt issues even when cached input lowers cost.
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
  `/`, `/api/v1/state`, `/api/v1/readiness`, `/api/v1/repos`, `/api/v1/issues`, `/api/v1/runs/:id`,
  `/api/v1/runs/:run_id/cancel`, `/api/v1/issues/:repo_id/:number/rerun`,
  `/api/v1/issues/:repo_id/:number/merge`, `/api/v1/issues/:repo_id/:number/stop-session`,
  `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The cockpit UI runs on a minimal Phoenix stack:

- LiveView for the GitHub cockpit at `/`
- JSON API for operational debugging and runtime data under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

The cockpit surfaces GitHub PR handoff metadata when available: PR URL, head SHA, check state, and
review state. PR-backed issue cards include a local trusted `Merge` action only when the server-side
merge gate is clear: open PR, green CI, passing autonomous review, and non-stale review head SHA.
Blocked cards show exact disabled reasons like `ci-not-reported`, `ci-not-green`, and
`autonomous-review-stale`, and the merge endpoint recomputes the same gate
before issuing any GitHub merge request. Once GitHub accepts the merge, the cockpit immediately
updates local issue, run, and durable-session state to done/merged so the board does not wait for the
next poll; closing the GitHub issue is attempted through the builder identity and recorded as part of
the merge response. Done issue cards also show a compact merge audit line with tracker, issue
snapshot, run-ledger, and durable-session reconciliation status plus a run-detail link. Active run
rows include operator controls to request cancellation, rerun an issue, or stop a parked/running
durable issue session. Those controls call the same JSON API used by tests; they are local trusted
control-plane actions, not part of the worker prompt.
Parked durable sessions are shown separately from active runs so `human-review` parking does not look
like a failing or still-running worker.

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
