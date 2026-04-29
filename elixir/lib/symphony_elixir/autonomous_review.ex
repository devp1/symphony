defmodule SymphonyElixir.AutonomousReview do
  @moduledoc """
  Agent-agnostic PR review and merge-gate helpers.

  Executor sessions remain responsible for producing a PR-ready branch. This
  module records the independent review verdict and projects whether the PR is
  eligible for a later merge action.
  """

  alias SymphonyElixir.{Config, GitHub, Linear.Issue, Storage}

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

  @spec normalize_verdict(term()) :: verdict()
  def normalize_verdict(verdict) when verdict in [:pass, :request_changes, :needs_input], do: Atom.to_string(verdict)

  def normalize_verdict(verdict) when is_binary(verdict) do
    verdict
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "pass" -> "pass"
      "approved" -> "pass"
      "approve" -> "pass"
      "request_changes" -> "request_changes"
      "changes_requested" -> "request_changes"
      "fail" -> "request_changes"
      "failed" -> "request_changes"
      "needs_input" -> "needs_input"
      "blocked" -> "needs_input"
      _ -> "needs_input"
    end
  end

  def normalize_verdict(_verdict), do: "needs_input"

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
    stale = stale_review?(issue, head_sha)

    Storage.record_autonomous_review(%{
      run_id: Map.get(attrs, :run_id) || Map.get(attrs, "run_id"),
      issue_session_id: Map.get(attrs, :issue_session_id) || Map.get(attrs, "issue_session_id"),
      repo_id: issue.repo_id,
      issue_number: issue.number,
      issue_identifier: issue.identifier,
      pr_url: issue.pr_url,
      head_sha: head_sha,
      reviewer_kind: Map.get(attrs, :reviewer_kind) || Map.get(attrs, "reviewer_kind") || "review-agent",
      verdict: verdict,
      summary: Map.get(attrs, :summary) || Map.get(attrs, "summary"),
      findings: Map.get(attrs, :findings) || Map.get(attrs, "findings") || [],
      check_name: Config.settings!().github.review_check_name,
      check_conclusion: check_conclusion(verdict),
      stale: stale,
      output_path: Map.get(attrs, :output_path) || Map.get(attrs, "output_path")
    })
  end

  @spec publish(Issue.t(), review_attrs()) :: :ok | {:error, term()}
  def publish(%Issue{} = issue, attrs) when is_map(attrs) do
    verdict = normalize_verdict(Map.get(attrs, :verdict) || Map.get(attrs, "verdict"))
    attrs = Map.put(attrs, :verdict, verdict)

    with {:ok, _review_id} <- record(issue, attrs),
         :ok <- GitHub.Client.upsert_autonomous_review_check(issue, attrs) do
      case GitHub.Client.submit_autonomous_pr_review(issue, attrs) do
        :ok -> :ok
        {:error, :reviewer_identity_not_independent} when verdict == "pass" -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

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

    %{ready?: reasons == [], reasons: Enum.reverse(reasons), review_verdict: review_verdict, review_stale?: review_stale?}
  end

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, _condition, _reason), do: reasons

  defp missing_pr?(%Issue{pr_url: pr_url, pr_number: pr_number}) do
    (not is_binary(pr_url) or String.trim(pr_url) == "") and is_nil(pr_number)
  end

  defp review_verdict(%{} = review), do: normalize_verdict(Map.get(review, :verdict) || Map.get(review, "verdict"))
  defp review_verdict(_review), do: nil

  defp review_stale?(%Issue{} = issue, %{} = review) do
    stale_review?(issue, Map.get(review, :head_sha) || Map.get(review, "head_sha"))
  end

  defp review_stale?(_issue, _review), do: false

  defp stale_review?(%Issue{head_sha: issue_head_sha}, review_head_sha)
       when is_binary(issue_head_sha) and issue_head_sha != "" and is_binary(review_head_sha) and review_head_sha != "" do
    issue_head_sha != review_head_sha
  end

  defp stale_review?(_issue, _review_head_sha), do: false
end
