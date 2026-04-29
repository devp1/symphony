defmodule SymphonyElixir.AutonomousReview do
  @moduledoc """
  Agent-agnostic PR review and merge-gate helpers.

  Executor sessions remain responsible for producing a PR-ready branch. This
  module records the independent review verdict and projects whether the PR is
  eligible for a later merge action.
  """

  alias SymphonyElixir.{CodingAgent, Config, GitHub, Linear.Issue, Storage}

  @review_artifact_dir ".symphony/autonomous-reviews"

  @type verdict :: String.t()
  @type review_attrs :: %{
          optional(:run_id) => String.t() | nil,
          optional(:issue_session_id) => String.t() | nil,
          optional(:reviewer_kind) => String.t(),
          optional(:verdict) => verdict() | String.t() | atom(),
          optional(:summary) => String.t() | nil,
          optional(:findings) => term(),
          optional(:head_sha) => String.t() | nil,
          optional(:output_path) => String.t() | nil
        }
  @type gate :: %{
          required(:ready?) => boolean(),
          required(:reasons) => [String.t()],
          required(:review_verdict) => verdict() | nil,
          required(:review_stale?) => boolean()
        }

  # The review adapter is intentionally injectable for non-Codex reviewers and
  # test fakes; Dialyzer only sees the default app-server path here.
  @dialyzer {:nowarn_function, review_and_publish: 3}
  @dialyzer {:nowarn_function, issue_with_review_head: 2}
  @dialyzer {:nowarn_function, review_with_context: 2}
  @dialyzer {:nowarn_function, maybe_put_review_context: 3}

  @spec review_pr(Path.t(), Issue.t(), keyword()) :: {:ok, review_attrs()} | {:error, term()}
  def review_pr(workspace, %Issue{} = issue, opts \\ []) when is_binary(workspace) do
    review_dir = Keyword.get(opts, :review_dir, Path.join(workspace, @review_artifact_dir))
    output_path = Path.join(review_dir, "review-#{System.unique_integer([:positive])}.json")

    with :ok <- File.mkdir_p(review_dir),
         {:ok, collector} <- Agent.start_link(fn -> [] end) do
      try do
        prompt = review_prompt(issue, output_path)

        result =
          CodingAgent.run(
            :reviewer,
            workspace,
            prompt,
            review_issue(issue),
            review_agent_opts(review_dir, collector, opts)
          )

        messages = Agent.get(collector, &Enum.reverse/1)

        case result do
          {:ok, turn} -> parse_review_result(output_path, messages, turn)
          {:error, reason} -> {:error, reason}
        end
      after
        Agent.stop(collector)
      end
    end
  end

  @spec review_and_publish(Path.t(), Issue.t(), keyword()) :: {:ok, review_attrs()} | {:error, term()}
  def review_and_publish(workspace, %Issue{} = issue, opts \\ []) when is_binary(workspace) do
    case review_pr(workspace, issue, opts) do
      {:ok, review} ->
        review = review_with_context(review, opts)
        issue = issue_with_review_head(issue, review)

        with :ok <- publish(issue, review) do
          {:ok, review}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec normalize_verdict(term()) :: verdict()
  def normalize_verdict(verdict) when verdict in [:pass, :request_changes, :needs_input], do: Atom.to_string(verdict)

  def normalize_verdict(verdict) when is_binary(verdict) do
    verdict
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> normalized_verdict_alias()
  end

  def normalize_verdict(_verdict), do: "needs_input"

  defp normalized_verdict_alias("pass"), do: "pass"
  defp normalized_verdict_alias("approved"), do: "pass"
  defp normalized_verdict_alias("approve"), do: "pass"
  defp normalized_verdict_alias("request_changes"), do: "request_changes"
  defp normalized_verdict_alias("changes_requested"), do: "request_changes"
  defp normalized_verdict_alias("fail"), do: "request_changes"
  defp normalized_verdict_alias("failed"), do: "request_changes"
  defp normalized_verdict_alias("needs_input"), do: "needs_input"
  defp normalized_verdict_alias("blocked"), do: "needs_input"
  defp normalized_verdict_alias(_verdict), do: "needs_input"

  @spec check_conclusion(verdict() | String.t() | atom()) :: String.t()
  def check_conclusion(verdict) do
    case normalize_verdict(verdict) do
      "pass" -> "success"
      "request_changes" -> "failure"
      "needs_input" -> "action_required"
    end
  end

  @spec record(Issue.t(), review_attrs()) :: {:ok, String.t()} | {:error, term()}
  def record(%Issue{} = issue, attrs) when is_map(attrs) do
    verdict = normalize_verdict(Map.get(attrs, :verdict) || Map.get(attrs, "verdict"))
    head_sha = Map.get(attrs, :head_sha) || Map.get(attrs, "head_sha") || issue.head_sha

    Storage.record_autonomous_review(record_attrs(issue, attrs, verdict, head_sha))
  end

  defp record_attrs(%Issue{} = issue, attrs, verdict, head_sha) do
    %{
      run_id: attr(attrs, :run_id),
      issue_session_id: attr(attrs, :issue_session_id),
      repo_id: issue.repo_id,
      issue_number: issue.number,
      issue_identifier: issue.identifier,
      pr_url: issue.pr_url,
      head_sha: head_sha,
      reviewer_kind: attr(attrs, :reviewer_kind) || "review-agent",
      verdict: verdict,
      summary: attr(attrs, :summary),
      findings: attr(attrs, :findings) || [],
      check_name: Config.settings!().github.review_check_name,
      check_conclusion: check_conclusion(verdict),
      stale: stale_review?(issue, head_sha),
      output_path: attr(attrs, :output_path)
    }
  end

  defp attr(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  @spec publish(Issue.t(), review_attrs()) :: :ok | {:error, term()}
  def publish(%Issue{} = issue, attrs) when is_map(attrs) do
    verdict = normalize_verdict(Map.get(attrs, :verdict) || Map.get(attrs, "verdict"))
    attrs = Map.put(attrs, :verdict, verdict)

    with :ok <- ensure_publishable_reviewer_identity(verdict),
         :ok <- GitHub.Client.submit_autonomous_pr_review(issue, attrs),
         {:ok, _review_id} <- record(issue, attrs) do
      GitHub.Client.upsert_autonomous_review_check(issue, attrs)
    end
  end

  defp ensure_publishable_reviewer_identity("pass") do
    if Config.independent_github_reviewer?(), do: :ok, else: {:error, :reviewer_identity_not_independent}
  end

  defp ensure_publishable_reviewer_identity(_verdict), do: :ok

  @spec merge_gate(Issue.t(), map() | nil) :: gate()
  def merge_gate(%Issue{} = issue, latest_review \\ nil) do
    review_verdict = review_verdict(latest_review)
    review_stale? = review_stale?(issue, latest_review)

    reasons =
      []
      |> maybe_reason(missing_pr?(issue), "missing-pr")
      |> maybe_reason(issue.pr_state not in [nil, "", "OPEN"], "pr-not-open")
      |> maybe_reason(issue.check_state != "passing", "ci-not-green")
      |> maybe_reason(review_verdict != "pass", "autonomous-review-not-passing")
      |> maybe_reason(review_stale?, "autonomous-review-stale")

    %{
      ready?: reasons == [],
      reasons: Enum.reverse(reasons),
      review_verdict: review_verdict,
      review_stale?: review_stale?
    }
  end

  @spec issue_from_snapshot(map()) :: Issue.t()
  def issue_from_snapshot(%{} = issue_snapshot) do
    %Issue{
      id: snapshot_issue_id(issue_snapshot),
      identifier: Map.get(issue_snapshot, "identifier"),
      title: Map.get(issue_snapshot, "title"),
      state: Map.get(issue_snapshot, "state"),
      url: Map.get(issue_snapshot, "url"),
      repo_id: Map.get(issue_snapshot, "repo_id"),
      number: snapshot_issue_number(issue_snapshot),
      labels: Map.get(issue_snapshot, "labels") || [],
      pr_url: Map.get(issue_snapshot, "pr_url"),
      head_sha: Map.get(issue_snapshot, "head_sha"),
      pr_state: Map.get(issue_snapshot, "pr_state"),
      check_state: Map.get(issue_snapshot, "check_state"),
      review_state: Map.get(issue_snapshot, "review_state")
    }
  end

  defp snapshot_issue_id(%{"repo_id" => repo_id, "number" => number}) when is_binary(repo_id) and is_integer(number) do
    "#{repo_id}##{number}"
  end

  defp snapshot_issue_id(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
  defp snapshot_issue_id(_issue_snapshot), do: "unknown"

  defp snapshot_issue_number(%{"number" => number}) when is_integer(number), do: number

  defp snapshot_issue_number(%{"number" => number}) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp snapshot_issue_number(_issue_snapshot), do: nil

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, _condition, _reason), do: reasons

  defp missing_pr?(%Issue{pr_url: pr_url, pr_number: pr_number}) do
    (not is_binary(pr_url) or String.trim(pr_url) == "") and is_nil(pr_number)
  end

  defp review_verdict(%{} = review) do
    normalize_verdict(Map.get(review, :verdict) || Map.get(review, "verdict"))
  end

  defp review_verdict(_review), do: nil

  defp review_stale?(%Issue{} = issue, %{} = review) do
    stale_review?(issue, Map.get(review, :head_sha) || Map.get(review, "head_sha"))
  end

  defp review_stale?(_issue, _review), do: false

  defp stale_review?(%Issue{head_sha: issue_head_sha}, review_head_sha)
       when is_binary(issue_head_sha) and issue_head_sha != "" and
              is_binary(review_head_sha) and review_head_sha != "" do
    issue_head_sha != review_head_sha
  end

  defp stale_review?(_issue, _review_head_sha), do: false

  defp issue_with_review_head(%Issue{} = issue, %{head_sha: head_sha}) when is_binary(head_sha) and head_sha != "" do
    %{issue | head_sha: issue.head_sha || head_sha}
  end

  defp issue_with_review_head(%Issue{} = issue, _review), do: issue

  defp review_with_context(review, opts) do
    review
    |> maybe_put_review_context(:run_id, Keyword.get(opts, :run_id))
    |> maybe_put_review_context(:issue_session_id, Keyword.get(opts, :issue_session_id))
    |> maybe_put_review_context(:reviewer_kind, Keyword.get(opts, :reviewer_kind))
  end

  defp maybe_put_review_context(review, _key, nil), do: review
  defp maybe_put_review_context(review, _key, ""), do: review
  defp maybe_put_review_context(review, key, value), do: Map.put(review, key, value)

  defp review_agent_opts(review_dir, collector, opts) do
    opts
    |> Keyword.delete(:on_message)
    |> Keyword.merge(
      approval_policy: "never",
      thread_sandbox: "workspace-write",
      turn_sandbox_policy: %{
        "type" => "workspaceWrite",
        "writableRoots" => [review_dir],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => true,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      },
      on_message: collect_message(collector)
    )
  end

  defp review_prompt(%Issue{} = issue, output_path) do
    """
    You are the Symphony autonomous PR reviewer. You are reviewing the PR, not implementing.

    Issue:
    - Identifier: #{issue.identifier || issue.id}
    - Title: #{issue.title}
    - State: #{issue.state}
    - URL: #{issue.url || "unknown"}
    - PR URL: #{issue.pr_url || "unknown"}
    - PR number: #{issue.pr_number || "unknown"}
    - Current head SHA: #{issue.head_sha || "unknown"}
    - CI/check state: #{issue.check_state || "unknown"}
    - GitHub review state: #{issue.review_state || "unknown"}

    Autonomous PR review contract:
    - Inspect the issue, PR diff, tests/checks, local repository state, and any evidence artifacts.
    - Use full repository context and `gh` where helpful; do not rely only on this prompt.
    - Do not edit repository source files or push commits.
    - The only file you may write is the review JSON below.
    - Use `pass` only when the PR is reviewable and there are no blocking correctness, safety, scope, or test issues.
    - Use `request_changes` when the executor should fix the PR in the same durable issue session.
    - Use `needs_input` when credentials, product decisions, missing infrastructure, or ambiguous acceptance criteria block an autonomous verdict.

    Write exactly this JSON object to #{output_path}, and also make it your final answer:
    {
      "verdict": "pass" | "request_changes" | "needs_input",
      "summary": "short human-readable judgment",
      "head_sha": "current PR head SHA reviewed",
      "findings": [
        {
          "title": "short finding title",
          "body": "actionable explanation",
          "file": "optional path",
          "line": 123,
          "severity": "critical" | "major" | "minor"
        }
      ]
    }
    """
  end

  defp review_issue(%Issue{} = issue) do
    %{issue | identifier: "#{issue.identifier || issue.id}-autonomous-review", title: "Autonomous PR review: #{issue.title}"}
  end

  defp collect_message(collector) do
    fn message ->
      Agent.update(collector, &[message | &1])
      :ok
    end
  end

  defp parse_review_result(output_path, messages, turn) do
    output_path
    |> parse_review_file()
    |> case do
      {:ok, review} ->
        {:ok, Map.merge(review, %{output_path: output_path, session_id: turn[:session_id], thread_id: turn[:thread_id]})}

      {:error, _file_reason} ->
        messages
        |> review_text_from_messages()
        |> parse_review_text()
        |> case do
          {:ok, review} -> {:ok, Map.merge(review, %{output_path: output_path, session_id: turn[:session_id], thread_id: turn[:thread_id]})}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_review_file(output_path) do
    with true <- File.regular?(output_path),
         {:ok, body} <- File.read(output_path),
         {:ok, review} <- parse_review_text(body) do
      {:ok, review}
    else
      false -> {:error, :missing_autonomous_review_output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_review_text(text) when is_binary(text) do
    case extract_json(text) do
      {:ok, json_text} ->
        case Jason.decode(json_text) do
          {:ok, decoded} -> normalize_review(decoded)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_review(%{} = review) do
    verdict = normalize_verdict(Map.get(review, "verdict") || Map.get(review, :verdict))

    {:ok,
     %{
       verdict: verdict,
       summary: string_value(review, "summary") || verdict,
       head_sha: string_value(review, "head_sha") || string_value(review, "headSha"),
       findings: Map.get(review, "findings") || Map.get(review, :findings) || []
     }}
  end

  defp normalize_review(_review), do: {:error, :autonomous_review_not_object}

  defp review_text_from_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&message_text_fragments/1)
    |> Enum.join("")
  end

  defp message_text_fragments(message) when is_map(message) do
    payload = Map.get(message, :payload) || Map.get(message, "payload") || Map.get(message, :message) || Map.get(message, "message") || message

    [
      text_at(payload, ["params", "delta"]),
      text_at(payload, ["params", "text"]),
      text_at(payload, ["params", "output"]),
      text_at(payload, ["params", "msg", "payload", "delta"]),
      text_at(payload, ["params", "msg", "payload", "text"]),
      text_at(payload, ["params", "item", "content", "text"]),
      text_at(payload, ["params", "content"]),
      text_at(message, [:payload, "params", "delta"]),
      text_at(message, [:payload, "params", "msg", "payload", "delta"])
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp message_text_fragments(_message), do: []

  defp text_at(value, path), do: get_in_nested(value, path)

  defp get_in_nested(value, []), do: value

  defp get_in_nested(%{} = map, [key | rest]) do
    case map_get(map, key) do
      nil -> nil
      nested -> get_in_nested(nested, rest)
    end
  end

  defp get_in_nested(_value, _path), do: nil

  defp map_get(%{} = map, key) when is_atom(key), do: Map.get(map, key)

  defp map_get(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp extract_json(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, :empty_autonomous_review_text}
      String.starts_with?(trimmed, "{") -> {:ok, trimmed}
      match = Regex.run(~r/```(?:json)?\s*({[\s\S]*?})\s*```/, trimmed) -> {:ok, Enum.at(match, 1)}
      match = Regex.run(~r/({[\s\S]*})/, trimmed) -> {:ok, Enum.at(match, 1)}
      true -> {:error, :missing_autonomous_review_json}
    end
  end

  defp string_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
