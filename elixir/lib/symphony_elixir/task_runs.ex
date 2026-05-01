defmodule SymphonyElixir.TaskRuns do
  @moduledoc """
  First-class task planning lane for native goals and GitHub issue plans.
  """

  alias SymphonyElixir.{CodingAgent, Config, GitHub, Linear.Issue, Storage, Workspace}

  @planning_statuses ["needs_input", "ready_for_approval", "inconclusive"]

  @type task_run :: map()
  @type create_goal_attrs :: %{
          optional(:repo_id) => String.t(),
          optional(:repo_hint) => String.t(),
          optional(:labels) => [String.t()],
          optional(:creator_notes) => String.t(),
          required(:goal_text) => String.t()
        }

  @spec create_goal(create_goal_attrs()) :: {:ok, task_run()} | {:error, term()}
  def create_goal(attrs) when is_map(attrs) do
    labels = normalize_strings(Map.get(attrs, :labels) || Map.get(attrs, "labels") || [])
    goal_text = Map.get(attrs, :goal_text) || Map.get(attrs, "goal_text")

    with :ok <- require_text(goal_text, :goal_text),
         {:ok, id} <-
           Storage.create_task_run(%{
             source: "goal",
             repo_id: Map.get(attrs, :repo_id) || Map.get(attrs, "repo_id"),
             repo_hint: Map.get(attrs, :repo_hint) || Map.get(attrs, "repo_hint"),
             labels: labels,
             creator_notes: Map.get(attrs, :creator_notes) || Map.get(attrs, "creator_notes"),
             goal_text: goal_text,
             state: "planning_queued",
             current_step: "planning queued",
             agent_profiles: resolved_profiles(%{labels: labels, repo_id: Map.get(attrs, :repo_id) || Map.get(attrs, "repo_id")})
           }) do
      _ = Storage.append_task_event(id, "info", "goal intake queued", %{labels: labels})
      {:ok, Storage.get_task_run(id)}
    end
  end

  @spec create_for_issue(Issue.t()) :: {:ok, task_run()} | {:error, term()}
  def create_for_issue(%Issue{} = issue) do
    with {:ok, id} <-
           Storage.create_task_run(%{
             source: "github_issue",
             repo_id: issue.repo_id,
             issue_number: issue.number,
             issue_identifier: issue.identifier,
             issue_title: issue.title,
             issue_url: issue.url,
             labels: issue.labels,
             state: "planning_queued",
             current_step: "planning queued",
             agent_profiles: resolved_profiles(issue)
           }) do
      _ = Storage.append_task_event(id, "info", "GitHub issue planning queued", %{issue_identifier: issue.identifier})
      {:ok, Storage.get_task_run(id)}
    end
  end

  @spec run_planning(String.t(), keyword()) :: {:ok, task_run()} | {:error, term()}
  def run_planning(task_run_id, opts \\ []) when is_binary(task_run_id) do
    with %{} = task_run <- Storage.get_task_run(task_run_id),
         :ok <- require_state(task_run, ["planning_queued", "planning_agent"]),
         {:ok, workspace} <- planning_workspace(task_run),
         issue <- issue_for_task(task_run),
         profile <- Config.agent_profile_for_issue(issue, :planner),
         :ok <- mark_planning_started(task_run_id, issue),
         _ <- Storage.append_task_event(task_run_id, "info", "planning started", %{profile: profile}),
         {:ok, result} <-
           CodingAgent.run(:planner, workspace, planning_prompt(task_run), issue, planning_opts(opts, profile)),
         {:ok, manifest} <- result |> agent_result_text() |> parse_planning_manifest(),
         :ok <- persist_planning_manifest(task_run_id, manifest) do
      {:ok, Storage.get_task_run(task_run_id)}
    else
      nil -> {:error, :task_run_not_found}
      {:error, reason} = error -> maybe_mark_planning_failed(task_run_id, reason, error)
    end
  end

  @spec submit_answers(String.t(), [map()]) :: {:ok, task_run()} | {:error, term()}
  def submit_answers(task_run_id, answers) when is_binary(task_run_id) and is_list(answers) do
    with %{} = task_run <- Storage.get_task_run(task_run_id),
         :ok <- require_state(task_run, ["awaiting_input"]),
         merged <- merge_answers(Map.get(task_run, "answers") || [], answers),
         :ok <-
           Storage.update_task_run(task_run_id, %{
             answers: merged,
             state: "planning_queued",
             outcome: nil,
             current_step: "answers received; planning queued",
             error: nil
           }) do
      _ = Storage.append_task_event(task_run_id, "info", "answers submitted", %{answers: merged})
      {:ok, Storage.get_task_run(task_run_id)}
    else
      nil -> {:error, :task_run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rerun_plan(String.t(), String.t() | nil) :: {:ok, task_run()} | {:error, term()}
  def rerun_plan(task_run_id, note \\ nil) when is_binary(task_run_id) do
    with %{} = task_run <- Storage.get_task_run(task_run_id),
         :ok <-
           Storage.update_task_run(task_run_id, %{
             state: "planning_queued",
             outcome: nil,
             current_step: "replanning queued",
             creator_notes: append_replan_note(Map.get(task_run, "creator_notes"), note),
             error: nil
           }) do
      _ = Storage.append_task_event(task_run_id, "info", "replanning requested", %{note: note})
      {:ok, Storage.get_task_run(task_run_id)}
    else
      nil -> {:error, :task_run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec approve_plan(String.t(), keyword()) :: {:ok, task_run()} | {:error, term()}
  def approve_plan(task_run_id, opts \\ []) when is_binary(task_run_id) do
    github = Keyword.get(opts, :github_client, GitHub.Client)

    with %{} = task_run <- Storage.get_task_run(task_run_id),
         :ok <- require_state(task_run, ["awaiting_approval"]),
         %{} = manifest <- Map.get(task_run, "planning_manifest"),
         {:ok, linked} <- ensure_github_issue(task_run, manifest, github),
         :ok <- publish_approved_plan(linked, manifest, github),
         :ok <-
           Storage.update_task_run(task_run_id, %{
             state: "approved",
             outcome: nil,
             approved_plan: manifest,
             repo_id: Map.get(linked, "repo_id"),
             issue_number: Map.get(linked, "issue_number"),
             issue_identifier: Map.get(linked, "issue_identifier"),
             issue_title: Map.get(linked, "issue_title"),
             issue_url: Map.get(linked, "issue_url"),
             current_step: "plan approved; GitHub issue queued for execution",
             error: nil
           }) do
      _ = Storage.append_task_event(task_run_id, "info", "plan approved", %{issue: linked})
      {:ok, Storage.get_task_run(task_run_id)}
    else
      nil -> {:error, :task_run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec sync_issue_execution(Issue.t(), String.t() | nil) :: :ok | {:error, term()}
  def sync_issue_execution(%Issue{} = issue, run_id \\ nil) do
    with %{} = task_run <- Storage.get_task_run_by_issue(issue.repo_id, issue.number),
         run <- run_for_sync(run_id),
         review <- latest_review_for_sync(run, issue),
         :ok <- Storage.update_task_run(task_run["id"], execution_sync_attrs(issue, run, review)) do
      Storage.append_task_event(task_run["id"], "info", "execution synced from issue run", %{
        issue_identifier: issue.identifier,
        run_id: map_value(run, "id"),
        pr_url: pr_url_for_sync(issue, run),
        review_verdict: map_value(review, "verdict")
      })
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_planning_manifest(task_run_id, manifest) do
    attrs =
      case manifest["status"] do
        "needs_input" ->
          %{
            state: "awaiting_input",
            outcome: "needs_input",
            planning_manifest: manifest,
            questions: manifest["questions"] || [],
            current_step: "waiting for answers"
          }

        "ready_for_approval" ->
          %{
            state: "awaiting_approval",
            outcome: nil,
            planning_manifest: manifest,
            questions: manifest["questions"] || [],
            current_step: "waiting for plan approval"
          }

        _status ->
          %{
            state: "failed",
            outcome: "action_required",
            planning_manifest: manifest,
            current_step: "planning inconclusive",
            error: manifest["summary"] || "Planning was inconclusive."
          }
      end

    with :ok <- Storage.update_task_run(task_run_id, attrs) do
      Storage.append_task_event(task_run_id, "info", "planning manifest recorded", %{status: manifest["status"]})
    end
  end

  defp mark_planning_started(task_run_id, issue) do
    Storage.update_task_run(task_run_id, %{
      state: "planning_agent",
      current_step: "running planning pass",
      agent_profiles: resolved_profiles(issue)
    })
  end

  defp planning_opts(opts, profile) do
    Keyword.merge(opts,
      agent_profile: profile,
      agent_provider: profile.provider
    )
  end

  defp append_replan_note(existing, note) when is_binary(note) do
    trimmed = String.trim(note)

    cond do
      trimmed == "" -> existing
      is_binary(existing) and String.trim(existing) != "" -> existing <> "\n\nReplan note: " <> trimmed
      true -> "Replan note: " <> trimmed
    end
  end

  defp append_replan_note(existing, _note), do: existing

  defp ensure_github_issue(%{"issue_number" => number} = task_run, _manifest, _github) when is_integer(number) do
    {:ok, issue_link(task_run)}
  end

  defp ensure_github_issue(task_run, manifest, github) do
    repo_id = Map.get(task_run, "repo_id") || Map.get(task_run, "repo_hint")
    title = github_issue_title(task_run, manifest)
    body = github_issue_body(task_run, manifest)
    labels = github_issue_labels(task_run)

    with :ok <- require_text(repo_id, :repo_id),
         {:ok, issue} <- github.create_issue(repo_id, title, body, labels) do
      {:ok,
       %{
         "repo_id" => repo_id,
         "issue_number" => Map.get(issue, "number"),
         "issue_identifier" => "#{repo_id}##{Map.get(issue, "number")}",
         "issue_title" => Map.get(issue, "title") || title,
         "issue_url" => Map.get(issue, "html_url") || Map.get(issue, "url")
       }}
    end
  end

  defp publish_approved_plan(%{"issue_identifier" => issue_identifier}, manifest, github)
       when is_binary(issue_identifier) do
    github.publish_approved_plan(issue_identifier, manifest)
  end

  defp publish_approved_plan(_linked, _manifest, _github), do: {:error, :missing_issue_identifier}

  defp github_issue_title(%{"goal_text" => goal_text}, _manifest) when is_binary(goal_text) do
    goal_text
    |> String.split("\n")
    |> List.first()
    |> String.slice(0, 120)
  end

  defp github_issue_title(_task_run, %{"summary" => summary}) when is_binary(summary), do: String.slice(summary, 0, 120)
  defp github_issue_title(_task_run, _manifest), do: "Symphony planned task"

  defp github_issue_body(task_run, manifest) do
    """
    #{Map.get(task_run, "goal_text") || Map.get(task_run, "issue_title") || "Approved Symphony task."}

    ## Approved Plan

    #{manifest["plan_markdown"] || manifest["summary"] || ""}

    ## Acceptance Criteria

    #{bullet_lines(manifest["acceptance_criteria"])}

    ## Test Plan

    #{bullet_lines(manifest["test_plan"])}
    """
    |> String.trim()
  end

  defp github_issue_labels(task_run) do
    repo_labels =
      case Config.repo_by_id(Map.get(task_run, "repo_id") || Map.get(task_run, "repo_hint") || "") do
        %{labels: labels} when is_map(labels) ->
          [Map.get(labels, "managed") || Map.get(labels, :managed), Map.get(labels, "queued") || Map.get(labels, :queued)]

        _ ->
          ["symphony", "agent-ready"]
      end

    task_run
    |> Map.get("labels", [])
    |> List.wrap()
    |> Enum.concat(repo_labels)
    |> normalize_strings()
    |> Enum.uniq()
  end

  defp issue_link(task_run) do
    %{
      "repo_id" => Map.get(task_run, "repo_id"),
      "issue_number" => Map.get(task_run, "issue_number"),
      "issue_identifier" => Map.get(task_run, "issue_identifier"),
      "issue_title" => Map.get(task_run, "issue_title"),
      "issue_url" => Map.get(task_run, "issue_url")
    }
  end

  defp planning_prompt(task_run) do
    """
    You are the Symphony planning agent.

    Work read-only. Do not edit repository files, create branches, or contact GitHub.

    Produce either concise questions or an approvable implementation plan.

    Goal:
    #{Map.get(task_run, "goal_text") || Map.get(task_run, "issue_title") || "(missing)"}

    Creator notes:
    #{Map.get(task_run, "creator_notes") || "(none)"}

    Answers so far:
    #{answers_text(Map.get(task_run, "answers") || [])}

    Return only JSON with:
    - status: needs_input, ready_for_approval, or inconclusive
    - summary
    - questions: array of {id, question, why}
    - plan_markdown
    - acceptance_criteria
    - test_plan
    - risks
    - out_of_scope
    - agent_profiles: optional planner/executor/reviewer profile suggestions
    """
    |> String.trim()
  end

  defp issue_for_task(task_run) do
    %Issue{
      id: Map.get(task_run, "issue_identifier") || Map.get(task_run, "id"),
      identifier: Map.get(task_run, "issue_identifier") || Map.get(task_run, "id"),
      title: Map.get(task_run, "issue_title") || github_issue_title(task_run, %{}),
      description: Map.get(task_run, "goal_text"),
      state: Map.get(task_run, "state"),
      repo_id: Map.get(task_run, "repo_id") || Map.get(task_run, "repo_hint"),
      number: Map.get(task_run, "issue_number"),
      labels: Map.get(task_run, "labels") || []
    }
  end

  defp resolved_profiles(issue) do
    %{
      planner: Config.agent_profile_for_issue(issue, :planner),
      executor: Config.agent_profile_for_issue(issue, :executor),
      reviewer: Config.agent_profile_for_issue(issue, :reviewer)
    }
  end

  defp parse_planning_manifest(text) when is_binary(text) do
    text
    |> extract_json_text()
    |> Jason.decode()
    |> case do
      {:ok, %{} = manifest} -> normalize_planning_manifest(manifest)
      {:ok, _other} -> {:error, :planning_manifest_not_object}
      {:error, _reason} -> {:error, :invalid_planning_manifest_json}
    end
  end

  defp normalize_planning_manifest(manifest) do
    manifest = stringify_keys(manifest)
    status = Map.get(manifest, "status")

    if Enum.member?(@planning_statuses, status) do
      {:ok,
       %{
         "status" => status,
         "summary" => string_value(Map.get(manifest, "summary")),
         "questions" => normalize_questions(Map.get(manifest, "questions")),
         "plan_markdown" => string_value(Map.get(manifest, "plan_markdown")),
         "acceptance_criteria" => normalize_strings(Map.get(manifest, "acceptance_criteria")),
         "test_plan" => normalize_strings(Map.get(manifest, "test_plan")),
         "risks" => normalize_strings(Map.get(manifest, "risks")),
         "out_of_scope" => normalize_strings(Map.get(manifest, "out_of_scope")),
         "agent_profiles" => stringify_keys(Map.get(manifest, "agent_profiles") || %{})
       }}
    else
      {:error, {:invalid_planning_status, status}}
    end
  end

  defp agent_result_text(%{result: result}), do: agent_result_text(result)
  defp agent_result_text(%{"result" => result}) when is_binary(result), do: result
  defp agent_result_text(%{"text" => text}) when is_binary(text), do: text
  defp agent_result_text(%{"final" => text}) when is_binary(text), do: text
  defp agent_result_text(%{text: text}) when is_binary(text), do: text
  defp agent_result_text(text) when is_binary(text), do: text
  defp agent_result_text(result), do: Jason.encode!(result)

  defp extract_json_text(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "```") do
      trimmed
      |> String.replace_prefix("```json", "")
      |> String.replace_prefix("```", "")
      |> String.replace_suffix("```", "")
      |> String.trim()
    else
      trimmed
    end
  end

  defp normalize_questions(questions) when is_list(questions) do
    Enum.flat_map(questions, fn
      %{} = question ->
        [
          %{
            "id" => string_value(Map.get(question, "id") || Map.get(question, :id)),
            "question" => string_value(Map.get(question, "question") || Map.get(question, :question)),
            "why" => string_value(Map.get(question, "why") || Map.get(question, :why))
          }
        ]

      _other ->
        []
    end)
  end

  defp normalize_questions(_questions), do: []

  defp merge_answers(existing, answers) do
    keyed =
      existing
      |> List.wrap()
      |> Enum.concat(answers)
      |> Enum.reduce(%{}, fn answer, acc ->
        id = Map.get(answer, "question_id") || Map.get(answer, :question_id)
        value = Map.get(answer, "answer") || Map.get(answer, :answer)

        if is_binary(id) and is_binary(value) do
          Map.put(acc, id, %{"question_id" => id, "answer" => value})
        else
          acc
        end
      end)

    Map.values(keyed)
  end

  defp require_state(task_run, allowed_states) do
    if Enum.member?(allowed_states, Map.get(task_run, "state")) do
      :ok
    else
      {:error, {:invalid_task_run_state, Map.get(task_run, "state")}}
    end
  end

  defp require_text(value, field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, {:missing_required_field, field}}, else: :ok
  end

  defp require_text(_value, field), do: {:error, {:missing_required_field, field}}

  defp maybe_mark_planning_failed(task_run_id, reason, error) do
    if Storage.get_task_run(task_run_id) do
      _ =
        Storage.update_task_run(task_run_id, %{
          state: "failed",
          outcome: "action_required",
          current_step: "planning failed",
          error: inspect(reason)
        })

      _ = Storage.append_task_event(task_run_id, "error", "planning failed", %{reason: inspect(reason)})
    end

    error
  end

  defp execution_sync_attrs(%Issue{} = issue, run, review) do
    pr_url = pr_url_for_sync(issue, run)

    %{
      state: task_state_for_execution(issue, run, review),
      outcome: task_outcome_for_execution(issue, run, review),
      implementation_manifest: implementation_manifest(issue, run, pr_url),
      review_manifest: review_manifest(review),
      pr_url: pr_url,
      pr_number: issue.pr_number || pr_number_from_url(pr_url),
      current_step: current_step_for_execution(issue, run, review),
      error: nil
    }
  end

  defp implementation_manifest(%Issue{} = issue, run, pr_url) do
    %{
      "status" => map_value(run, "state") || issue.state,
      "issue_identifier" => issue.identifier,
      "run_id" => map_value(run, "id"),
      "workspace_path" => map_value(run, "workspace_path"),
      "thread_id" => map_value(run, "thread_id"),
      "pr_url" => pr_url,
      "pr_state" => map_value(run, "pr_state") || issue.pr_state,
      "check_state" => map_value(run, "check_state") || issue.check_state,
      "review_state" => map_value(run, "review_state") || issue.review_state
    }
    |> reject_nil_values()
  end

  defp review_manifest(nil), do: nil

  defp review_manifest(review) when is_map(review) do
    %{
      "verdict" => map_value(review, "verdict"),
      "summary" => map_value(review, "summary"),
      "reviewer_kind" => map_value(review, "reviewer_kind"),
      "check_conclusion" => map_value(review, "check_conclusion"),
      "output_path" => map_value(review, "output_path")
    }
    |> reject_nil_values()
  end

  defp task_state_for_execution(%Issue{} = issue, run, review) do
    cond do
      map_value(run, "state") == "failed" -> "failed"
      map_value(review, "verdict") == "pass" and normalized_issue_state(issue) == "human-review" -> "completed"
      pr_url_for_sync(issue, run) not in [nil, ""] -> "pr_reviewing"
      true -> "implementing"
    end
  end

  defp task_outcome_for_execution(%Issue{} = issue, run, review) do
    cond do
      map_value(run, "state") == "failed" -> "failed"
      map_value(review, "verdict") == "pass" and normalized_issue_state(issue) == "human-review" -> "pr_ready_for_human_review"
      map_value(review, "verdict") in ["request_changes", "needs_input"] -> map_value(review, "verdict")
      true -> nil
    end
  end

  defp current_step_for_execution(%Issue{} = issue, run, review) do
    cond do
      map_value(run, "state") == "failed" -> "implementation failed"
      map_value(review, "verdict") == "pass" and normalized_issue_state(issue) == "human-review" -> "PR opened and autonomous review passed"
      pr_url_for_sync(issue, run) not in [nil, ""] -> "PR opened; autonomous review in progress"
      true -> "implementation in progress"
    end
  end

  defp run_for_sync(run_id) when is_binary(run_id), do: Storage.get_run(run_id) || %{}
  defp run_for_sync(_run_id), do: %{}

  defp latest_review_for_sync(%{"autonomous_reviews" => reviews}, _issue) when is_list(reviews) do
    List.first(reviews)
  end

  defp latest_review_for_sync(_run, %Issue{} = issue) do
    Storage.list_autonomous_reviews(250)
    |> Enum.find(fn review ->
      map_value(review, "repo_id") == issue.repo_id and map_value(review, "issue_number") == issue.number
    end)
  end

  defp pr_url_for_sync(%Issue{} = issue, run), do: issue.pr_url || map_value(run, "pr_url")

  defp normalized_issue_state(%Issue{state: state}) when is_binary(state) do
    state
    |> String.downcase()
    |> String.replace("_", "-")
    |> String.replace(" ", "-")
  end

  defp normalized_issue_state(_issue), do: nil

  defp pr_number_from_url(pr_url) when is_binary(pr_url) do
    case Regex.run(~r{/pull/(\d+)(?:\z|[/?#])}, pr_url) do
      [_, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp pr_number_from_url(_pr_url), do: nil

  defp map_value(nil, _key), do: nil
  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp planning_workspace(task_run) do
    task_run
    |> issue_for_task()
    |> Workspace.create_for_issue()
  end

  defp answers_text([]), do: "No answers yet."

  defp answers_text(answers) do
    Enum.map_join(answers, "\n", fn answer ->
      "- #{Map.get(answer, "question_id")}: #{Map.get(answer, "answer")}"
    end)
  end

  defp bullet_lines(values) do
    values
    |> normalize_strings()
    |> Enum.map_join("\n", &("- " <> &1))
  end

  defp normalize_strings(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_strings(_values), do: []

  defp stringify_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, to_string(key), stringify_keys(nested))
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp string_value(value) when is_binary(value), do: value
  defp string_value(nil), do: ""
  defp string_value(value), do: to_string(value)
end
