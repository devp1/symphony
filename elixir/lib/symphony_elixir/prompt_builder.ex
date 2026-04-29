defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Linear.Issue, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @issue_context_defaults %{
    "id" => nil,
    "identifier" => nil,
    "title" => nil,
    "description" => nil,
    "priority" => nil,
    "state" => nil,
    "branch_name" => nil,
    "url" => nil,
    "assignee_id" => nil,
    "repo_id" => nil,
    "repo_owner" => nil,
    "repo_name" => nil,
    "repo_full_name" => nil,
    "number" => nil,
    "pr_url" => nil,
    "pr_number" => nil,
    "head_sha" => nil,
    "pr_state" => nil,
    "check_state" => nil,
    "review_state" => nil,
    "labels" => [],
    "labels_text" => "",
    "blocked_by" => [],
    "assigned_to_worker" => nil,
    "created_at" => nil,
    "updated_at" => nil
  }

  @spec build_prompt(Issue.t() | map(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue_context(issue)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp issue_context(%_{} = issue), do: issue |> Map.from_struct() |> issue_context()

  defp issue_context(issue) when is_map(issue) do
    issue
    |> to_solid_map()
    |> then(&Map.merge(@issue_context_defaults, &1))
    |> put_issue_display_fields()
  end

  defp put_issue_display_fields(issue) do
    issue
    |> Map.put("labels_text", labels_text(Map.get(issue, "labels")))
    |> Map.put("repo_full_name", repo_full_name(Map.get(issue, "repo_owner"), Map.get(issue, "repo_name")))
  end

  defp labels_text(labels) when is_list(labels) do
    labels
    |> Enum.map(&label_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp labels_text(label) when is_binary(label), do: label
  defp labels_text(nil), do: ""
  defp labels_text(label), do: label_text(label)

  defp label_text(label) when is_binary(label), do: label
  defp label_text(label) when is_atom(label), do: Atom.to_string(label)
  defp label_text(label) when is_integer(label), do: Integer.to_string(label)
  defp label_text(label) when is_float(label), do: Float.to_string(label)
  defp label_text(nil), do: ""
  defp label_text(label), do: inspect(label)

  defp repo_full_name(owner, name) when is_binary(owner) and is_binary(name) do
    case {String.trim(owner), String.trim(name)} do
      {"", _name} -> ""
      {_owner, ""} -> ""
      {owner, name} -> "#{owner}/#{name}"
    end
  end

  defp repo_full_name(_owner, _name), do: ""

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
