defmodule Slipdock.Gardener.Run do
  @moduledoc """
  One look over a board by the gardener (W-1807): when, why (`manual`,
  `schedule` or `mcp`) and how much it found — `counts` is `%{"total",
  "new", check key => n}`.
  """
  use Ecto.Schema

  @triggers ~w(manual schedule mcp)

  schema "garden_runs" do
    field :trigger, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :counts, :map, default: %{}

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :user, Slipdock.Accounts.User
    has_many :suggestions, Slipdock.Gardener.Suggestion

    timestamps(type: :utc_datetime)
  end

  def triggers, do: @triggers
end
