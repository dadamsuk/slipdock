defmodule SlipdockWeb.RelativeTimeLiveTest do
  @moduledoc """
  A card's relative times tick in the browser (#2025): the status updates,
  the at-a-glance status line and the comments are `<time data-relative>`s
  with the viewer's zone, which `assets/js/relative_time.js` rewrites every
  30 s and on every re-render, so the server never has to.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Timezones}
  alias Slipdock.Boards.{Comment, StatusUpdate}

  # Three days back reads "3 days ago" whatever the hour, so no midnight race.
  @days_ago 3 * 86_400

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Ticking"})
    at = DateTime.utc_now() |> DateTime.add(-@days_ago) |> DateTime.truncate(:second)

    {:ok, update} =
      Boards.add_status_update(card, owner, %{"health" => "at_risk", "body" => "Waiting on CI"})

    {:ok, comment} = Boards.add_comment(card, "Looks right", by: owner)
    Repo.update_all(from(u in StatusUpdate, where: u.id == ^update.id), set: [inserted_at: at])
    Repo.update_all(from(c in Comment, where: c.id == ^comment.id), set: [inserted_at: at])

    %{board: board, card: card, owner: owner, update: update, comment: comment, at: at}
  end

  defp open(ctx), do: live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp ticking!(html, selector, ctx) do
    {:ok, doc} = Floki.parse_document(html)
    assert [el] = Floki.find(doc, selector), "no #{selector}"

    assert Floki.attribute(el, "data-relative") == ["past"]
    assert Floki.attribute(el, "data-zone") == [Timezones.of(ctx.owner)]
    assert Floki.attribute(el, "datetime") == [DateTime.to_iso8601(ctx.at)]
    assert Floki.text(el) == "3 days ago"
    el
  end

  test "a status update's time ticks", ctx do
    {:ok, _view, html} = open(ctx)
    ticking!(html, "time#status-update-#{ctx.update.id}-at", ctx)
  end

  test "the at-a-glance status line's time ticks", ctx do
    {:ok, _view, html} = open(ctx)
    ticking!(html, "#glance-status time#glance-step-at", ctx)
  end

  test "a comment's time ticks", ctx do
    {:ok, _view, html} = open(ctx)
    ticking!(html, "#comment-#{ctx.comment.id} time#comment-#{ctx.comment.id}-at", ctx)
  end

  test "a re-render keeps the marks the browser rewrites the stale text by", ctx do
    {:ok, view, _html} = open(ctx)

    {:ok, _} = Boards.add_status_update(ctx.card, ctx.owner, %{"health" => "on_track"})
    :sys.get_state(view.pid)
    :sys.get_state(view.pid)
    html = render(view)

    ticking!(html, "time#status-update-#{ctx.update.id}-at", ctx)
    ticking!(html, "time#comment-#{ctx.comment.id}-at", ctx)

    {:ok, doc} = Floki.parse_document(html)
    [glance] = Floki.find(doc, "#glance-status time#glance-step-at")
    assert Floki.attribute(glance, "data-relative") == ["past"]
    assert Floki.text(glance) =~ ~r/^(just now|\d+ min ago|\d+ h ago|yesterday)$/
  end
end
