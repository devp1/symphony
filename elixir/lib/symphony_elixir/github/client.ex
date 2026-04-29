defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub Issues client backed by the authenticated `gh` CLI.
  """

  alias SymphonyElixir.{Config, Linear.Issue, Storage}

  @type github_role :: Config.github_role()

  @spec preflight() :: :ok | {:error, term()}
  def preflight do
    with :ok <- gh_auth_preflight() do
      Config.repos()
      |> Enum.reduce_while(:ok, fn repo_config, :ok ->
        case repo_preflight(repo_config) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    Config.settings!().tracker.active_states
    |> fetch_issues_by_states()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, issues} <- fetch_open_issues() do
      states = state_names |> Enum.map(&to_string/1) |> MapSet.new()

      issues
      |> Enum.filter(&MapSet.member?(states, &1.state))
      |> then(&{:ok, &1})
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn
      _issue_id, {:error, reason} ->
        {:halt, {:error, reason}}

      issue_id, {:ok, acc} ->
        case fetch_issue(issue_id) do
          {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_artifact_marker(String.t()) ::
          {:ok, String.t(), term()} | :missing | {:error, term()}
  def fetch_artifact_marker(issue_id) when is_binary(issue_id) do
    {repo_config, issue_number} = repo_and_issue_number(issue_id)

    case gh_api(repo_config, [
           "repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}/comments",
           "-X",
           "GET",
           "-F",
           "per_page=100"
         ]) do
      {:ok, comments} when is_list(comments) ->
        comments
        |> Enum.filter(&codex_workpad_comment?/1)
        |> Enum.max_by(&comment_updated_at_sort_key/1, fn -> nil end)
        |> case do
          nil ->
            :missing

          comment ->
            body = Map.get(comment, "body", "")
            updated_at = Map.get(comment, "updated_at") || Map.get(comment, "created_at")
            {:ok, "github codex workpad updated", {:github_workpad, :erlang.phash2({body, updated_at})}}
        end

      {:ok, _other} ->
        {:error, :github_unexpected_issue_comments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    {repo_config, issue_number} = repo_and_issue_number(issue_id)

    with {:ok, _response} <-
           gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}/comments", "-X", "POST", "-f", "body=#{body}"]) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    {repo_config, issue_number} = repo_and_issue_number(issue_id)

    case state_name do
      "Done" ->
        close_issue(repo_config, issue_number)

      state_name ->
        with :ok <- open_issue(repo_config, issue_number), do: replace_state_label(repo_config, issue_number, state_name)
    end
  end

  @spec upsert_autonomous_review_check(Issue.t(), map()) :: :ok | {:error, term()}
  def upsert_autonomous_review_check(%Issue{} = issue, attrs) when is_map(attrs) do
    repo_config = repo_config_for_issue(issue)
    github_config = Config.settings!().github
    verdict = normalize_review_verdict(Map.get(attrs, :verdict) || Map.get(attrs, "verdict"))
    conclusion = review_check_conclusion(verdict)
    summary = review_summary(attrs, verdict)
    details = review_details(attrs, summary)

    with {:ok, head_sha} <- review_head_sha(issue, attrs),
         {:ok, _response} <-
           gh_api(
             repo_config,
             [
               "repos/#{repo_config.owner}/#{repo_config.name}/check-runs",
               "-X",
               "POST",
               "-H",
               "Accept: application/vnd.github+json",
               "-f",
               "name=#{github_config.review_check_name}",
               "-f",
               "head_sha=#{head_sha}",
               "-f",
               "status=completed",
               "-f",
               "conclusion=#{conclusion}",
               "-f",
               "output[title]=Symphony autonomous review: #{verdict}",
               "-f",
               "output[summary]=#{summary}",
               "-f",
               "output[text]=#{details}"
             ],
             :reviewer
           ) do
      :ok
    end
  end

  @spec submit_autonomous_pr_review(Issue.t(), map()) :: :ok | {:error, term()}
  def submit_autonomous_pr_review(%Issue{} = issue, attrs) when is_map(attrs) do
    repo_config = repo_config_for_issue(issue)
    verdict = normalize_review_verdict(Map.get(attrs, :verdict) || Map.get(attrs, "verdict"))

    with {:ok, event} <- pull_request_review_event(verdict),
         :ok <- ensure_review_approval_allowed(event),
         {:ok, pr_number} <- pull_request_number(issue),
         {:ok, _response} <-
           gh_api(
             repo_config,
             [
               "repos/#{repo_config.owner}/#{repo_config.name}/pulls/#{pr_number}/reviews",
               "-X",
               "POST",
               "-H",
               "Accept: application/vnd.github+json",
               "-f",
               "event=#{event}",
               "-f",
               "body=#{review_details(attrs, review_summary(attrs, verdict))}"
             ],
             :reviewer
           ) do
      :ok
    end
  end

  @doc false
  @spec command_env_for_test(github_role()) :: [{String.t(), String.t()}]
  def command_env_for_test(role), do: command_env(role)

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue), do: normalize_issue(issue)

  defp fetch_open_issues do
    Config.repos()
    |> Enum.reduce_while({:ok, []}, fn repo_config, {:ok, acc} ->
      case fetch_open_issues(repo_config) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_open_issues(repo_config) do
    labels = repo_labels(repo_config)

    gh_api(repo_config, [
      "repos/#{repo_config.owner}/#{repo_config.name}/issues",
      "-X",
      "GET",
      "-f",
      "state=open",
      "-f",
      "labels=#{labels["managed"]}",
      "-F",
      "per_page=100"
    ])
    |> case do
      {:ok, issues} when is_list(issues) ->
        issues
        |> Enum.reject(&Map.has_key?(&1, "pull_request"))
        |> Enum.map(&normalize_issue(repo_config, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&(&1.created_at || ~U[1970-01-01 00:00:00Z]), DateTime)
        |> tap(&persist_repo_snapshot(repo_config, &1))
        |> then(&{:ok, &1})

      {:ok, _other} ->
        {:error, :github_unexpected_issue_list}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue(issue_id) do
    {repo_config, issue_number} = repo_and_issue_number(issue_id)

    case gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}"]) do
      {:ok, issue} when is_map(issue) -> {:ok, normalize_issue(repo_config, issue)}
      {:ok, _other} -> {:error, :github_unexpected_issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_issue(repo_config, issue_number) do
    with {:ok, _response} <-
           gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}", "-X", "PATCH", "-f", "state=closed"]) do
      :ok
    end
  end

  defp open_issue(repo_config, issue_number) do
    with {:ok, _response} <-
           gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}", "-X", "PATCH", "-f", "state=open"]) do
      :ok
    end
  end

  defp replace_state_label(repo_config, issue_number, state_name) do
    labels = repo_labels(repo_config)

    state_labels =
      repo_config
      |> state_label_map()
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(state_labels, fn label ->
      gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}/labels/#{label}", "-X", "DELETE", "--silent"])
    end)

    with :ok <- add_label(repo_config, issue_number, labels["managed"]) do
      case Map.fetch(state_label_map(repo_config), state_name) do
        {:ok, label} -> add_label(repo_config, issue_number, label)
        :error -> :ok
      end
    end
  end

  defp add_label(_repo_config, _issue_number, nil), do: :ok

  defp add_label(repo_config, issue_number, label) do
    with {:ok, _response} <-
           gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}/labels", "-X", "POST", "-f", "labels[]=#{label}"]) do
      :ok
    end
  end

  defp normalize_issue(repo_config, %{"number" => number, "title" => title} = issue) do
    labels = label_names(issue)
    repo_id = repo_config.id
    pr_metadata = best_effort_pr_metadata(repo_config, number)

    struct!(
      Issue,
      Map.merge(
        %{
          id: normalized_issue_id(repo_id, number),
          identifier: normalized_issue_identifier(repo_id, number),
          title: title,
          description: Map.get(issue, "body"),
          priority: nil,
          state: issue_state(repo_config, issue, labels),
          branch_name: nil,
          url: Map.get(issue, "html_url"),
          assignee_id: assignee_login(issue),
          repo_id: repo_id,
          repo_owner: repo_config.owner,
          repo_name: repo_config.name,
          number: number,
          labels: labels,
          assigned_to_worker: true,
          created_at: parse_datetime(Map.get(issue, "created_at")),
          updated_at: parse_datetime(Map.get(issue, "updated_at"))
        },
        pr_metadata
      )
    )
  end

  defp normalize_issue(%{"number" => _number, "title" => _title} = issue), do: normalize_issue(primary_repo!(), issue)
  defp normalize_issue(_issue), do: nil

  defp issue_state(repo_config, %{"state" => "closed"}, _labels) do
    _ = repo_config
    "Done"
  end

  defp issue_state(repo_config, _issue, labels) do
    label_map = repo_labels(repo_config)

    cond do
      label_map["merging"] in labels -> "Merging"
      label_map["needs_input"] in labels -> "Needs Input"
      label_map["blocked"] in labels -> "Blocked"
      label_map["human_review"] in labels -> "Human Review"
      label_map["rework"] in labels -> "Rework"
      label_map["running"] in labels -> "In Progress"
      label_map["queued"] in labels -> "Todo"
      true -> "Backlog"
    end
  end

  defp label_names(%{"labels" => labels}) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      _label -> []
    end)
  end

  defp label_names(_issue), do: []

  defp codex_workpad_comment?(%{"body" => body}) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?("## Codex Workpad")
  end

  defp codex_workpad_comment?(_comment), do: false

  defp comment_updated_at_sort_key(comment) when is_map(comment) do
    Map.get(comment, "updated_at") || Map.get(comment, "created_at") || ""
  end

  defp best_effort_pr_metadata(repo_config, issue_number) do
    if github_repo_configured?(repo_config) and is_integer(issue_number) do
      with {:ok, pr_number} <- linked_pr_number(repo_config, issue_number),
           {:ok, metadata} <- fetch_pr_metadata(repo_config, pr_number) do
        metadata
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp github_repo_configured?(repo_config) do
    is_binary(Map.get(repo_config, :owner)) and String.trim(Map.get(repo_config, :owner)) != "" and
      is_binary(Map.get(repo_config, :name)) and String.trim(Map.get(repo_config, :name)) != ""
  end

  defp linked_pr_number(repo_config, issue_number) do
    case linked_pr_number_from_issue_view(repo_config, issue_number) do
      {:ok, number} -> {:ok, number}
      _missing_or_error -> linked_pr_number_from_timeline(repo_config, issue_number)
    end
  end

  defp linked_pr_number_from_issue_view(repo_config, issue_number) do
    case gh_json(repo_config, [
           "issue",
           "view",
           Integer.to_string(issue_number),
           "--repo",
           "#{repo_config.owner}/#{repo_config.name}",
           "--json",
           "closedByPullRequestsReferences"
         ]) do
      {:ok, issue} when is_map(issue) ->
        issue
        |> Map.get("closedByPullRequestsReferences")
        |> pr_number_from_references()

      {:ok, _other} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp linked_pr_number_from_timeline(repo_config, issue_number) do
    case gh_api(repo_config, [
           "repos/#{repo_config.owner}/#{repo_config.name}/issues/#{issue_number}/timeline",
           "-H",
           "Accept: application/vnd.github+json",
           "-F",
           "per_page=100"
         ]) do
      {:ok, events} when is_list(events) ->
        events
        |> Enum.flat_map(&timeline_pr_number/1)
        |> Enum.uniq()
        |> List.last()
        |> case do
          number when is_integer(number) -> {:ok, number}
          _ -> :missing
        end

      {:ok, _other} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pr_number_from_references(references) when is_list(references) do
    references
    |> Enum.flat_map(fn
      %{"number" => number} when is_integer(number) -> [number]
      _reference -> []
    end)
    |> List.last()
    |> case do
      number when is_integer(number) -> {:ok, number}
      _ -> :missing
    end
  end

  defp pr_number_from_references(_references), do: :missing

  defp timeline_pr_number(%{"source" => %{"issue" => %{"number" => number, "pull_request" => %{} = _pull_request}}})
       when is_integer(number),
       do: [number]

  defp timeline_pr_number(%{"subject" => %{"number" => number, "pull_request" => %{} = _pull_request}})
       when is_integer(number),
       do: [number]

  defp timeline_pr_number(_event), do: []

  defp fetch_pr_metadata(repo_config, pr_number) when is_integer(pr_number) do
    case gh_json(repo_config, [
           "pr",
           "view",
           Integer.to_string(pr_number),
           "--repo",
           "#{repo_config.owner}/#{repo_config.name}",
           "--json",
           "url,number,state,headRefOid,statusCheckRollup,reviewDecision"
         ]) do
      {:ok, pr} when is_map(pr) ->
        {:ok,
         %{
           pr_url: Map.get(pr, "url"),
           pr_number: Map.get(pr, "number"),
           pr_state: Map.get(pr, "state"),
           head_sha: Map.get(pr, "headRefOid"),
           check_state: status_check_state(Map.get(pr, "statusCheckRollup")),
           review_state: Map.get(pr, "reviewDecision")
         }}

      {:ok, _other} ->
        {:error, :github_unexpected_pr}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status_check_state(nil), do: nil
  defp status_check_state([]), do: "none"

  defp status_check_state(checks) when is_list(checks) do
    cond do
      Enum.any?(checks, &failing_check?/1) -> "failing"
      Enum.any?(checks, &pending_check?/1) -> "pending"
      true -> "passing"
    end
  end

  defp status_check_state(_checks), do: nil

  defp failing_check?(check) when is_map(check) do
    conclusion = check |> Map.get("conclusion") |> normalize_github_state()
    status = check |> Map.get("status") |> normalize_github_state()

    conclusion in ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"] or
      status in ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"]
  end

  defp failing_check?(_check), do: false

  defp pending_check?(check) when is_map(check) do
    conclusion = check |> Map.get("conclusion") |> normalize_github_state()
    status = check |> Map.get("status") |> normalize_github_state()

    is_nil(conclusion) and status not in ["completed", "success", "neutral", "skipped"]
  end

  defp pending_check?(_check), do: false

  defp normalize_github_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_github_state(_value), do: nil

  defp assignee_login(%{"assignee" => %{"login" => login}}) when is_binary(login), do: login
  defp assignee_login(_issue), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp gh_auth_preflight do
    case run_command(["auth", "status", "-h", "github.com"], :builder) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:github_auth_preflight_failed, status, String.trim(output)}}
    end
  end

  defp repo_preflight(repo_config) do
    required_labels =
      repo_config
      |> repo_labels()
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case gh_api(repo_config, ["repos/#{repo_config.owner}/#{repo_config.name}/labels", "-X", "GET", "-F", "per_page=100"]) do
      {:ok, labels} when is_list(labels) ->
        existing =
          labels
          |> Enum.flat_map(fn
            %{"name" => name} when is_binary(name) -> [name]
            _label -> []
          end)
          |> MapSet.new()

        case Enum.reject(required_labels, &MapSet.member?(existing, &1)) do
          [] -> :ok
          missing -> {:error, {:github_missing_labels, "#{repo_config.owner}/#{repo_config.name}", missing}}
        end

      {:ok, _other} ->
        {:error, {:github_preflight_unexpected_labels, "#{repo_config.owner}/#{repo_config.name}"}}

      {:error, reason} ->
        {:error, {:github_label_preflight_failed, "#{repo_config.owner}/#{repo_config.name}", reason}}
    end
  end

  defp gh_api(repo_config, args, role \\ :builder) when is_list(args) do
    gh_json(repo_config, ["api" | args], role)
  end

  defp gh_json(_repo_config, args, role \\ :builder) when is_list(args) do
    case run_command(args, role) do
      {output, 0} -> Jason.decode(output)
      {output, status} -> {:error, {:gh_api_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:gh_command_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:gh_command_failed, {kind, reason}}}
  end

  defp command_fun do
    Application.get_env(:symphony_elixir, :github_command_fun, fn args, env ->
      System.cmd("gh", args, stderr_to_stdout: true, env: env)
    end)
  end

  defp run_command(args, role) do
    command = command_fun()
    env = command_env(role)

    cond do
      is_function(command, 2) ->
        command.(args, env)

      is_function(command, 1) ->
        command.(args)

      true ->
        System.cmd("gh", args, stderr_to_stdout: true, env: env)
    end
  end

  defp command_env(role) when role in [:builder, :reviewer] do
    case Config.github_token(role) do
      token when is_binary(token) and token != "" -> [{"GH_TOKEN", token}, {"GITHUB_TOKEN", token}]
      _ -> []
    end
  end

  defp primary_repo! do
    Config.primary_repo() || %{id: "github", owner: Config.settings!().tracker.owner, name: Config.settings!().tracker.repo, labels: %{}}
  end

  defp repo_config_for_issue(%Issue{repo_id: repo_id, repo_owner: owner, repo_name: name}) do
    Config.repo_by_id(repo_id || "") ||
      %{id: repo_id || "github", owner: owner || primary_repo!().owner, name: name || primary_repo!().name, labels: %{}}
  end

  defp normalize_review_verdict(verdict) when verdict in [:pass, :request_changes, :needs_input], do: Atom.to_string(verdict)

  defp normalize_review_verdict(verdict) when is_binary(verdict) do
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
      other -> other
    end
  end

  defp normalize_review_verdict(_verdict), do: "needs_input"

  defp review_check_conclusion("pass"), do: "success"
  defp review_check_conclusion("request_changes"), do: "failure"
  defp review_check_conclusion("needs_input"), do: "action_required"
  defp review_check_conclusion(_verdict), do: "action_required"

  defp review_summary(attrs, verdict) do
    Map.get(attrs, :summary) || Map.get(attrs, "summary") || "Autonomous review verdict: #{verdict}"
  end

  defp review_details(attrs, fallback) do
    Map.get(attrs, :details) || Map.get(attrs, "details") || Map.get(attrs, :body) || Map.get(attrs, "body") || fallback
  end

  defp review_head_sha(%Issue{head_sha: head_sha}, attrs) do
    case Map.get(attrs, :head_sha) || Map.get(attrs, "head_sha") || head_sha do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_pr_head_sha}
    end
  end

  defp pull_request_review_event("pass"), do: {:ok, "APPROVE"}
  defp pull_request_review_event("request_changes"), do: {:ok, "REQUEST_CHANGES"}
  defp pull_request_review_event("needs_input"), do: {:ok, "COMMENT"}
  defp pull_request_review_event(verdict), do: {:error, {:unsupported_autonomous_review_verdict, verdict}}

  defp ensure_review_approval_allowed("APPROVE") do
    if Config.independent_github_reviewer?() do
      :ok
    else
      {:error, :reviewer_identity_not_independent}
    end
  end

  defp ensure_review_approval_allowed(_event), do: :ok

  defp pull_request_number(%Issue{pr_number: number}) when is_integer(number), do: {:ok, number}
  defp pull_request_number(%Issue{pr_number: number}) when is_binary(number), do: {:ok, number}

  defp pull_request_number(%Issue{pr_url: pr_url}) when is_binary(pr_url) do
    case Regex.run(~r{/pull/(\d+)(?:\z|[/?#])}, pr_url) do
      [_match, number] -> {:ok, number}
      _ -> {:error, :missing_pull_request_number}
    end
  end

  defp pull_request_number(_issue), do: {:error, :missing_pull_request_number}

  defp repo_and_issue_number(issue_id) do
    case String.split(issue_id, "#", parts: 2) do
      [repo_id, number] ->
        {Config.repo_by_id(repo_id) || primary_repo!(), number}

      [number] ->
        {primary_repo!(), number}
    end
  end

  defp issue_id(repo_id, number), do: "#{repo_id}##{number}"

  defp normalized_issue_id(repo_id, number) do
    if length(Config.repos()) > 1, do: issue_id(repo_id, number), else: to_string(number)
  end

  defp normalized_issue_identifier(repo_id, number) do
    if length(Config.repos()) > 1, do: "#{repo_id}-#{number}", else: "GH-#{number}"
  end

  defp repo_labels(repo_config) do
    Map.merge(SymphonyElixir.Config.Schema.default_github_labels(), Map.get(repo_config, :labels, %{}) || %{})
  end

  defp state_label_map(repo_config) do
    labels = repo_labels(repo_config)

    %{
      "Todo" => labels["queued"],
      "In Progress" => labels["running"],
      "Human Review" => labels["human_review"],
      "Needs Input" => labels["needs_input"],
      "Blocked" => labels["blocked"],
      "Rework" => labels["rework"],
      "Merging" => labels["merging"]
    }
  end

  defp persist_repo_snapshot(repo_config, issues) do
    _ = Storage.upsert_repo(Map.from_struct(repo_config))

    Enum.each(issues, fn issue ->
      Storage.record_issue_snapshot(%{
        repo_id: issue.repo_id,
        number: issue.number,
        identifier: issue.identifier,
        title: issue.title,
        state: issue.state,
        url: issue.url,
        labels: issue.labels,
        pr_url: issue.pr_url,
        head_sha: issue.head_sha,
        pr_state: issue.pr_state,
        check_state: issue.check_state,
        review_state: issue.review_state
      })
    end)
  end
end
