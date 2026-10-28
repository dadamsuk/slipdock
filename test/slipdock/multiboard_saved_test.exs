defmodule Slipdock.MultiboardSavedTest do
  @moduledoc """
  Saved multiboards (#1482): a named, coloured Multiboard view, its owner's
  alone, placed among their boards and vaults on the home page.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Multiboard, Repo, Vaults}
  alias Slipdock.Multiboard.Saved

  setup do
    user = user_fixture()
    a = board_fixture(%{"name" => "A", "code" => "msva"}, owner: user)
    b = board_fixture(%{"name" => "B", "code" => "msvb"}, owner: user)
    [_, a_todo, _, _] = a.columns
    %{user: user, a: a, b: b, a_todo: a_todo}
  end

  defp save(user, name, view \\ %{lists: [], top: 5, by: "board"}, color \\ "indigo") do
    {:ok, saved} = Multiboard.create_saved(user, %{"name" => name, "color" => color}, view)
    saved
  end

  describe "saving" do
    test "keeps the name, colour and a normalized view", %{user: user, a_todo: todo} do
      {:ok, saved} =
        Multiboard.create_saved(
          user,
          %{"name" => "  This week  ", "color" => "rose"},
          %{lists: [todo.id, todo.id], top: 500, by: "nonsense"}
        )

      assert saved.name == "This week"
      assert saved.color == "rose"
      assert Saved.view(saved) == %{lists: [todo.id], top: Multiboard.max_top(), by: "board"}
    end

    test "refuses a blank name and an unknown colour", %{user: user} do
      assert {:error, cs} = Multiboard.create_saved(user, %{"name" => " "}, %{})
      assert %{name: [_]} = errors_on(cs)

      assert {:error, cs} =
               Multiboard.create_saved(user, %{"name" => "X", "color" => "plaid"}, %{})

      assert %{color: [_]} = errors_on(cs)
      assert Multiboard.list_saved(user) == []
    end

    test "renames, recolours and changes the view", %{user: user, a_todo: todo} do
      saved = save(user, "Old")

      {:ok, saved} = Multiboard.update_saved(saved, %{"name" => "New", "color" => "teal"})
      assert {saved.name, saved.color} == {"New", "teal"}

      {:ok, saved} = Multiboard.save_view(saved, %{lists: [todo.id], top: 3, by: "grid"})
      assert Saved.view(Repo.reload(saved)) == %{lists: [todo.id], top: 3, by: "grid"}

      assert {:error, _} = Multiboard.update_saved(saved, %{"color" => "plaid"})
    end

    test "deleting one leaves the boards alone", %{user: user, a: a} do
      saved = save(user, "Gone")
      {:ok, _} = Multiboard.delete_saved(saved)

      assert Multiboard.list_saved(user) == []
      assert Repo.reload(a)
    end
  end

  describe "finding" do
    test "by id or by name, case aside, and in name order", %{user: user} do
      b = save(user, "beta")
      a = save(user, "Alpha")

      assert Enum.map(Multiboard.list_saved(user), & &1.id) == [a.id, b.id]
      assert Multiboard.get_saved(user, to_string(b.id)).id == b.id
      assert Multiboard.get_saved(user, b.id).id == b.id
      assert Multiboard.get_saved(user, "ALPHA").id == a.id
      assert Multiboard.get_saved(user, "nope") == nil
    end

    test "somebody else's is not found", %{user: user} do
      stranger = user_fixture("msv-stranger@example.com")
      theirs = save(stranger, "Theirs")

      assert Multiboard.get_saved(user, theirs.id) == nil
      assert Multiboard.get_saved(user, "Theirs") == nil
      assert Multiboard.list_saved(user) == []
    end

    test "boards_of names each list's board", %{a: a, b: b, a_todo: todo} do
      [b_first | _] = b.columns
      assert Multiboard.boards_of([todo.id, b_first.id]) == %{todo.id => a.id, b_first.id => b.id}
      assert Multiboard.boards_of([]) == %{}
    end
  end

  describe "on the home page's order" do
    defp order(user) do
      Slipdock.Access.list_boards(user)
      |> Kernel.++(Vaults.list_vaults(user))
      |> Kernel.++(Multiboard.list_saved(user))
      |> Boards.sort_boards("manual")
      |> Enum.map(&{&1.__struct__ |> Module.split() |> List.last(), &1.id})
    end

    test "takes its place among the boards and vaults, by any of its names", ctx do
      %{user: user, a: a, b: b} = ctx
      m = save(user, "M")
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "V"})

      :ok = Boards.reorder_boards(user, [b, m, vault, a])

      assert order(user) == [
               {"Board", b.id},
               {"Saved", m.id},
               {"Vault", vault.id},
               {"Board", a.id}
             ]

      :ok = Boards.reorder_boards(user, ["multiboard-#{m.id}", a.id, vault, b.id])

      assert order(user) == [
               {"Saved", m.id},
               {"Board", a.id},
               {"Vault", vault.id},
               {"Board", b.id}
             ]

      :ok = Boards.reorder_boards(user, [a.id, {:multiboard, to_string(m.id)}, vault, b.id])
      assert Repo.reload(m).position == 1
    end

    test "an order of boards alone (the CLI's) keeps each multiboard where it was", ctx do
      %{user: user, a: a, b: b} = ctx
      c = board_fixture(%{"name" => "C", "code" => "msvc"}, owner: user)
      m = save(user, "M")
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "V"})

      :ok = Boards.reorder_boards(user, [a, m, b, vault, c])
      :ok = Boards.reorder_boards(user, [c.id, b.id, a.id])

      assert order(user) == [
               {"Board", c.id},
               {"Saved", m.id},
               {"Board", b.id},
               {"Vault", vault.id},
               {"Board", a.id}
             ]
    end

    test "an order naming vaults but no multiboards keeps the multiboards' places", ctx do
      %{user: user, a: a, b: b} = ctx
      m = save(user, "M")
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "V"})

      :ok = Boards.reorder_boards(user, [m, a, vault, b])
      :ok = Boards.reorder_boards(user, [vault, b.id, a.id])

      assert hd(order(user)) == {"Saved", m.id}
    end

    test "a multiboard left out of an order naming multiboards loses its place", ctx do
      %{user: user, a: a} = ctx
      m = save(user, "M")
      n = save(user, "N")

      :ok = Boards.reorder_boards(user, [m, n, a])
      :ok = Boards.reorder_boards(user, [n, a])

      assert Repo.reload(n).position == 0
      assert Repo.reload(m).position == nil
    end

    test "nobody else's multiboard is placed", %{user: user, a: a} do
      stranger = user_fixture("msv-stranger2@example.com")
      theirs = save(stranger, "Theirs")
      :ok = Boards.reorder_boards(stranger, [theirs])

      :ok = Boards.reorder_boards(user, [{:multiboard, theirs.id}, a])
      assert Repo.reload(theirs).position == 0
    end

    test "nudge and place move it like a board", %{user: user, a: a, b: b} do
      m = save(user, "M")
      :ok = Boards.reorder_boards(user, [a, b, m])

      :ok = Boards.nudge_board(user, m, :up, [a, b, m])
      assert order(user) == [{"Board", a.id}, {"Saved", m.id}, {"Board", b.id}]

      :ok = Boards.place_board(user, m, a.id, [a, m, b])
      assert hd(order(user)) == {"Saved", m.id}
    end

    test "sorts by name, cards and age among the boards", %{user: user, a_todo: todo} do
      card_fixture(todo, %{"title" => "One"})
      m = save(user, "0 first")
      boards = Slipdock.Access.list_boards(user, activity: true)

      assert [%Saved{id: id} | _] = Boards.sort_boards(boards ++ [m], "name")
      assert id == m.id

      # It holds no cards of its own, so the busiest board comes first.
      assert [%{name: "A"} | _] = Boards.sort_boards([m | boards], "cards")
      assert %Saved{} = List.last(Boards.sort_boards([m | boards], "oldest"))
      assert %Saved{} = hd(Boards.sort_boards([m | boards], "newest"))
    end
  end
end
