defmodule Slipdock.MultiboardTest do
  @moduledoc """
  The multiboard overview (#1479): which lists a reader can choose, the top
  N cards of each in list order, the three layouts, and the remembered view.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Multiboard, Repo}
  alias Slipdock.Boards.Card

  setup do
    user = user_fixture()
    ops = board_fixture(%{"name" => "Ops"}, owner: user)
    web = board_fixture(%{"name" => "Web"}, owner: user)
    [_, ops_todo, ops_doing, _] = ops.columns
    [_, web_todo, _, _] = web.columns

    %{
      user: user,
      ops: ops,
      web: web,
      ops_todo: ops_todo,
      ops_doing: ops_doing,
      web_todo: web_todo
    }
  end

  defp titles(entry), do: Enum.map(entry.cards, & &1.title)

  describe "normalize/2" do
    test "takes ids from a list or a comma string, dropping junk and repeats" do
      assert Multiboard.normalize(%{"lists" => "3, 1,x,,3,-2"}).lists == [3, 1]
      assert Multiboard.normalize(%{"lists" => ["", "7", 7, "8"]}).lists == [7, 8]
      assert Multiboard.normalize(%{"lists" => 12}).lists == []
    end

    test "clamps top to 1..50 and defaults it to 5" do
      assert Multiboard.normalize(%{"top" => "0"}).top == 1
      assert Multiboard.normalize(%{"top" => 999}).top == Multiboard.max_top()
      assert Multiboard.normalize(%{"top" => "seven"}).top == 5
      assert Multiboard.normalize(%{}).top == 5
    end

    test "an unknown layout is by board; what is missing comes from the saved view" do
      assert Multiboard.normalize(%{"by" => "spiral"}).by == "board"

      saved = %{"lists" => [4], "top" => 9, "by" => "grid"}
      assert Multiboard.normalize(%{"by" => "list"}, saved) == %{lists: [4], top: 9, by: "list"}
      assert Multiboard.normalize(nil, nil) == %{lists: [], top: 5, by: "board"}
    end
  end

  describe "choices/2" do
    test "every board of the reader with its lists in order, not other people's", ctx do
      stranger = user_fixture("stranger@example.com")
      _theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)

      choices = Multiboard.choices(ctx.user)
      assert Enum.map(choices, & &1.board.name) |> Enum.sort() == ["Ops", "Web"]

      ops = Enum.find(choices, &(&1.board.id == ctx.ops.id))
      assert Enum.map(ops.columns, & &1.name) == ["Backlog", "To Do", "In Progress", "Done"]
    end

    test "a token confined to one board offers only that board's lists", ctx do
      {_, token} = Slipdock.Accounts.create_api_token(ctx.user, "t", scope_boards: [ctx.web.id])
      assert [%{board: %{name: "Web"}}] = Multiboard.choices(ctx.user, token: token)
    end

    test "nobody signed in has nothing to choose" do
      assert Multiboard.choices(nil) == []
    end
  end

  describe "entries/2" do
    test "the top N of each list in its own order, archived and snoozed cards left out", ctx do
      for t <- ~w(one two three four), do: card_fixture(ctx.ops_todo, %{"title" => t})
      card_fixture(ctx.web_todo, %{"title" => "web one"})

      [two | _] = Repo.all(from c in Card, where: c.title == "two")
      later = DateTime.add(DateTime.utc_now(), 3600, :second)
      Repo.update_all(from(c in Card, where: c.id == ^two.id), set: [snoozed_until: later])

      [three] = Repo.all(from c in Card, where: c.title == "three")
      {:ok, _} = Slipdock.Boards.archive_card(three)

      choices = Multiboard.choices(ctx.user)
      view = %{lists: [ctx.web_todo.id, ctx.ops_todo.id], top: 2, by: "board"}
      entries = Multiboard.entries(view, choices)

      todo = Enum.find(entries, &(&1.column.id == ctx.ops_todo.id))
      assert titles(todo) == ["one", "four"]

      # The list's own order, not the order cards were made in.
      [four] = Repo.all(from c in Card, where: c.title == "four")
      Repo.update_all(from(c in Card, where: c.id == ^four.id), set: [position: -1])
      todo = Enum.find(Multiboard.entries(view, choices), &(&1.column.id == ctx.ops_todo.id))
      assert titles(todo) == ["four", "one"]

      web = Enum.find(entries, &(&1.column.id == ctx.web_todo.id))
      assert titles(web) == ["web one"]
    end

    test "lists the reader can't choose from are left out", ctx do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
      [_, their_todo | _] = theirs.columns
      card_fixture(their_todo, %{"title" => "secret"})

      view = %{lists: [their_todo.id, ctx.ops_doing.id], top: 5, by: "board"}
      entries = Multiboard.entries(view, Multiboard.choices(ctx.user))

      assert [%{column: %{id: id}, cards: []}] = entries
      assert id == ctx.ops_doing.id
    end

    test "no lists is no entries", ctx do
      assert Multiboard.entries(%{lists: [], top: 5}, Multiboard.choices(ctx.user)) == []
    end
  end

  describe "group/2" do
    setup ctx do
      card_fixture(ctx.ops_todo, %{"title" => "a"})
      card_fixture(ctx.ops_doing, %{"title" => "b"})
      card_fixture(ctx.web_todo, %{"title" => "c"})
      view = %{lists: [ctx.ops_todo.id, ctx.ops_doing.id, ctx.web_todo.id], top: 5}
      %{entries: Multiboard.entries(view, Multiboard.choices(ctx.user))}
    end

    defp item_titles(section), do: Enum.map(section.items, & &1.card.title)

    test "by board: a section per board, its lists' cards in turn", ctx do
      sections = Multiboard.group(ctx.entries, "board")
      ops = Enum.find(sections, &(&1.label == "Ops"))
      assert item_titles(ops) == ["a", "b"]
      assert Enum.map(ops.items, & &1.column.name) == ["To Do", "In Progress"]
      assert length(sections) == 2
    end

    test "by list: a section per list, named board › list", ctx do
      labels = ctx.entries |> Multiboard.group("list") |> Enum.map(& &1.label)
      assert Enum.sort(labels) == ["Ops › In Progress", "Ops › To Do", "Web › To Do"]
    end

    test "grid: one section of every card, each knowing where it is from", ctx do
      assert [%{key: "grid", items: items}] = Multiboard.group(ctx.entries, "grid")
      assert items |> Enum.map(& &1.card.title) |> Enum.sort() == ["a", "b", "c"]
      assert Enum.all?(items, &(&1.board && &1.column))
      assert Multiboard.group([], "grid") == []
    end
  end

  describe "resolve/2" do
    test "ids and board/list names, case aside; the first unknown is named", ctx do
      choices = Multiboard.choices(ctx.user)

      assert Multiboard.resolve(
               ["#{ctx.web_todo.id}", "ops/in progress", " #{ctx.ops.code}/To Do"],
               choices
             ) ==
               {:ok, [ctx.web_todo.id, ctx.ops_doing.id, ctx.ops_todo.id]}

      assert Multiboard.resolve(["ops/Nope"], choices) == {:error, "ops/Nope"}
      assert Multiboard.resolve(["999999999"], choices) == {:error, "999999999"}
      assert Multiboard.resolve(["what"], choices) == {:error, "what"}
    end
  end

  test "prefs round-trip through the user", ctx do
    assert Multiboard.prefs(ctx.user) == %{lists: [], top: 5, by: "board"}
    {:ok, user} = Multiboard.save_prefs(ctx.user, %{lists: [ctx.ops_todo.id], top: 3, by: "grid"})
    assert Multiboard.prefs(Repo.reload(user)) == %{lists: [ctx.ops_todo.id], top: 3, by: "grid"}
  end
end
