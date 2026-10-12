defmodule Slipdock.Wiki.Change do
  @moduledoc """
  One change to a board's wiki — a page, a folder or a page's attachment
  changed, archived, restored or deleted — as a row of the log a sync polls
  (see `Slipdock.Wiki.Changes`). The id is the cursor.
  """
  use Ecto.Schema

  @subjects ~w(page folder attachment)
  @actions ~w(changed archived restored deleted)

  schema "wiki_changes" do
    field :subject, :string
    field :subject_id, :integer
    field :action, :string

    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def subjects, do: @subjects
  def actions, do: @actions
end
