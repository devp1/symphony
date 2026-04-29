---
tracker:
  kind: github
  owner: devp1
  repo: Beacon
  label: symphony
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
github:
  builder_token: $SYMPHONY_GITHUB_BUILDER_TOKEN
  reviewer_token: $SYMPHONY_GITHUB_REVIEWER_TOKEN
  review_check_name: symphony/autonomous-review
  required_check_names: []
polling:
  interval_ms: 10000
workspace:
  root: ~/code/symphony-workspaces/beacon
hooks:
  after_create: |
    git clone https://github.com/devp1/Beacon.git .
  before_run: |
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      safe_name="$(printf '%s' "$(basename "$PWD")" | tr -c 'A-Za-z0-9._-' '-')"
      branch="codex/${safe_name:-issue}"
      git fetch origin main >/dev/null 2>&1 || true
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        git switch "$branch"
      else
        git switch -c "$branch"
      fi
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 8
  artifact_nudge_tokens: 150000
  max_artifact_nudges: 1
  max_tokens_before_first_artifact: 200000
  max_tokens_without_artifact: 300000
evidence:
  enabled: true
  review_gate: blocking
  force_labels:
    - evidence-required
  skip_labels:
    - evidence-skip
  max_review_attempts: 2
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
---

You are working on a GitHub issue for Beacon.

Issue:
- Identifier: {{ issue.identifier }}
- Number: {{ issue.number }}
- Repository: {{ issue.repo_full_name }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:

1. Work only inside this Symphony-created Beacon workspace.
2. GitHub labels are the machine-readable workflow state:
   - `agent-ready` = Todo
   - `in-progress` = In Progress
   - `human-review` = Human Review
   - `needs-input` = Symphony paused because Codex needs human input
   - `blocked` = Symphony cannot proceed because an external dependency is missing
   - `rework` = Rework
   - `merging` = Merging
3. Symphony owns the kickoff claim transition. If this worker starts while the issue is still Todo/`agent-ready`, stop as claim drift instead of implementing.
4. Symphony creates local `.symphony/` runtime files before and during a run. Read `.symphony/workpad.md` early if it helps, write `.symphony/handoff.json` before final handoff, and keep `.symphony/` out of commits.
5. Before broad repo exploration, verify the `before_run` hook put the checkout on the issue branch, read `docs/handoff-2026-04-27.md`, inspect the nearest runner/test entry points, and produce one useful repo artifact. Valid early artifacts are a focused failing/characterization test, fixture, runner config, code change, or dated validation note tied to a command you actually ran.
6. Create or update one durable `## Codex Workpad` issue comment at the first natural checkpoint: once the initial plan is clear, once the first artifact exists, or when genuinely blocked. Prefer targeted issue comment/PR lookup before the first repo artifact, while using broader history when it is genuinely needed to avoid duplicating work.
7. Treat the project goal as proving the autonomous exhaustion runner can close real target gaps with honest evidence.
8. Keep scope narrow to the GitHub issue. If you discover adjacent work, create a separate GitHub issue instead of expanding this one.
9. Use the authenticated `gh` CLI for routine GitHub comments, label transitions, branch pushes, and PR handoff. Do not use GitHub MCP/app connector tools for ordinary bookkeeping in unattended runs; they can ask for interactive approval.
10. Write a compact plan in a GitHub issue comment when it helps coordination, but do not let comment reconciliation delay the first real repo artifact. Identify the validation signal you will use. Keep the comment short; it is coordination, not progress proof.
11. During long runs, keep leaving inspectable repo artifacts as the work matures: focused tests, fixtures, runner configs, code changes, or dated validation notes tied to real command output. Issue comments, status narration, and broad plans are useful coordination, but they are not progress proof.
12. Autonomy shortcut before the first repo artifact: do not fetch full issue comments, memory rollout summaries, or old run logs unless they directly change the first edit/test path. If Symphony gives you a continuation nudge or `.symphony/continuation.json`, use that compact state as the resume point instead of rediscovering old context. If the workspace already has issue-relevant uncommitted changes on a continuation, inspect that diff first, remove unrelated generated churn, run validation, and move toward PR handoff before broad rediscovery. Use narrow GitHub queries such as issue body, labels, state, URL, and branch PR existence. If you need the existing workpad, fetch only enough to find/update the `## Codex Workpad` comment.
13. Soft budget: if the first implementation path is uncertain after a serious targeted pass, create the smallest honest characterization artifact that sharpens the path: a focused test, tiny fixture, runner config, or dated validation note with command/result evidence. Move to `needs-input` only for missing external secrets, permissions, required services, or a product decision the issue cannot answer. Do not stop just because several read-only commands were useful while making real progress.
14. Run the most relevant targeted validation for the change. Use `npm run typecheck` and `npm test` when the scope touches shared behavior.
15. Do not claim completion without concrete evidence from commands, tests, or a real runner walk.
16. Create or update a PR for completed work. Add a concise issue comment with changed files, validation results, blockers, and remaining uncertainty.
17. When ready for review, write `.symphony/handoff.json` with `ready: true`, `state: "human-review"`, `reason`, `pr_url`, summary, validation evidence, and an `evidence` object. Use `"evidence": {"required": true, "bundle_path": ".symphony/evidence/RUN-ID/manifest.json", "reason": "runner behavior changed"}` when a trace/log/validation bundle should be reviewed, or `"required": false` for docs-only/no-runtime work. Required evidence manifests use `schema_version: "symphony.evidence.v1"`, a non-empty `summary`, and at least one inspectable `artifacts` or `commands` entry. Relative artifact/log paths resolve from the manifest directory, must exist, and must stay inside the issue workspace; `http://` and `https://` URLs are allowed for externally hosted artifacts. Then stop. Symphony preserves a ready marker across restart/recovery, runs any configured evidence review, removes `in-progress`/`rework`, adds `human-review`, verifies the label state, and clears the verified marker so later rework must write a fresh one. After the ready handoff marker exists, do not start optional rediscovery or cleanup. Do not close the issue yourself unless the change has landed.
18. If you need human input, missing auth, missing secrets, or a permission you cannot resolve autonomously, leave a clear issue comment, write `.symphony/handoff.json` with `ready: true`, `state: "needs-input"`, and the exact blocker, then let Symphony verify/move the issue to `needs-input`.
