defmodule SlipdockWeb.Meetings.ReceiptLiveTest do
  @moduledoc """
  The receipt (#539, screen 8): what was written with links, Undo all —
  asking first when something was edited since — and the same over the API.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Boards, Meetings, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Meetings.Commit

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing"}, owner: user)

    capture =
      reviewed_capture(board, user, [
        decision_finding(),
        action_finding(nil, %{"owner" => nil, "title" => "Tell sales"})
      ])

    {:ok, capture} = Commit.commit(capture, user)
    [create, decision] = capture.change_set["changes"]
    %{board: board, capture: capture, create: create, decision: decision}
  end

  test "lists what was written, with links to each", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")
    receipt = view |> element("#receipt") |> render()

    assert receipt =~ "Written to the board"
    assert receipt =~ ~s(href="/boards/#{ctx.board.id}/cards/#{ctx.create["card_id"]}")
    assert receipt =~ "Tell sales"
    assert receipt =~ ~s(href="/boards/#{ctx.board.id}/wiki/#{ctx.decision["page_slug"]}")
    assert receipt =~ "committed by #{ctx.user.email}"
    # The record says who did what.
    assert view |> element("#capture-record") |> render() =~ "Committed 2 changes."
  end

  test "Undo all reverses it", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")
    view |> element("#undo-all") |> render_click()

    assert Repo.get!(Card, ctx.create["card_id"]).archived_at

    assert view |> element("#receipt") |> render() =~
             "Undone by #{ctx.user.name || ctx.user.email}"

    refute has_element?(view, "#undo-all")
  end

  test "an edit since the commit is shown first; undo the rest keeps it", ctx do
    card = Repo.get!(Card, ctx.create["card_id"])
    {:ok, _} = Boards.update_card(card, %{"title" => "Tell sales and support"})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")
    view |> element("#undo-all") |> render_click()
    assert view |> element("#undo-conflicts") |> render() =~ "the card was edited since"
    assert Meetings.get_capture!(ctx.capture.id).undone_at == nil

    view |> element("#undo-rest") |> render_click()
    assert Repo.get!(Card, card.id).archived_at == nil
    assert Meetings.get_capture!(ctx.capture.id).undone_at
  end

  test "cancel leaves it all as it is", ctx do
    {:ok, _} = Boards.update_card(Repo.get!(Card, ctx.create["card_id"]), %{"title" => "Edited"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")
    view |> element("#undo-all") |> render_click()
    view |> element("#undo-cancel") |> render_click()
    refute has_element?(view, "#undo-conflicts")
    assert Meetings.get_capture!(ctx.capture.id).undone_at == nil
  end

  test "POST /api/captures/:id/undo: 409 listing the edits, then rest: true", ctx do
    {:ok, _} = Boards.update_card(Repo.get!(Card, ctx.create["card_id"]), %{"title" => "Edited"})

    body = ctx.conn |> post(~p"/api/captures/#{ctx.capture.id}/undo") |> json_response(409)
    assert body["error"] =~ "the card was edited since"
    assert [%{"ref" => _}] = body["edited"]

    body =
      ctx.conn
      |> post(~p"/api/captures/#{ctx.capture.id}/undo", %{"rest" => true})
      |> json_response(200)

    assert body["capture"]["undone_at"]

    again = ctx.conn |> post(~p"/api/captures/#{ctx.capture.id}/undo") |> json_response(409)
    assert again["error"] == "this capture was undone already"
  end

  test "a read-only member sees the receipt but no Undo", ctx do
    reader = user_fixture("reader@example.com")
    share_fixture(ctx.board, [reader], "read")
    {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{ctx.board}/meetings/#{ctx.capture.id}")
    assert has_element?(view, "#receipt")
    refute has_element?(view, "#undo-all")
    conn_as(reader) |> post(~p"/api/captures/#{ctx.capture.id}/undo") |> json_response(403)
  end
end
