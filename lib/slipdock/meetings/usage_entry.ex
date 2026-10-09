defmodule Slipdock.Meetings.UsageEntry do
  @moduledoc """
  One line of meeting capture's usage ledger: a transcription (`seconds`), a
  model call (`tokens_in`/`tokens_out`), or audio stored (`bytes`), with its
  `cost` where the provider reported one, against a person, a capture and a
  month. `own_key` marks work done on the person's own key or endpoint, which
  the server's limits do not count.
  """
  use Ecto.Schema

  @kinds ~w(transcription reading relisten context storage)

  schema "meeting_usage" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :capture, Slipdock.Meetings.Capture
    belongs_to :board, Slipdock.Boards.Board
    field :kind, :string
    field :step, :string
    field :seconds, :float
    field :tokens_in, :integer
    field :tokens_out, :integer
    field :bytes, :integer
    field :cost, :float
    field :own_key, :boolean, default: false
    field :model, :string
    field :month, :date
    field :inserted_at, :utc_datetime_usec
  end

  def kinds, do: @kinds
end
