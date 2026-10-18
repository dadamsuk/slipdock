defmodule Slipdock.GardenerHelpers do
  @moduledoc "Shared by the gardener's check tests: run one check, and age a card."

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Gardener.{Context, Settings}
  alias Slipdock.Repo

  @doc "What `check` finds on `board` at `now`, with the board's settings or `settings` over them."
  def find(check, board, opts \\ []) do
    board = Repo.get!(Boards.Board, board.id)
    now = opts[:now] || DateTime.utc_now()
    settings = Map.merge(Settings.for(board, check), opts[:settings] || %{})
    check.find(Context.new(board, now), settings)
  end

  @doc "The card ids of what `check` finds."
  def found_ids(check, board, opts \\ []) do
    check |> find(board, opts) |> Enum.flat_map(& &1.subject["cards"])
  end

  @doc """
  Makes everything about `card` — its row, its activity lines and its
  comments — `days` old.
  """
  def age(card, days) do
    at = DateTime.add(DateTime.utc_now(:second), -days * 86_400)
    Repo.update_all(from(c in Boards.Card, where: c.id == ^card.id), set: [updated_at: at])

    Repo.update_all(from(a in Boards.Activity, where: a.card_id == ^card.id),
      set: [inserted_at: at]
    )

    Repo.update_all(from(c in Boards.Comment, where: c.card_id == ^card.id),
      set: [inserted_at: at]
    )

    at
  end
end
