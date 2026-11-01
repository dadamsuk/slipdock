defmodule SlipdockWeb.WikiVaultViewTreeTest do
  @moduledoc """
  The vault view's tree with many boards in the vault (W-2201): every board
  the reader owns is a folder of it, so a reply carrying many containers
  must not read each board in full once per container, which left the tree
  of a hundred-board vault empty. Its top names no board, and the vault's
  size, not the board the view stands on, says whether it opens whole.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.{Repo, Vaults, Wiki}

  setup %{user: user} do
    # "Aardvark" sorts first, so it is the board the vault's top stands on.
    stand = board_fixture(%{"name" => "Aardvark", "code" => "vvtaard"}, owner: user)

    boards =
      for n <- 1..8 do
        board = board_fixture(%{"name" => "Board #{n}", "code" => "vvt#{n}"}, owner: user)
        {:ok, a} = Wiki.create_folder(board, %{"name" => "Notes #{n}"})
        {:ok, b} = Wiki.create_folder(board, %{"name" => "Specs #{n}"})
        {board, [a, b]}
      end

    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Brain"})
    %{vault: vault, stand: stand, boards: boards}
  end

  defp vault_tree(view, keys),
    do: tree_load(view, %{"scope" => "vault", "keys" => keys, "only" => true})

  # `{what fun returned, how many queries of the cards table pid made}`. A
  # board read in full reads its cards; drawing the tree's rows has no need to.
  defp card_queries(pid, fun) do
    test = self()
    id = "vault-tree-cards-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:slipdock, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == pid and meta.source == "cards", do: send(test, {:card_query, id})
      end,
      nil
    )

    try do
      result = fun.()
      {result, count(id, 0)}
    after
      :telemetry.detach(id)
    end
  end

  defp count(id, n) do
    receive do
      {:card_query, ^id} -> count(id, n + 1)
    after
      0 -> n
    end
  end

  test "the vault's top lists every board as a folder", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault))

    assert titles(vault_tree(view, ["vault"]), "vault") ==
             ["Aardvark" | Enum.map(1..8, &"Board #{&1}")]
  end

  test "the boards follow the home page's hand-made order", %{
    conn: conn,
    user: user,
    vault: vault,
    boards: boards
  } do
    [{b1, _}, _, {b3, _} | _] = boards
    {b8, _} = List.last(boards)
    :ok = Slipdock.Boards.reorder_boards(user, [b8.id, b3.id, b1.id])

    {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault))

    # The placed three first, in their order; the rest after, oldest first.
    assert titles(vault_tree(view, ["vault"]), "vault") ==
             ["Board 8", "Board 3", "Board 1", "Aardvark"] ++
               Enum.map([2, 4, 5, 6, 7], &"Board #{&1}")
  end

  test "many containers in one reply cost no more board reads than one", %{
    conn: conn,
    vault: vault,
    boards: boards
  } do
    {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault))
    keys = for {_board, folders} <- boards, folder <- folders, do: "folder:#{folder.id}"
    [first | _] = keys

    {_reply, one} = card_queries(view.pid, fn -> vault_tree(view, [first]) end)
    {reply, many} = card_queries(view.pid, fn -> vault_tree(view, keys) end)

    # Every container asked for came back, each with the reader's write
    # access on its rows.
    assert Map.keys(reply.nodes) |> Enum.sort() == Enum.sort(keys)

    for {board, _} <- boards do
      assert %{writable: true} = row(vault_tree(view, ["vault"]), "vault", board.name)
    end

    # Before the fix each container read all nine boards in full, cards and
    # all: sixteen containers made well over a hundred card queries.
    assert many - one <= length(keys)
  end

  test "its top names no board; a page names the board that holds it", %{
    conn: conn,
    vault: vault,
    boards: [{board, _} | _]
  } do
    {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault))
    assert has_element?(view, "#vault-crumbs", "Brain")
    refute has_element?(view, "#vault-board")

    page_fixture(board, %{"title" => "Plan"})
    {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault, "Board 1/Plan"))
    assert view |> element("#vault-board") |> render() =~ "on Board 1"
  end

  describe "whether the tree opens whole on a first visit" do
    test "a small vault does", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault))
      assert tree_load_kept(view, %{"scope" => "vault"}).small
    end

    test "a big vault doesn't, though the board it stands on is small", %{
      conn: conn,
      vault: vault,
      stand: stand,
      boards: [{board, _} | _]
    } do
      page_fixture(stand, %{"title" => "Only page here"})
      bulk_pages!(board, 301)

      {:ok, view, _html} = live(conn, SlipdockWeb.VaultUrls.url(vault))
      refute tree_load_kept(view, %{"scope" => "vault"}).small
    end
  end

  # Pages straight into the table: a few hundred through `Wiki` would make
  # this test slow for nothing it checks.
  defp bulk_pages!(board, n) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    tag = System.unique_integer([:positive])

    rows =
      for i <- 1..n do
        %{
          board_id: board.id,
          title: "Bulk #{i}",
          slug: "bulk-#{i}",
          code: "VVT#{tag}-#{i}",
          number: 1000 + i,
          content_hash: "",
          inserted_at: now,
          updated_at: now
        }
      end

    {^n, _} = Repo.insert_all(Slipdock.Wiki.Page, rows)
  end
end
