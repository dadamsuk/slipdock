defmodule Slipdock.Repo.Migrations.AddCardBorders do
  use Ecto.Migration

  # Each edge of a card can wear its own palette colour (#1209), apart from
  # its cover colour. Nil is no border on that edge.
  def change do
    alter table(:cards) do
      add :border_top, :string
      add :border_right, :string
      add :border_bottom, :string
      add :border_left, :string
    end
  end
end
