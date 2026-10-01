defmodule Slipdock.Repo.Migrations.ListAddButtons do
  use Ecto.Migration

  @moduledoc """
  What the foot of every list offers: a card, a wiki page, or a document
  dropped in as a card with the file attached.

  All three are on by default — they are shortcuts to adding a card, not new
  kinds of thing — and each can be turned off per board in its settings,
  because a board that never holds documents does not want the button.
  """

  def change do
    alter table(:boards) do
      add :add_card, :boolean, null: false, default: true
      add :add_page, :boolean, null: false, default: true
      add :add_document, :boolean, null: false, default: true
    end
  end
end
