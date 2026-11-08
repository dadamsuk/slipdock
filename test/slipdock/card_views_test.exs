defmodule Slipdock.CardViewsTest do
  @moduledoc "Card views (#2031): named views, the three levels, and the cascade."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.CardViews
  alias Slipdock.CardViews.{CardView, Elements, Resolved}

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Views"}, owner: user)
    [todo, doing | _] = board.columns
    %{user: user, board: board, todo: todo, doing: doing}
  end

  defp front(resolved, column_id \\ nil, density \\ "normal"),
    do: CardViews.front_shown(resolved, column_id, density)

  describe "named card views" do
    test "are created, found by id or name, renamed, changed and deleted", %{user: user} do
      assert {:ok, %CardView{} = view} =
               CardViews.create(user, %{
                 "name" => " Lean ",
                 "show" => "tags",
                 "hide" => ["due_date"]
               })

      assert view.name == "Lean"
      assert view.elements == %{"tags" => true, "due_date" => false}
      assert {:ok, ^view} = CardViews.get(user, view.id)
      assert {:ok, ^view} = CardViews.get(user, to_string(view.id))
      assert {:ok, ^view} = CardViews.get(user, "Lean")
      assert [^view] = CardViews.list(user)

      {:ok, view} =
        CardViews.update(user, view, %{"name" => "Leaner", "inherit" => "tags", "show" => "id"})

      assert view.name == "Leaner"
      assert view.elements == %{"due_date" => false, "id" => true}

      {:ok, view} =
        CardViews.update(user, view, %{"reset" => true, "elements" => %{"cover" => false}})

      assert view.elements == %{"cover" => false}

      assert {:ok, _} = CardViews.delete(user, view)
      assert {:error, :not_found} = CardViews.get(user, "Leaner")
    end

    test "refuse unknown elements, bad values, blank and duplicate names", %{user: user} do
      assert {:error, "not an element: bogus" <> _} =
               CardViews.create(user, %{"name" => "X", "show" => "bogus"})

      assert {:error, "tags must be true, false or null"} =
               CardViews.create(user, %{"name" => "X", "elements" => %{"tags" => "maybe"}})

      assert {:error, %Ecto.Changeset{} = cs} = CardViews.create(user, %{"name" => "  "})
      assert {"can't be blank", _} = cs.errors[:name]

      {:ok, _} = CardViews.create(user, %{"name" => "Twice"})
      assert {:error, cs} = CardViews.create(user, %{"name" => "Twice"})
      assert {"you already have a card view of that name", _} = cs.errors[:name]
    end

    test "are personal: nobody else finds, changes or deletes them", %{user: user} do
      other = user_fixture("other-#{System.unique_integer([:positive])}@example.com")
      {:ok, view} = CardViews.create(user, %{"name" => "Mine"})
      {:ok, _} = CardViews.create(other, %{"name" => "Mine"})

      assert {:error, :not_found} = CardViews.get(other, view.id)
      assert {:error, :not_found} = CardViews.update(other, view, %{"name" => "Theirs"})
      assert {:error, :not_found} = CardViews.delete(other, view)
      assert [%{name: "Mine"}] = CardViews.list(other)
      assert {:error, :not_found} = CardViews.get(nil, "Mine")
    end
  end

  describe "levels" do
    test "the scope checks the board can be read and the list is on it", ctx do
      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")
      other_board = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.user)

      assert {:ok, :global} = CardViews.scope(ctx.user, nil, nil)
      assert {:ok, {:board, _}} = CardViews.scope(ctx.user, ctx.board, nil)
      assert {:ok, {:list, _, _}} = CardViews.scope(ctx.user, ctx.board, ctx.todo)
      assert {:error, :not_found} = CardViews.scope(stranger, ctx.board, nil)
      assert {:error, :not_found} = CardViews.scope(ctx.user, other_board, ctx.todo)
      assert {:error, :not_found} = CardViews.scope(ctx.user, nil, ctx.todo)
    end

    test "state only what they change, and a level stating nothing goes", ctx do
      scope = {:board, ctx.board}
      assert CardViews.level(ctx.user, scope).elements == %{}

      {:ok, level} = CardViews.update_level(ctx.user, scope, %{"hide" => "tags"})
      assert level.id && level.elements == %{"tags" => false}

      {:ok, level} = CardViews.update_level(ctx.user, scope, %{"elements" => %{"tags" => nil}})
      assert level.elements == %{}
      assert is_nil(CardViews.level(ctx.user, scope).id)
    end

    test "apply a named view, by id or name, or none", ctx do
      {:ok, view} = CardViews.create(ctx.user, %{"name" => "Lean", "hide" => "tags"})
      scope = {:list, ctx.board, ctx.todo}

      {:ok, level} = CardViews.update_level(ctx.user, scope, %{"card_view" => "Lean"})
      assert level.card_view.id == view.id
      {:ok, level} = CardViews.update_level(ctx.user, scope, %{"card_view" => view.id})
      assert level.card_view_id == view.id

      assert {:error, :not_found} =
               CardViews.update_level(ctx.user, scope, %{"card_view" => "Gone"})

      {:ok, level} = CardViews.update_level(ctx.user, scope, %{"card_view" => "none"})
      assert is_nil(level.card_view_id)
    end

    test "Show all is a board's switch only", ctx do
      assert {:ok, %{show_all: true}} = CardViews.put_show_all(ctx.user, ctx.board, true)
      assert {:ok, %{show_all: false}} = CardViews.put_show_all(ctx.user, ctx.board, false)

      assert {:error, "show_all is a board's switch" <> _} =
               CardViews.update_level(ctx.user, :global, %{"show_all" => true})

      assert {:error, "show_all is a board's switch" <> _} =
               CardViews.update_level(ctx.user, {:list, ctx.board, ctx.todo}, %{
                 "show_all" => "on"
               })

      assert {:error, "show_all must be true or false"} =
               CardViews.update_level(ctx.user, {:board, ctx.board}, %{"show_all" => "sometimes"})
    end

    test "clear_level removes what a level states", ctx do
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags"})
      assert {:ok, 1} = CardViews.clear_level(ctx.user, :global)
      assert CardViews.level(ctx.user, :global).elements == %{}
      assert {:ok, 0} = CardViews.clear_level(ctx.user, :global)
    end

    test "a deleted named view leaves the level's own elements", ctx do
      {:ok, view} = CardViews.create(ctx.user, %{"name" => "Lean", "hide" => "tags"})

      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, ctx.board}, %{
          "card_view" => "Lean",
          "hide" => "id"
        })

      {:ok, _} = CardViews.delete(ctx.user, view)
      level = CardViews.level(ctx.user, {:board, ctx.board})
      assert is_nil(level.card_view_id)
      assert level.elements == %{"id" => false}
    end

    test "changes are broadcast to the person", ctx do
      CardViews.subscribe(ctx.user)
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags"})
      user_id = ctx.user.id
      assert_receive {:card_views_changed, ^user_id}
    end
  end

  describe "the cascade" do
    test "defaults, then global, board, list and a saved view's card view", ctx do
      %{user: user, board: board, todo: todo, doing: doing} = ctx
      # The built-in defaults: the essentials (#1708) and every mark.
      assert front(CardViews.resolve(user, board)) ==
               MapSet.new(
                 Slipdock.Swimlanes.Config.default_show() ++ Slipdock.Swimlanes.Config.marks_on()
               )

      {:ok, _} =
        CardViews.update_level(user, :global, %{"hide" => "tags,priority", "show" => "id"})

      {:ok, _} = CardViews.update_level(user, {:board, board}, %{"show" => "tags"})
      {:ok, _} = CardViews.update_level(user, {:list, board, todo}, %{"hide" => "id"})
      {:ok, _} = CardViews.create(user, %{"name" => "Top", "show" => "priority,id"})

      r = CardViews.resolve(user, board)
      # Board over global; the global's other choices stand.
      assert "tags" in front(r) and "id" in front(r)
      refute "priority" in front(r)
      # The list over the board, only for that list's cards.
      refute "id" in front(r, todo.id)
      assert "id" in front(r, doing.id)

      # A saved view's card view sits above the list.
      top = CardViews.with_saved_view(r, user, "Top")
      assert "id" in front(top, todo.id) and "priority" in front(top, todo.id)
      # A name the reader has no card view of changes nothing.
      assert front(CardViews.with_saved_view(r, user, "Nobody's"), todo.id) == front(r, todo.id)
    end

    test "a level's named view, with the level's own elements on top", ctx do
      {:ok, _} = CardViews.create(ctx.user, %{"name" => "Lean", "hide" => "tags,due_date"})

      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, ctx.board}, %{
          "card_view" => "Lean",
          "show" => "tags"
        })

      r = CardViews.resolve(ctx.user, ctx.board)
      assert "tags" in front(r)
      refute "due_date" in front(r)
    end

    test "compact cards leave the image out by default, unless a level shows it", ctx do
      r = CardViews.resolve(ctx.user, ctx.board)
      assert "images" in front(r, nil, "normal")
      refute "images" in front(r, nil, "compact")

      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"show" => "images"})
      assert "images" in front(CardViews.resolve(ctx.user, ctx.board), nil, "compact")
    end

    test "Show all puts every front element on, and leaves the panel to the cascade", ctx do
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags,open.checklist"})
      {:ok, _} = CardViews.put_show_all(ctx.user, ctx.board, true)

      r = CardViews.resolve(ctx.user, ctx.board)
      assert front(r) == MapSet.new(Elements.front_keys())
      refute "open.checklist" in CardViews.panel_shown(r, nil)
      assert "open.comments" in CardViews.panel_shown(r, nil)
    end

    test "the panel's sections and sidebar groups cascade like the front", ctx do
      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, ctx.board}, %{
          "hide" => "open.comments,side.votes"
        })

      {:ok, _} =
        CardViews.update_level(ctx.user, {:list, ctx.board, ctx.todo}, %{
          "show" => "open.comments"
        })

      r = CardViews.resolve(ctx.user, ctx.board)
      refute "open.comments" in CardViews.panel_shown(r, ctx.doing.id)
      assert "open.comments" in CardViews.panel_shown(r, ctx.todo.id)
      refute "side.votes" in CardViews.panel_shown(r, ctx.todo.id)
      # Nothing resolved (another page drawing the panel): every section.
      assert CardViews.panel_shown(nil, 1) == MapSet.new(Elements.panel_keys())
    end

    test "nobody signed in has the defaults", ctx do
      assert CardViews.resolve(nil, ctx.board) == %Resolved{}
    end

    test "another person's levels don't reach this one's", ctx do
      other = user_fixture("other-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = CardViews.update_level(other, :global, %{"hide" => "tags"})
      assert "tags" in front(CardViews.resolve(ctx.user, ctx.board))
    end
  end

  describe "explain/4" do
    test "says where each value comes from, and that board settings win", ctx do
      {:ok, board} = Slipdock.Boards.update_board(ctx.board, %{"simple" => true})
      {:ok, todo} = Slipdock.Boards.update_column(ctx.todo, %{"show_age" => false})
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags"})

      {:ok, _} =
        CardViews.update_level(ctx.user, {:board, board}, %{"show" => "age,percent_complete"})

      {:ok, _} = CardViews.update_level(ctx.user, {:list, board, todo}, %{"show" => "id"})
      {:ok, _} = CardViews.create(ctx.user, %{"name" => "Top", "show" => "comments"})

      by_key =
        ctx.user
        |> CardViews.explain(board, todo, card_view: "Top")
        |> Map.new(&{&1.key, &1})

      assert %{shown: false, source: "global"} = by_key["tags"]
      assert %{shown: true, source: "list"} = by_key["id"]
      assert %{shown: true, source: "saved view"} = by_key["comments"]
      assert %{shown: true, source: "default"} = by_key["priority"]
      assert %{shown: true, source: "default", group: "open"} = by_key["open.description"]
      # The list's own setting and the simple board both win over the card view.
      assert %{shown: false, source: "board setting"} = by_key["age"]
      assert %{shown: false, source: "board setting"} = by_key["percent_complete"]

      {:ok, _} = CardViews.put_show_all(ctx.user, board, true)
      by_key = ctx.user |> CardViews.explain(board, todo) |> Map.new(&{&1.key, &1})
      assert %{shown: true, source: "show all"} = by_key["tags"]
      assert %{shown: false, source: "board setting"} = by_key["age"]
    end

    test "with no board, the global level alone", ctx do
      {:ok, _} = CardViews.update_level(ctx.user, :global, %{"hide" => "tags"})
      by_key = ctx.user |> CardViews.explain(nil) |> Map.new(&{&1.key, &1})
      assert %{shown: false, source: "global"} = by_key["tags"]
      assert length(Map.keys(by_key)) == length(Elements.keys())
    end
  end

  test "the element list covers the facets, the marks, the panel and the sidebar" do
    assert Enum.all?(Slipdock.Swimlanes.Config.facet_keys(), &Elements.known?/1)
    assert Enum.all?(~w(handoff handoff_note handoff_full state_line wait), &Elements.known?/1)
    assert "open.description" in Elements.panel_keys()
    assert "side.snooze" in Elements.panel_keys()
    # Every property in the sidebar can be hidden too (#2070), drawn first.
    side = Enum.map(Elements.side(), &elem(&1, 0))

    for key <-
          ~w(side.assignees side.priority side.percent side.start side.due side.health side.precision side.authors side.rollup) do
      assert key in side
      assert Elements.default?(key)
    end

    assert hd(side) == "side.assignees"
    assert Elements.label("side.percent") == "% complete"
    refute Elements.known?("bogus")
    assert Elements.label("open.comments") == "Comments and activity"
    assert Elements.label("nope") == "nope"
    refute Elements.default?("handoff_note")
    assert Elements.default?("side.time")
  end
end
