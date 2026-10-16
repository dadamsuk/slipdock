defmodule SlipdockWeb.CardMarkdownLiveTest do
  @moduledoc """
  A card's description and its comments are shown as rendered Markdown, not
  as the Markdown source (#868).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Markdown", "code" => "md"}, owner: user)

    card =
      card_fixture(hd(board.columns), %{
        "title" => "Rendered",
        "description" => "## Steps\n\n- **first** thing\n- `second`\n\n<script>alert(1)</script>"
      })

    %{board: board, card: card}
  end

  test "the description is rendered as Markdown", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert has_element?(view, "#card-description-view h2", "Steps")
    assert has_element?(view, "#card-description-view li strong", "first")
    assert has_element?(view, "#card-description-view li code", "second")
    refute has_element?(view, "#card-description-view script")

    html = view |> element("#card-description-view") |> render()
    refute html =~ "## Steps"
    refute html =~ "**first**"
    assert html =~ "&lt;script&gt;"
  end

  test "clicking the rendered description still opens the editor on its source", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    view |> element("#card-description-view") |> render_click()
    assert view |> element("#card-description") |> render() =~ "## Steps"
  end

  test "comments are rendered as Markdown", ctx do
    {:ok, comment} =
      Boards.add_comment(ctx.card, "Done:\n\n1. *one*\n2. [docs](https://example.com/d)")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert has_element?(view, "#comment-#{comment.id} ol li em", "one")
    assert has_element?(view, ~s|#comment-#{comment.id} a[href="https://example.com/d"]|, "docs")
    refute view |> element("#comment-#{comment.id}") |> render() =~ "*one*"
  end
end
