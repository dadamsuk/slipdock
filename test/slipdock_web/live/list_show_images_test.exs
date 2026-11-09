defmodule SlipdockWeb.ListShowImagesTest do
  @moduledoc """
  A list can keep image thumbnails off the front of its own cards
  (`show_images`, #1664): from its settings, the API, the CLI and a portable
  export. On by default; the board's Display › Images still rules every list.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Column
  alias Slipdock.Swimlanes.Config

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup %{user: user} do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Pictures"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    a = card_fixture(todo, %{"title" => "In to do"})
    b = card_fixture(doing, %{"title" => "In doing"})
    attach(a)
    attach(b)
    %{board: board, todo: todo, doing: doing, a: a, b: b}
  end

  defp attach(card) do
    path = Path.join(System.tmp_dir!(), "list-img-#{System.unique_integer([:positive])}")
    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)

    {:ok, a} =
      Boards.add_attachment(card, %{filename: "shot.png", content_type: "image/png"}, path)

    a
  end

  defp thumb(card), do: "#card-#{card.id} [data-role=card-image]"

  defp open_settings(conn, board, column) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    view |> with_target("#board-column") |> render_hook("edit_column", %{"id" => column.id})
    view
  end

  test "new lists show images, and the settings offer the tick box ticked", ctx do
    assert ctx.todo.show_images
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    assert has_element?(view, thumb(ctx.a))
    assert has_element?(view, thumb(ctx.b))

    view = open_settings(ctx.conn, ctx.board, ctx.todo)
    assert has_element?(view, "#column-form", "Show images on the front of this list's cards")

    assert has_element?(
             view,
             "#column-form input[type=checkbox][name='column[show_images]'][checked]"
           )
  end

  test "unticking it leaves images off that list's cards only, and ticking brings them back",
       ctx do
    view = open_settings(ctx.conn, ctx.board, ctx.todo)
    view |> form("#column-form", column: %{show_images: "false"}) |> render_submit()

    refute Repo.get!(Column, ctx.todo.id).show_images
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    refute has_element?(view, thumb(ctx.a))
    assert has_element?(view, thumb(ctx.b))
    # The card itself is still drawn, with its other facets.
    assert has_element?(view, "#card-#{ctx.a.id}", "In to do")

    view = open_settings(ctx.conn, ctx.board, ctx.todo)
    view |> form("#column-form", column: %{show_images: "true"}) |> render_submit()
    assert Repo.get!(Column, ctx.todo.id).show_images
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    assert has_element?(view, thumb(ctx.a))
  end

  test "compact cards on a list with images off lose their small square too", ctx do
    {:ok, _} = Boards.update_column(ctx.todo, %{"show_images" => false})

    {:ok, view, _} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}?#{[density: "compact"]}",
        ~w(images)
      )

    refute has_element?(view, thumb(ctx.a))
    assert has_element?(view, thumb(ctx.b))
  end

  test "images and the age chip off on one list are both off, independently", ctx do
    {:ok, _} = Boards.update_column(ctx.todo, %{"show_images" => false})
    {:ok, _} = Boards.update_column(ctx.doing, %{"show_age" => false})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    refute has_element?(view, thumb(ctx.a))
    assert has_element?(view, thumb(ctx.b))
  end

  test "the Display menu's Images off still turns them off on every list", ctx do
    without = Config.facet_keys() -- ["images"]

    {:ok, view, _} =
      Slipdock.CardViewHelpers.live_showing(
        ctx.conn,
        ctx.user,
        ctx.board,
        ~p"/boards/#{ctx.board}",
        without
      )

    refute has_element?(view, "[data-role=card-image]")
  end

  test "the API reads it on every list and sets it", ctx do
    %{"board" => %{"columns" => columns}} =
      ctx.conn |> get(~p"/api/boards/#{ctx.board.id}") |> json_response(200)

    assert Enum.all?(columns, &(&1["show_images"] == true))

    body =
      ctx.conn
      |> patch(~p"/api/boards/#{ctx.board.id}/columns/#{ctx.todo.id}", %{"show_images" => false})
      |> json_response(200)

    assert inspect(body) =~ ~s("show_images" => false)
    refute Repo.get!(Column, ctx.todo.id).show_images
  end

  test "the manual, API guide and the skill say how to turn it off" do
    root = Path.expand("../../..", __DIR__)
    assert Slipdock.DocsText.read!(Path.join(root, "docs/manual.md")) =~ "--no-show-images"

    assert Slipdock.DocsText.read!(Path.join(root, "lib/slipdock_web/api_guide.ex")) =~
             "`show_images: false`"

    assert Slipdock.DocsText.read!(Path.join(root, "priv/skills/slipdock/SKILL.md")) =~
             "set-column <board> <column> --no-show-images"
  end
end
