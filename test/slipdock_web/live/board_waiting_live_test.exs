defmodule SlipdockWeb.BoardWaitingLiveTest do
  @moduledoc """
  An epic shows what in its tree is waiting on you (#2095): a chip on its
  tile counting what is on me, a glance line naming it (and what is on
  others) in place of the percentage, the chip opening the sub-board kept
  to those cards, the board header's count linking to My work kept to the
  board, and all of it following a wait as it opens and is answered.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("bw-owner@example.com")
    dana = user_fixture("bw-dana@example.com")
    board = board_fixture(%{"name" => "Ops"}, owner: owner)
    [_backlog, todo | _] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)

    epic = card_fixture(todo, %{"title" => "Epic"})
    {:ok, _} = Boards.Cards.update_card(epic, %{"percent_complete" => 57})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)

    %{owner: owner, dana: dana, board: board, todo: todo, epic: epic, sub: sub}
  end

  defp agent(user), do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id}
  defp sub_card(ctx, title), do: card_fixture(hd(ctx.sub.columns), %{"title" => title})

  defp wait_on(card, by, on) do
    {:ok, wait} =
      Boards.Waits.open_wait(card, agent(by), %{"needs" => "Which region?", "on_user_id" => on.id})

    wait
  end

  defp failed_job(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    from(j in Job, where: j.id == ^job.id) |> Repo.update_all(set: [status: "failed"])
  end

  defp circling(card, n) do
    from(c in Card, where: c.id == ^card.id)
    |> Repo.update_all(
      set: [
        verify_rejections: n,
        verify_state: "rejected",
        flags: ["review"],
        verify_at: DateTime.utc_now(:second)
      ]
    )
  end

  defp board_view(ctx, user \\ nil, path \\ nil) do
    {:ok, view, _} =
      live(log_in_user(build_conn(), user || ctx.owner), path || ~p"/boards/#{ctx.board.id}")

    view
  end

  defp chip(ctx), do: "#card-#{ctx.epic.id}-waiting"
  defp line(ctx), do: "#card-#{ctx.epic.id}-waiting-line"

  test "a wait, a rejection-limit card and a failed job: the chip counts them, the line names them",
       ctx do
    asked = sub_card(ctx, "Region")
    wait_on(asked, ctx.owner, ctx.owner)
    limit = sub_card(ctx, "Circling")
    circling(limit, 3)
    failing = sub_card(ctx, "Flaky")
    failed_job(failing)

    view = board_view(ctx)

    assert has_element?(view, chip(ctx), "3 waiting on you")

    text = view |> element(line(ctx)) |> render()
    assert text =~ "Waiting on you:"
    assert text =~ "##{limit.id} (3 rejections)"
    assert text =~ "##{asked.id} (a question)"
    assert text =~ "##{failing.id} (a failed job)"
  end

  test "an item on someone else is in the line only, never the chip", ctx do
    mine = sub_card(ctx, "Mine")
    wait_on(mine, ctx.owner, ctx.owner)
    wait_on(sub_card(ctx, "Theirs"), ctx.owner, ctx.dana)

    view = board_view(ctx)
    assert has_element?(view, chip(ctx), "1 waiting on you")

    assert has_element?(
             view,
             line(ctx),
             "Waiting on you: ##{mine.id} (a question) and 1 on someone else"
           )
  end

  test "only someone else's: no chip, a line saying so", ctx do
    wait_on(sub_card(ctx, "Theirs"), ctx.owner, ctx.dana)

    view = board_view(ctx)
    refute has_element?(view, chip(ctx))
    assert has_element?(view, line(ctx), "Waiting on someone else: 1")
    refute has_element?(view, "#board-waiting")
  end

  test "nothing waiting: no chip, no line, no header count", ctx do
    sub_card(ctx, "Quiet")

    view = board_view(ctx)
    refute has_element?(view, chip(ctx))
    refute has_element?(view, line(ctx))
    refute has_element?(view, "#board-waiting")
  end

  test "on the tile the glance line takes the percentage's place", ctx do
    card =
      Boards.get_board!(ctx.board.id).columns
      |> Enum.flat_map(& &1.cards)
      |> Enum.find(&(&1.id == ctx.epic.id))
      |> Map.put(:percent_complete, 57)

    render = fn c -> render_component(&SlipdockWeb.SlipdockComponents.card/1, card: c) end

    assert render.(card) =~ "57%"
    assert render.(%{card | waiting_on_me: %{mine: [], others: []}}) =~ "57%"

    item = %{card: %Card{id: 9001, title: "Region"}, reason: "wait", text: "Waiting on you: ?"}
    html = render.(%{card | waiting_on_me: %{mine: [item], others: []}})
    refute html =~ "57%"
    assert html =~ "Waiting on you: #9001 (a question)"
    assert html =~ "1 waiting on you"
  end

  test "the chip opens the sub-board kept to the cards waiting on me", ctx do
    asked = sub_card(ctx, "Region")
    wait_on(asked, ctx.owner, ctx.owner)
    quiet = sub_card(ctx, "Quiet")

    view = board_view(ctx)
    html = view |> element(chip(ctx)) |> render()
    assert html =~ "/boards/#{ctx.sub.id}?waiting=me"

    sub_view = board_view(ctx, ctx.owner, "/boards/#{ctx.sub.id}?waiting=me")
    assert has_element?(sub_view, "#waiting-filter-banner")
    assert has_element?(sub_view, "#card-#{asked.id}")
    refute has_element?(sub_view, "#card-#{quiet.id}")

    # Show all brings the rest back.
    sub_view |> element("#waiting-filter-clear") |> render_click()
    assert has_element?(sub_view, "#card-#{quiet.id}")
    refute has_element?(sub_view, "#waiting-filter-banner")
  end

  test "the header counts the tree and links to My work kept to the board", ctx do
    asked = sub_card(ctx, "Region")
    wait_on(asked, ctx.owner, ctx.owner)
    # Elsewhere: on another board, so My work kept to this one leaves it out.
    other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
    elsewhere = card_fixture(Enum.at(other.columns, 1), %{"title" => "Far away"})
    failed_job(elsewhere)

    view = board_view(ctx)
    assert has_element?(view, "#board-waiting", "Waiting on you: 1")
    assert view |> element("#board-waiting") |> render() =~ "/work?board=#{ctx.board.id}"

    {:ok, work, _} = live(log_in_user(build_conn(), ctx.owner), "/work?board=#{ctx.board.id}")
    assert has_element?(work, "#work-board-filter", "Ops")
    assert has_element?(work, "#waiting-card-#{asked.id}")
    refute has_element?(work, "#waiting-card-#{elsewhere.id}")

    work |> element("#work-board-filter-clear") |> render_click()
    assert has_element?(work, "#waiting-card-#{elsewhere.id}")
    refute has_element?(work, "#work-board-filter")

    # A board the reader can't see keeps nothing out.
    stranger = board_fixture(%{"name" => "Not mine"}, owner: ctx.dana)
    {:ok, work, _} = live(log_in_user(build_conn(), ctx.owner), "/work?board=#{stranger.id}")
    refute has_element?(work, "#work-board-filter")
  end

  test "the chip and the header follow a wait as it opens and is answered", ctx do
    card = sub_card(ctx, "Region")
    view = board_view(ctx)
    refute has_element?(view, chip(ctx))

    wait_on(card, ctx.owner, ctx.owner)
    assert has_element?(view, chip(ctx), "1 waiting on you")
    assert has_element?(view, "#board-waiting", "Waiting on you: 1")

    {:ok, _} =
      Boards.Waits.answer_wait(Repo.get!(Card, card.id), Actor.web(ctx.owner), %{"answer" => "EU"})

    refute has_element?(view, chip(ctx))
    refute has_element?(view, "#board-waiting")
  end
end
