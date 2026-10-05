defmodule Slipdock.Repo.Migrations.AddOrderToColumns do
  use Ecto.Migration

  # How a list draws its cards (see `Slipdock.ListOrder`): sorted by an
  # attribute rather than by hand, and grouped under headings. Nil sort is
  # the order they were dragged into; nil group is one run of cards.
  def change do
    alter table(:columns) do
      add :sort_by, :string
      add :sort_dir, :string, null: false, default: "asc"
      add :group_by, :string
    end
  end
end
