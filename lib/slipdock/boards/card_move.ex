defmodule Slipdock.Boards.CardMove do
  @moduledoc """
  The movement ledger (#1112): one row each time a card changes list, and
  when it is created, archived and restored, in the order it happened. Board
  flow numbers, a list's usual stay and a card's time in its list are read
  from it.

  Rows are written by `Slipdock.Boards` at its move choke points, never
  edited, and never for a stand-in. Each one snapshots both lists' names and
  categories, so a rename or a deleted list leaves the history readable;
  deleting a list only nilifies its column ids.

    * `created` — `to_*` is the list the card started in;
    * `moved` — `from_*` and `to_*`;
    * `archived` — `from_*` is the list it was put away from;
    * `restored` — `to_*` is the list it came back to.

  `board_id` is the board the card was on afterwards and `from_board_id`
  the one the `from_*` list is on: the two differ for a move between boards.

  `actor_kind`, `via`, `user_id`, `agent` and `job_id` are the
  `Slipdock.Actor` that made the change. Rows recovered from the activity
  log by the migration that made the table are `backfilled` and have no
  actor.
  """
  use Ecto.Schema

  @kinds ~w(created moved archived restored)

  schema "card_moves" do
    field :kind, :string
    field :from_column_name, :string
    field :from_category, :string
    field :to_column_name, :string
    field :to_category, :string
    field :actor_kind, :string
    field :via, :string
    field :agent, :string
    field :backfilled, :boolean, default: false

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :from_board, Slipdock.Boards.Board
    belongs_to :from_column, Slipdock.Boards.Column
    belongs_to :to_column, Slipdock.Boards.Column
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  @doc "The kinds that put a card into a list."
  def entry_kinds, do: ~w(created moved restored)
end
