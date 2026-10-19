defmodule SlipdockWeb.CardTimelineLiveTest do
  # The card panel's Timeline (#1131): the lists it has sat in, its waits
  # and its jobs as lanes on one axis, near the bottom of the panel.
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.CardMove

  setup %{user: user} do
    board = board_fixture(%{"name" => "Timeline live"}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Draw it"})
    %{board: board, card: card, todo: todo, doing: doing}
  end

  defp span(view, lane, label),
    do: element(view, "#card-timeline-#{lane} [data-timeline-span='#{label}']")

  test "a moved card shows each list it sat in, the last one open", ctx do
    :ok = Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: Actor.web(ctx.user))

    # An hour in To Do, then a quarter of an hour in progress.
    now = DateTime.utc_now()

    Repo.update_all(from(m in CardMove, where: m.card_id == ^ctx.card.id and m.kind == "created"),
      set: [inserted_at: DateTime.add(now, -75 * 60)]
    )

    Repo.update_all(from(m in CardMove, where: m.card_id == ^ctx.card.id and m.kind == "moved"),
      set: [inserted_at: DateTime.add(now, -15 * 60)]
    )

    {:ok, view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    assert html =~ "Timeline"
    assert has_element?(view, "#card-timeline-list")
    todo = span(view, "stays", "To Do") |> render()
    doing = span(view, "stays", "In Progress") |> render()

    assert todo =~ "for 1h"
    assert todo =~ "bg-info/40"
    assert todo =~ "left: 0.0%"
    assert doing =~ "by"
    assert doing =~ "so far"
    assert doing =~ "bg-primary/50"
    # Three quarters of the way along: the To Do hour of the hour and a quarter.
    assert doing =~ ~r/left: 8\d\.\d+%|left: 79\.\d+%/
    refute has_element?(view, "#card-timeline-waits")
    refute has_element?(view, "#card-timeline-jobs")
    assert render(element(view, "#card-timeline-list")) =~ "2 stays in lists"
  end

  test "waits and jobs get lanes of their own", ctx do
    {:ok, _} = Boards.open_wait(ctx.card, Actor.web(ctx.user), %{"needs" => "Which colour?"})
    {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})

    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    assert span(view, "waits", "on anyone") |> render() =~ "Which colour?"
    assert span(view, "jobs", "##{job.id} queued") |> render() =~ "dev · claude"
  end

  test "a backfilled stay is drawn as uncertain", ctx do
    :ok = Boards.move_card(ctx.card.id, ctx.doing.id, nil, actor: Actor.web(ctx.user))

    Repo.update_all(from(m in CardMove, where: m.card_id == ^ctx.card.id and m.kind == "moved"),
      set: [from_column_name: nil, backfilled: true, actor_kind: nil, via: nil, user_id: nil]
    )

    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    todo = span(view, "stays", "To Do") |> render()
    assert todo =~ "time uncertain"
    assert todo =~ "border-dashed"
    assert span(view, "stays", "In Progress") |> render() =~ "recovered from the log"
  end

  test "a card with nothing recorded has no timeline", ctx do
    Repo.delete_all(from(m in CardMove, where: m.card_id == ^ctx.card.id))

    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    refute has_element?(view, "#card-timeline")
  end
end
