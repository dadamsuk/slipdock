defmodule SlipdockWeb.AgeChipOptionTest do
  @moduledoc """
  Leaving the age chip ("79d · 72d over usual") off cards: board-wide as the
  Display menu's *Time in list* facet, and for one list from its settings
  (`show_age`), which the API and a portable export carry too.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Column
  alias Slipdock.Swimlanes.Config

  setup %{user: user} do
    board = board_fixture(%{"name" => "Ages"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    %{board: board, todo: todo, doing: doing, a: card_fixture(todo), b: card_fixture(doing)}
  end

  defp chip(card), do: "#card-#{card.id} [data-role=age-chip]"

  describe "the card views' Time in list" do
    test "is offered, off by default, and on once shown, comfortable and compact", ctx do
      assert {"age", "Time in list"} in Config.facets()
      assert {"age", "Time in list"} in Slipdock.CardViews.Elements.front()
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      # Off until someone asks for it (#1708).
      refute has_element?(view, chip(ctx.a))

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?#{[density: "compact"]}")
      refute has_element?(view, chip(ctx.a))

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(age)
        )

      assert has_element?(view, chip(ctx.a))

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}?#{[density: "compact"]}",
          ~w(age)
        )

      assert has_element?(view, chip(ctx.a))
    end

    test "unticked, no card on the board shows the chip; the other facets stay", ctx do
      without = Config.facet_keys() -- ["age"]

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          without
        )

      refute has_element?(view, "[data-role=age-chip]")
      assert has_element?(view, "#card-#{ctx.a.id}")

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}?#{[density: "compact"]}",
          ~w(cover)
        )

      refute has_element?(view, "[data-role=age-chip]")
    end
  end

  describe "a list's own setting" do
    defp open_settings(conn, board, column) do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> with_target("#board-column") |> render_hook("edit_column", %{"id" => column.id})
      view
    end

    test "new lists show it", ctx do
      assert ctx.todo.show_age

      assert has_element?(
               open_settings(ctx.conn, ctx.board, ctx.todo),
               "#column-form",
               "Show how long each card"
             )
    end

    test "unticking it leaves the chip off that list's cards only, and ticking brings it back",
         ctx do
      view = open_settings(ctx.conn, ctx.board, ctx.todo)
      view |> form("#column-form", column: %{show_age: "false"}) |> render_submit()

      refute Repo.get!(Column, ctx.todo.id).show_age

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(age)
        )

      refute has_element?(view, chip(ctx.a))
      assert has_element?(view, chip(ctx.b))

      view = open_settings(ctx.conn, ctx.board, ctx.todo)
      view |> form("#column-form", column: %{show_age: "true"}) |> render_submit()
      assert Repo.get!(Column, ctx.todo.id).show_age

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(age)
        )

      assert has_element?(view, chip(ctx.a))
    end

    test "off for the list and off on the board: still off, nothing else lost", ctx do
      {:ok, _} = Boards.update_column(ctx.todo, %{"show_age" => false})

      {:ok, view, _} =
        Slipdock.CardViewHelpers.live_showing(
          ctx.conn,
          ctx.user,
          ctx.board,
          ~p"/boards/#{ctx.board}",
          ~w(tags age)
        )

      refute has_element?(view, chip(ctx.a))
      assert has_element?(view, chip(ctx.b))
    end

    test "the API reads and sets it", ctx do
      %{"board" => %{"columns" => columns}} =
        ctx.conn |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)

      assert Enum.all?(columns, &(&1["show_age"] == true))

      body =
        ctx.conn
        |> patch(~p"/api/boards/#{ctx.board.id}/columns/#{ctx.todo.id}", %{"show_age" => false})
        |> json_response(200)

      assert inspect(body) =~ ~s("show_age" => false)
      refute Repo.get!(Column, ctx.todo.id).show_age
    end
  end

  test "the manual, API guide and the skill say how to turn it off" do
    root = Path.expand("../../..", __DIR__)
    manual = File.read!(Path.join(root, "docs/manual.md"))
    # A card view element now (#2031), and still the list's own switch.
    assert manual =~ "show **Time in list** in your\n[card views](#card-views)"
    assert manual =~ "--no-show-age"
    refute manual =~ "untick **Time in list**"
    assert File.read!(Path.join(root, "lib/slipdock_web/api_guide.ex")) =~ "`show_age: false`"

    assert File.read!(Path.join(root, "priv/skills/slipdock/SKILL.md")) =~
             "set-column <board> <column> --no-show-age"
  end
end
