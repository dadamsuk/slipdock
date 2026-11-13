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
    [_backlog, todo, doing, done] = board.columns
    card = card_fixture(todo, %{"title" => "Draw it"})
    %{board: board, card: card, todo: todo, doing: doing, done: done}
  end

  # Sets when each of the card's ledger rows happened, by the list it put
  # the card in, as seconds before now.
  defp backdate(card, ago_by_list) do
    now = DateTime.utc_now()

    for {list, ago} <- ago_by_list do
      Repo.update_all(
        from(m in CardMove, where: m.card_id == ^card.id and m.to_column_name == ^list),
        set: [inserted_at: DateTime.add(now, -ago)]
      )
    end
  end

  defp style(html, prop) do
    [_, pct] = Regex.run(~r/#{prop}: (-?[\d.]+)%/, html)
    String.to_float(pct)
  end

  defp span(view, lane, label),
    do: element(view, "#card-timeline-#{lane} [data-timeline-span='#{label}']")

  test "a moved card shows each list it sat in, the last one open", ctx do
    :ok = Boards.Cards.move_card(ctx.card.id, ctx.doing.id, nil, actor: Actor.web(ctx.user))

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
    # Not done, so nothing is folded.
    refute has_element?(view, "#card-timeline-done-at")
    refute doing =~ "not to scale"
  end

  describe "a card in a done list (#2827)" do
    @hour 3600
    @day 86_400

    test "keeps its done stay to a fixed tail, so the earlier stays keep their size", ctx do
      move = &Boards.Cards.move_card(ctx.card.id, &1.id, nil, actor: Actor.web(ctx.user))
      :ok = move.(ctx.doing)
      :ok = move.(ctx.done)

      # An hour in To Do, an hour in progress, then thirty days done.
      backdate(ctx.card, [
        {"To Do", 30 * @day + 2 * @hour},
        {"In Progress", 30 * @day + @hour},
        {"Done", 30 * @day}
      ])

      {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      todo = span(view, "stays", "To Do") |> render()
      doing = span(view, "stays", "In Progress") |> render()
      done = span(view, "stays", "Done") |> render()

      # Drawn to scale, the two hours would be a quarter of a percent of
      # the axis between them; folded, they share its first 85%.
      assert style(todo, "left") == 0.0
      assert_in_delta style(todo, "width"), 42.5, 0.1
      assert_in_delta style(doing, "left"), 42.5, 0.1
      assert_in_delta style(doing, "width"), 42.5, 0.1
      assert_in_delta style(done, "left"), 85.0, 0.1
      assert_in_delta style(done, "width"), 15.0, 0.1

      # Its real length is still what it says, and so is the stays list.
      assert done =~ "for 30d so far"
      assert done =~ "not to scale"
      assert render(element(view, "#card-timeline-list")) =~ "30d so far"
      # The header still counts the whole time, to now.
      assert render(element(view, "#card-timeline h3")) =~ "30d"

      # The axis says when it reached done.
      assert render(element(view, "#card-timeline-done-at")) =~ "done "
    end

    test "places a job after it reached done in the tail", ctx do
      :ok = Boards.Cards.move_card(ctx.card.id, ctx.done.id, nil, actor: Actor.web(ctx.user))
      backdate(ctx.card, [{"To Do", 10 * @day + @hour}, {"Done", 10 * @day}])
      {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})

      {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      job_html = span(view, "jobs", "##{job.id} queued") |> render()
      assert style(job_html, "left") >= 85.0
      assert_in_delta style(span(view, "stays", "To Do") |> render(), "width"), 85.0, 0.1
    end

    test "draws to scale again once it has moved back out of done", ctx do
      move = &Boards.Cards.move_card(ctx.card.id, &1.id, nil, actor: Actor.web(ctx.user))
      :ok = move.(ctx.done)
      :ok = move.(ctx.doing)

      backdate(ctx.card, [
        {"To Do", 30 * @day + @hour},
        {"Done", 30 * @day},
        {"In Progress", @hour}
      ])

      {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      refute has_element?(view, "#card-timeline-done-at")
      done = span(view, "stays", "Done") |> render()
      refute done =~ "not to scale"
      # Thirty days out of thirty days and an hour: nearly the whole axis.
      assert style(done, "width") > 95.0
    end
  end

  test "waits and jobs get lanes of their own", ctx do
    {:ok, _} =
      Boards.Waits.open_wait(ctx.card, Actor.web(ctx.user), %{"needs" => "Which colour?"})

    {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "go"})

    {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

    assert span(view, "waits", "on anyone") |> render() =~ "Which colour?"
    assert span(view, "jobs", "##{job.id} queued") |> render() =~ "dev · claude"
  end

  test "a backfilled stay is drawn as uncertain", ctx do
    :ok = Boards.Cards.move_card(ctx.card.id, ctx.doing.id, nil, actor: Actor.web(ctx.user))

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
