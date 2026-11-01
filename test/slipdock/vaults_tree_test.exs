defmodule Slipdock.VaultsTreeTest do
  @moduledoc """
  The root vault's tree (W-2201): a sub-board shows once, inside its epic's
  card folder, whether or not that folder is a row of its own: a folder row
  with a `card_id` shares a directory with its sub-board's root.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Vaults, Wiki}
  alias Slipdock.Wiki.{CardFolders, Tree}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Keystone", "code" => "vttkb"}, owner: user)
    {:ok, template} = Boards.find_template(nil, "Simple")
    [column | _] = board.columns
    epic = card_fixture(column, %{"title" => "Launch"})
    {:ok, sub} = sub_board(epic, template)
    %{user: user, board: board, epic: epic, sub: sub, vault: Vaults.root(user)}
  end

  defp boards(ctx, ids \\ nil) do
    for id <- ids || Vaults.board_ids(ctx.vault), into: %{} do
      board = Boards.get_board!(id)
      {id, {board, [as: ctx.user]}}
    end
  end

  defp children(ctx, key) do
    {:ok, rows} = Tree.vault_children(ctx.vault, key, boards(ctx))
    rows
  end

  # Every row a reader reaches walking a filtered tree down from its top.
  defp shown(nodes, key) do
    rows = Map.get(nodes, key, [])
    rows ++ Enum.flat_map(rows, &shown(nodes, &1[:key] || "#{&1.kind}:#{&1.id}"))
  end

  defp titled(rows, title), do: Enum.filter(rows, &(to_string(&1[:title]) == title))

  describe "with no folder row for the epic" do
    test "the way down is a dir row, then the sub-board, once each", ctx do
      {:ok, _} = Wiki.create_page(ctx.sub, %{"title" => "Inner"}, user: ctx.user)
      board_key = "board:#{ctx.board.id}"

      assert [%{key: ^board_key}] = ctx |> children("vault") |> titled("Keystone")

      assert [%{key: "dir:Keystone/Cards"} = cards] =
               ctx |> children(board_key) |> titled("Cards")

      assert cards.mount

      sub_key = "board:#{ctx.sub.id}"
      assert [%{key: ^sub_key}] = ctx |> children("dir:Keystone/Cards") |> titled("Launch")
      assert ["Inner"] = ctx |> children(sub_key) |> Enum.map(& &1.title)
    end
  end

  describe "with a real card folder for the epic" do
    setup ctx do
      {:ok, folder} = CardFolders.ensure(ctx.epic)
      %{folder: folder}
    end

    test "the card folder is one row, holding the sub-board's pages once", ctx do
      {:ok, _} = Wiki.create_page(ctx.sub, %{"title" => "Inner"}, user: ctx.user)
      {:ok, own} = Wiki.create_page(ctx.board, %{"title" => "Own", "folder_id" => ctx.folder.id})

      [cards] = ctx |> children("board:#{ctx.board.id}") |> titled("Cards")
      assert [%{id: id}] = ctx |> children("folder:#{cards.id}") |> titled("Launch")
      assert id == ctx.folder.id

      rows = children(ctx, "folder:#{ctx.folder.id}")
      assert [%{}] = titled(rows, "Inner")
      assert [%{id: own_id}] = titled(rows, "Own")
      assert own_id == own.id
      refute Enum.any?(rows, &(&1[:key] == "board:#{ctx.sub.id}"))
    end

    test "with nothing of its own, the folder still opens onto the sub-board", ctx do
      {:ok, _} = Wiki.create_page(ctx.sub, %{"title" => "Inner"}, user: ctx.user)

      [cards] = ctx |> children("board:#{ctx.board.id}") |> titled("Cards")
      assert [%{count: count}] = ctx |> children("folder:#{cards.id}") |> titled("Launch")
      assert count > 0
    end

    test "the way to a sub-board's page goes through the folder", ctx do
      {:ok, page} = Wiki.create_page(ctx.sub, %{"title" => "Inner"}, user: ctx.user)

      keys = Tree.vault_path_to(ctx.vault, page, boards(ctx))

      assert "folder:#{ctx.folder.id}" in keys
      refute "board:#{ctx.sub.id}" in keys
      assert hd(keys) == "board:#{ctx.board.id}"
    end

    test "a filter that matches on the sub-board shows it once", ctx do
      {:ok, _} = Wiki.create_page(ctx.sub, %{"title" => "Needle"}, user: ctx.user)

      filters = Map.put(Slipdock.Filters.empty(), :q, "Needle")
      result = Tree.vault_filter(ctx.vault, boards(ctx), filters)

      rows = shown(result.nodes, result.top)
      assert [%{}] = titled(rows, "Needle")
      assert [%{}] = titled(rows, "Launch")
    end
  end

  test "a board the reader can't open is left out of the tree", ctx do
    other = board_fixture(%{"name" => "Other", "code" => "vttot"}, owner: ctx.user)
    rows = Enum.map(children(ctx, "vault"), & &1.title)
    assert "Other" in rows

    {:ok, reduced} = Tree.vault_children(ctx.vault, "vault", Map.delete(boards(ctx), other.id))
    refute "Other" in Enum.map(reduced, & &1.title)
  end
end
