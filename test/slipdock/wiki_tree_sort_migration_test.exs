defmodule Slipdock.WikiTreeSortMigrationTest do
  @moduledoc """
  The migration that makes the wiki's tree read a-z by default (#789): every
  board on "manual" moves to "name", folders on "manual" follow their board,
  and a sort chosen otherwise, and every position, is kept.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.Repo
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki
  alias Slipdock.Wiki.Folder

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261014160000_wiki_tree_sorts_by_name.exs")

  @migration migration

  # The test database is migrated already: its backfill again, on rows put
  # back as they stood before, inside the test's transaction.
  defp backfill, do: Enum.each(@migration.backfill(), &Repo.query!/1)

  test "manual boards and folders move to name; other choices and positions stay" do
    user = user_fixture()
    vault = board_fixture(%{"name" => "Vault", "code" => "vaultm"}, owner: user)
    dated = board_fixture(%{"name" => "Dated", "code" => "datedm"}, owner: user)

    {:ok, websites} = Wiki.create_folder(vault, %{"name" => "Websites"})
    {:ok, export} = Wiki.create_folder(vault, %{"name" => "export"})
    {:ok, named} = Wiki.create_folder(vault, %{"name" => "Named"})

    # As they stood before: everything "manual", one board and one folder
    # having chosen otherwise.
    Repo.update_all(from(b in Board, where: b.id == ^vault.id), set: [wiki_sort: "manual"])
    Repo.update_all(from(b in Board, where: b.id == ^dated.id), set: [wiki_sort: "modified"])
    Repo.update_all(Folder, set: [sort: "manual"])
    Repo.update_all(from(f in Folder, where: f.id == ^named.id), set: [sort: "created"])
    positions = Map.new(Repo.all(from(f in Folder, select: {f.id, f.position})))

    backfill()

    assert Repo.get!(Board, vault.id).wiki_sort == "name"
    assert Repo.get!(Board, dated.id).wiki_sort == "modified"
    assert Repo.get!(Folder, websites.id).sort == nil
    assert Repo.get!(Folder, export.id).sort == nil
    assert Repo.get!(Folder, named.id).sort == "created"
    assert Map.new(Repo.all(from(f in Folder, select: {f.id, f.position}))) == positions

    # The columns as the migration left them: a board made by SQL alone
    # sorts by name, and a folder need have no sort of its own.
    %{rows: [[default]]} =
      Repo.query!(
        "SELECT column_default FROM information_schema.columns WHERE table_name = 'boards' AND column_name = 'wiki_sort'"
      )

    assert default =~ "'name'"

    %{rows: [[nullable]]} =
      Repo.query!(
        "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'page_folders' AND column_name = 'sort'"
      )

    assert nullable == "YES"
  end
end
