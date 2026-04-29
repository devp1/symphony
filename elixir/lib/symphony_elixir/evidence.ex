defmodule SymphonyElixir.Evidence do
  @moduledoc """
  Agent-agnostic evidence gate helpers.

  The executor agent decides whether a PR handoff needs an evidence bundle, while
  Symphony applies repo/operator overrides and records the review ledger. The
  first reviewer implementation is Codex app-server, but the contract is phrased
  around executor/review agents so another coding agent can slot in later.
  """

  alias SymphonyElixir.{AutonomousReview, CodingAgent, Config, Handoff, Linear.Issue, PathSafety}
  alias SymphonyElixir.Evidence.Manifest

  @review_artifact_dir ".symphony/evidence/reviews"

  @type decision :: %{
          required(:required) => boolean(),
          required(:status) => String.t(),
          required(:reason) => String.t(),
          optional(:manifest_path) => String.t() | nil,
          optional(:bundle_path) => String.t() | nil
        }

  @type bundle :: %{
          required(:manifest_path) => String.t(),
          required(:bundle_path) => String.t(),
          required(:manifest) => map()
        }

  @type review :: %{
          required(:verdict) => String.t(),
          optional(:summary) => String.t(),
          optional(:feedback) => term(),
          optional(:output_path) => String.t(),
          optional(:session_id) => String.t(),
          optional(:thread_id) => String.t()
        }

  @spec decision(Path.t(), Issue.t(), Handoff.t()) :: decision()
  def decision(workspace, %Issue{} = issue, handoff) when is_binary(workspace) and is_map(handoff) do
    evidence_config = Config.settings!().evidence
    labels = issue_labels(issue)
    evidence = Map.get(handoff, :evidence) || %{}

    cond do
      evidence_config.enabled == false ->
        not_required("disabled", "evidence gate disabled")

      evidence_config.review_gate == "off" ->
        not_required("disabled", "evidence review gate is off")

      true ->
        active_decision(evidence_config, labels, evidence)
    end
  end

  defp active_decision(evidence_config, labels, evidence) do
    cond do
      matching_label(labels, evidence_config.skip_labels) ->
        not_required("skipped", "skipped by issue label")

      matching_label(labels, evidence_config.force_labels) ->
        required(evidence, "required by issue label")

      true ->
        executor_decision(evidence)
    end
  end

  @spec blocking?(decision()) :: boolean()
  def blocking?(%{required: true}), do: Config.settings!().evidence.review_gate == "blocking"
  def blocking?(_decision), do: false

  @spec next_attempt(String.t() | nil) :: pos_integer()
  def next_attempt(run_id) when is_binary(run_id) do
    run_id
    |> SymphonyElixir.Storage.evidence_reviews_for_run()
    |> length()
    |> Kernel.+(1)
  end

  def next_attempt(_run_id), do: 1

  @spec max_attempts() :: pos_integer()
  def max_attempts do
    Config.settings!().evidence.max_review_attempts
  end

  @spec load_bundle(Path.t(), decision()) :: {:ok, bundle()} | {:error, term()}
  def load_bundle(workspace, %{required: true} = decision) when is_binary(workspace) do
    with {:ok, workspace_root} <- PathSafety.canonicalize(workspace),
         {:ok, evidence_path} <- evidence_path(decision),
         {:ok, canonical_path} <- canonical_evidence_path(workspace_root, workspace, evidence_path),
         {:ok, manifest_path, bundle_path} <- manifest_and_bundle_paths(canonical_path),
         {:ok, body} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(body),
         {:ok, manifest} <- Manifest.validate(manifest, workspace_root, bundle_path) do
      {:ok, %{manifest_path: manifest_path, bundle_path: bundle_path, manifest: manifest}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:evidence_bundle_load_failed, Exception.message(error)}}
  end

  def load_bundle(_workspace, _decision), do: {:error, :evidence_not_required}

  @spec review_bundle(Path.t(), Issue.t(), Handoff.t(), bundle(), keyword()) ::
          {:ok, review()} | {:error, term()}
  def review_bundle(workspace, %Issue{} = issue, handoff, bundle, opts \\ []) when is_binary(workspace) do
    review_dir = Path.join(workspace, @review_artifact_dir)
    output_path = Path.join(review_dir, "review-#{System.unique_integer([:positive])}.json")

    with :ok <- File.mkdir_p(review_dir),
         {:ok, collector} <- Agent.start_link(fn -> [] end) do
      try do
        prompt = review_prompt(issue, handoff, bundle, output_path)

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
          {:ok, turn} ->
            parse_review_result(output_path, messages, turn)

          {:error, reason} ->
            {:error, reason}
        end
      after
        Agent.stop(collector)
      end
    end
  end

  @spec feedback_markdown(review() | map() | term(), term()) :: String.t()
  def feedback_markdown(review, reason) do
    summary =
      case review do
        %{summary: summary} when is_binary(summary) and summary != "" -> summary
        %{"summary" => summary} when is_binary(summary) and summary != "" -> summary
        _ -> inspect(reason)
      end

    feedback =
      case review do
        %{feedback: feedback} -> feedback
        %{"feedback" => feedback} -> feedback
        _ -> %{}
      end

    """
    # Symphony Evidence Review

    The PR-ready handoff did not pass the evidence gate.

    Summary:
    #{summary}

    Required next action:
    - Address the review feedback, update or regenerate the evidence bundle when needed, then write a fresh `.symphony/handoff.json`.

    Raw feedback:
    ```json
    #{Jason.encode!(feedback, pretty: true)}
    ```
    """
  end

  defp required(evidence, reason) do
    %{
      required: true,
      status: "required",
      reason: reason,
      bundle_path: Map.get(evidence, :bundle_path),
      manifest_path: Map.get(evidence, :manifest_path)
    }
  end

  defp not_required(status, reason), do: %{required: false, status: status, reason: reason}

  defp executor_decision(%{required: true} = evidence) do
    required(evidence, Map.get(evidence, :reason) || "executor declared evidence required")
  end

  defp executor_decision(%{required: false} = evidence) do
    not_required("not_required", Map.get(evidence, :reason) || "executor declared evidence unnecessary")
  end

  defp executor_decision(_evidence), do: not_required("not_required", "executor did not declare evidence required")

  defp issue_labels(%Issue{labels: labels}) when is_list(labels) do
    Enum.map(labels, &normalize_label/1)
  end

  defp issue_labels(_issue), do: []

  defp matching_label(labels, configured_labels) do
    configured_labels
    |> List.wrap()
    |> Enum.map(&normalize_label/1)
    |> Enum.any?(&(&1 in labels))
  end

  defp normalize_label(label) do
    label
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp evidence_path(%{manifest_path: path}) when is_binary(path) and path != "", do: {:ok, path}
  defp evidence_path(%{bundle_path: path}) when is_binary(path) and path != "", do: {:ok, path}
  defp evidence_path(_decision), do: {:error, :missing_evidence_bundle_path}

  defp canonical_evidence_path(workspace_root, workspace, evidence_path) do
    expanded_path =
      case Path.type(evidence_path) do
        :absolute -> Path.expand(evidence_path)
        _ -> Path.expand(evidence_path, workspace)
      end

    with {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path) do
      workspace_prefix = workspace_root <> "/"

      if canonical_path == workspace_root or String.starts_with?(canonical_path <> "/", workspace_prefix) do
        {:ok, canonical_path}
      else
        {:error, {:evidence_path_escape, canonical_path, workspace_root}}
      end
    end
  end

  defp manifest_and_bundle_paths(path) do
    cond do
      File.dir?(path) ->
        manifest_path = Path.join(path, "manifest.json")

        if File.regular?(manifest_path) do
          {:ok, manifest_path, path}
        else
          {:error, {:missing_evidence_manifest, manifest_path}}
        end

      File.regular?(path) ->
        {:ok, path, Path.dirname(path)}

      true ->
        {:error, {:missing_evidence_bundle, path}}
    end
  end

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

  defp review_prompt(%Issue{} = issue, handoff, bundle, output_path) do
    """
    You are the Symphony review agent for a PR-ready handoff. You are reviewing evidence, not implementing.

    Issue:
    - Identifier: #{issue.identifier || issue.id}
    - Title: #{issue.title}
    - State: #{issue.state}
    - URL: #{issue.url || "unknown"}
    - PR URL: #{issue.pr_url || Map.get(handoff, :pr_url) || "unknown"}

    Evidence bundle:
    - Manifest path: #{bundle.manifest_path}
    - Bundle path: #{bundle.bundle_path}

    Manifest:
    ```json
    #{Jason.encode!(bundle.manifest, pretty: true)}
    ```

    Review contract:
    - Inspect the issue, PR/diff/checks if available, repository state, and the evidence manifest.
    - Judge whether the evidence supports the executor's handoff and acceptance criteria.
    - Do not edit repository source files. The only file you may write is the review JSON below.
    - If the evidence is missing, stale, irrelevant, or contradicts the plan, fail the gate with concrete feedback.
    - If it is sufficient for human review, pass the gate.

    Write exactly this JSON shape to #{output_path}, and also make it your final answer:
    {
      "verdict": "pass" | "request_changes" | "needs_input",
      "summary": "short human-readable judgment",
      "feedback": {
        "concerns": ["specific concern"],
        "required_actions": ["specific action"]
      }
    }
    """
  end

  defp review_issue(%Issue{} = issue) do
    %{issue | identifier: "#{issue.identifier || issue.id}-evidence-review", title: "Evidence review: #{issue.title}"}
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
          {:ok, review} ->
            {:ok, Map.merge(review, %{output_path: output_path, session_id: turn[:session_id], thread_id: turn[:thread_id]})}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_review_file(output_path) do
    with true <- File.regular?(output_path),
         {:ok, body} <- File.read(output_path),
         {:ok, review} <- parse_review_text(body) do
      {:ok, review}
    else
      false -> {:error, :missing_review_output}
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

  defp parse_review_text(_text), do: {:error, :missing_review_text}

  defp normalize_review(%{} = review) do
    verdict =
      review
      |> Map.get("verdict", Map.get(review, :verdict))
      |> to_string()
      |> String.trim()
      |> String.downcase()

    verdict = AutonomousReview.normalize_verdict(verdict)

    if verdict in ["pass", "request_changes", "needs_input"] do
      {:ok,
       %{
         verdict: verdict,
         summary: string_value(review, "summary") || verdict,
         feedback: Map.get(review, "feedback") || Map.get(review, :feedback) || %{}
       }}
    else
      {:error, {:invalid_evidence_review_verdict, verdict}}
    end
  end

  defp normalize_review(_review), do: {:error, :evidence_review_not_object}

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
      trimmed == "" ->
        {:error, :empty_evidence_review_text}

      String.starts_with?(trimmed, "{") ->
        {:ok, trimmed}

      match = Regex.run(~r/```(?:json)?\s*({[\s\S]*?})\s*```/, trimmed) ->
        {:ok, Enum.at(match, 1)}

      match = Regex.run(~r/({[\s\S]*})/, trimmed) ->
        {:ok, Enum.at(match, 1)}

      true ->
        {:error, :missing_evidence_review_json}
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
