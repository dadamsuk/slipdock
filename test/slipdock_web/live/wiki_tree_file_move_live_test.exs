defmodule SlipdockWeb.WikiTreeFileMoveLiveTest do
  @moduledoc """
  Dragging a file (an image, a PDF, a drawing) about the wiki's tree (#749):
  `tree_move` with kind `file` files it in a folder of its own board, or at
  the top, and refuses a reader, another board and a name already there.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  import Ecto.Query

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Wiki.{Change, Files}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KB", "code" => "kbfmv"}, owner: user)
    {:ok, specs} = Wiki.create_folder(kb, %{"name" => "Specs"})
    {:ok, art} = Wiki.create_folder(kb, %{"name" => "Art"})
    cat = file_fixture(kb, "cat.png")
    %{kb: kb, specs: specs, art: art, cat: cat}
  end

  defp file_fixture(board, name, folder \\ nil) do
    path = Path.join(System.tmp_dir!(), "fmv-#{System.unique_integer([:positive])}")
    File.write!(path, "BYTES")
    {:ok, file} = Files.create(board, %{name: name, folder_id: folder && folder.id}, path)
    file
  end

  # What the change log a sync reads holds for this file.
  defp file_changes(file),
    do:
      Repo.aggregate(
        from(c in Change, where: c.subject == "file" and c.subject_id == ^file.id),
        :count
      )

  defp move(view, file, into),
    do:
      render_click(view, "tree_move", %{
        "kind" => "file",
        "id" => to_string(file.id),
        "into" => into,
        "before" => nil
      })

  test "a file dropped in a folder is filed there, and the tree and a sync hear of it", ctx do
    %{conn: conn, kb: kb, specs: specs, cat: cat} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    tree_load(view)
    logged = file_changes(cat)

    move(view, cat, "folder:#{specs.id}")

    assert Files.get(cat.id).folder_id == specs.id
    reply = tree_load(view, %{"keys" => ["folder:#{specs.id}"]})
    assert %{kind: "file", writable: true} = row(reply, "folder:#{specs.id}", "cat.png")
    refute Enum.any?(reply.nodes["root"], &(&1.title == "cat.png"))
    assert file_changes(cat) == logged + 1
  end

  test "dropped on a page, a file goes to that page's folder; dropped at the top, out of any",
       ctx do
    %{conn: conn, kb: kb, specs: specs, art: art, cat: cat} = ctx
    note = page_fixture(kb, %{"title" => "Note"})
    {:ok, _} = Wiki.file_page(note, art)
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    move(view, cat, "page:#{note.id}")
    assert Files.get(cat.id).folder_id == art.id

    {:ok, _} = Files.move(Files.get(cat.id), %{folder_id: specs.id})
    move(view, cat, "folder:")
    assert Files.get(cat.id).folder_id == nil
  end

  test "a name already in the folder is refused, case aside, and nothing moves", ctx do
    %{conn: conn, kb: kb, specs: specs, cat: cat} = ctx
    file_fixture(kb, "CAT.png", specs)
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html = move(view, cat, "folder:#{specs.id}")
    assert html =~ "Specs already has a file called cat.png."
    assert Files.get(cat.id).folder_id == nil

    # An archived file of that name is no clash.
    other = file_fixture(kb, "dog.png", specs)
    {:ok, _} = Files.archive(other)
    dog = file_fixture(kb, "dog.png")
    move(view, dog, "folder:#{specs.id}")
    assert Files.get(dog.id).folder_id == specs.id
  end

  test "a file doesn't cross to another board of the vault", ctx do
    %{conn: conn, kb: kb, user: user, cat: cat} = ctx
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobsfmv"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")

    html = move(view, cat, "folder:#{acme.id}")
    assert html =~ "A file can only move within its own board."
    assert %{board_id: board_id, folder_id: nil} = Files.get(cat.id)
    assert board_id == kb.id
  end

  test "a reader can't move a file, nor anybody an archived or unknown one", ctx do
    %{kb: kb, specs: specs, cat: cat} = ctx
    # A fixture with no address would be the signed-in owner again.
    reader = user_fixture("reader-fmv@example.com")
    share_fixture(kb, reader, "read")
    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{kb}/wiki")

    html = move(view, cat, "folder:#{specs.id}")
    assert html =~ "You can&#39;t write on this board."
    assert Files.get(cat.id).folder_id == nil

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{kb}/wiki")
    {:ok, gone} = Files.archive(cat)
    assert move(view, gone, "folder:#{specs.id}") =~ "That file couldn&#39;t be moved."
    assert Files.get(cat.id).folder_id == nil

    assert render_click(view, "tree_move", %{
             "kind" => "file",
             "id" => "999999",
             "into" => "folder:"
           }) =~
             "That file couldn&#39;t be moved."
  end

  test "dropping a file where it already is changes nothing", ctx do
    %{conn: conn, kb: kb, specs: specs} = ctx
    in_specs = file_fixture(kb, "plan.pdf", specs)
    {:ok, view, _} = live(conn, ~p"/boards/#{kb}/wiki")
    logged = file_changes(in_specs)

    html = move(view, in_specs, "folder:#{specs.id}")
    refute html =~ "already has a file"
    assert file_changes(in_specs) == logged
  end
end
