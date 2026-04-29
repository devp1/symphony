defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :repo_id,
    :repo_owner,
    :repo_name,
    :number,
    :pr_url,
    :pr_number,
    :head_sha,
    :pr_state,
    :check_state,
    :review_state,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          repo_id: String.t() | nil,
          repo_owner: String.t() | nil,
          repo_name: String.t() | nil,
          number: integer() | nil,
          pr_url: String.t() | nil,
          pr_number: integer() | nil,
          head_sha: String.t() | nil,
          pr_state: String.t() | nil,
          check_state: String.t() | nil,
          review_state: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
