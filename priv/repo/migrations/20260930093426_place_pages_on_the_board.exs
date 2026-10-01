defmodule Slipdock.Repo.Migrations.PlacePagesOnTheBoard do
  use Ecto.Migration

  @moduledoc """
  A wiki page can be put on the board, in a list, and dragged about like a
  card.

  Placement is a second, optional axis: a page keeps its place in the wiki
  tree whether or not it is on the board, and most pages never will be. The
  ones that want to be are the spec sitting in "In Progress" beside the work
  it describes, or the retro waiting in "To Do" to be written.

  `position` is shared with the cards in the same list, so the two interleave
  in one order — the list is what the reader sees, and a document that has to
  sit after all the cards is not really on the board.

  A deleted list leaves its pages behind, unplaced rather than deleted:
  losing a list should never lose the writing.
  """

  def change do
    alter table(:pages) do
      add :column_id, references(:columns, on_delete: :nilify_all)
      # Shared with `cards.position` within the list, so the two interleave.
      add :board_position, :integer, null: false, default: 0
    end

    create index(:pages, [:column_id])
  end
end
