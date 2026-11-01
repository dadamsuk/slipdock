defmodule Slipdock.Wiki.Change do
  @moduledoc """
  One change to a board's wiki — a page, a folder, a page's attachment, a
  file or the board's own folder changed, moved, archived, restored or
  deleted — as a row of the log a sync polls (see `Slipdock.Wiki.Changes`).
  The id is the cursor. `from_path` is where a `moved` subject was.
  """
  use Ecto.Schema

  @subjects ~w(page folder attachment file board)
  @actions ~w(changed moved archived restored deleted)

  schema "wiki_changes" do
    field :subject, :string
    field :subject_id, :integer
    field :action, :string
    field :from_path, :string

    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def subjects, do: @subjects
  def actions, do: @actions
end
