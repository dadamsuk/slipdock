defmodule SlipdockWeb.CommentAuthorLiveTest do
  @moduledoc """
  A comment written in the app is signed by whoever wrote it, and the
  comments list says who that was rather than calling everybody "Me" (#668).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Accounts.User

  setup %{user: user} do
    {:ok, user} = user |> Ecto.Changeset.change(name: "Ada Lovelace") |> Repo.update()
    board = board_fixture(%{"name" => "Authors", "code" => "authors"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Signed remarks"})
    %{user: user, board: board, card: card}
  end

  test "a comment on a card is signed, and shows its writer", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    view
    |> element("form[phx-submit='add_comment']")
    |> render_submit(%{body: "Looks right to me"})

    assert [comment] = Boards.get_card!(ctx.card.id).comments
    assert comment.user_id == ctx.user.id

    html = view |> element("#comment-#{comment.id}") |> render()
    assert html =~ "Ada Lovelace"
    assert html =~ "AL"
    refute html =~ "Me"
  end

  test "a comment with no author says nothing about who wrote it", ctx do
    {:ok, comment} = Boards.add_comment(ctx.card, "Runner job ended")
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    html = view |> element("#comment-#{comment.id}") |> render()
    assert html =~ "?"
    refute html =~ "Ada Lovelace"
  end

  test "a comment on a wiki page is signed too", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"page_card_features" => true})
    page = page_fixture(ctx.board, %{"title" => "Retry policy"}, user: ctx.user)

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/wiki/#{page.slug}")
    view |> element("form[phx-submit='add_comment']") |> render_submit(%{body: "Still true?"})

    page = Repo.preload(page, [comments: :user], force: true)
    assert [%{body: "Still true?", user: %User{id: id}}] = page.comments
    assert id == ctx.user.id
    assert render(view) =~ "Ada Lovelace"
  end
end
