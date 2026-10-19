defmodule SlipdockWeb.CardStateLiveTest do
  @moduledoc """
  A card's state on its tile (#1117): the state line, word for word what
  `card_line` gives agents; the agent or person mark on a tree where agents
  work and nowhere else; the age chip, amber past the list's usual stay;
  the Stuck and Driver filters; and the tiles keeping up as a runner moves
  a job along.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Runners}
  alias Slipdock.Boards.CardMove

  setup %{user: user} do
    board = board_fixture(%{"name" => "Tiles"}, owner: user)
    [_backlog, todo, doing, done] = board.columns
    {:ok, runner, _} = Runners.create_runner(board, %{"name" => "runner-2", "pool" => "dev"})
    %{board: board, todo: todo, doing: doing, done: done, runner: runner}
  end

  defp runner_rule(board) do
    rule_fixture(board, %{
      "trigger" => %{"type" => "card_created"},
      "actions" => [%{"type" => "runner", "pool" => "elsewhere"}]
    })
  end

  defp running(ctx, card) do
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(ctx.runner)
    {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id)

    Repo.update_all(from(j in Runners.Job, where: j.id == ^job.id),
      set: [started_at: DateTime.utc_now() |> DateTime.add(-425) |> DateTime.truncate(:second)]
    )

    job
  end

  defp tile_line(html, card) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#card-#{card.id} [data-role=state-line]")
    |> LazyHTML.text()
    |> String.trim()
  end

  test "a running job's tile: the line card_line gives, word for word, and an agent mark",
       ctx do
    card = card_fixture(ctx.doing, %{"title" => "Build"})
    running(ctx, card)
    {:ok, _} = Boards.leave_handoff(card, nil, %{next_step: "Ship it", via: "ui"})

    {:ok, view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    listed = Enum.find(Boards.list_cards(ctx.board), &(&1.id == card.id))
    golden = SlipdockWeb.MCP.Tools.card_line(listed).state

    assert golden == "Running · runner-2 · 7m · Next: Ship it"
    assert tile_line(html, card) == golden
    assert has_element?(view, "#card-#{card.id} [data-role=driver-mark][data-driver=agent]")
  end

  test "#1132: each state's line is coloured by its kind; running pulses green", ctx do
    run = card_fixture(ctx.doing, %{"title" => "Build"})
    running(ctx, run)
    waiting = card_fixture(ctx.doing)
    {:ok, _} = Boards.open_wait(waiting, Actor.web(ctx.user), %{"needs" => "Region?"})
    failed = card_fixture(ctx.doing)
    {:ok, _} = Runners.queue(failed, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(ctx.runner)
    {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "failed"})

    {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    doc = LazyHTML.from_fragment(html)

    line = fn card, kind ->
      found = LazyHTML.query(doc, "#card-#{card.id} [data-role=state-line][data-kind=#{kind}]")
      assert Enum.count(found) == 1, "card #{card.id} has no #{kind} line"
      found
    end

    run_line = line.(run, "running")
    assert hd(LazyHTML.attribute(run_line, "class")) =~ "text-success"
    assert Enum.count(LazyHTML.query(run_line, ".bg-success.animate-pulse")) == 1

    wait_line = line.(waiting, "waiting")
    assert hd(LazyHTML.attribute(wait_line, "class")) =~ "text-amber-700"
    # Only a running job's dot pulses.
    assert Enum.empty?(LazyHTML.query(wait_line, ".animate-pulse"))

    assert hd(LazyHTML.attribute(line.(failed, "failed"), "class")) =~ "text-error"
  end

  test "a plain board: age chips, but no line, no mark and no Driver filter", ctx do
    card = card_fixture(ctx.todo)

    Boards.move_card(card.id, ctx.doing.id, nil,
      actor: %{Actor.unknown() | kind: "agent", via: "mcp", agent: "claude"}
    )

    {:ok, _} = Boards.leave_handoff(card, nil, %{next_step: "Look", via: "ui"})
    flagged = card_fixture(ctx.doing, %{"flags" => ["review"]})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    for c <- [card, flagged] do
      assert has_element?(view, "#card-#{c.id} [data-role=age-chip][data-stuck=false]")
      refute has_element?(view, "#card-#{c.id} [data-role=state-line]")
    end

    # The handoff and review flag keep their own marks.
    assert has_element?(view, "#card-#{card.id} [data-role=handoff-mark]")
    refute has_element?(view, "[data-role=driver-mark]")
    refute has_element?(view, "[phx-click=filter_driver]")
    assert has_element?(view, "[phx-click=filter_stuck]")
  end

  test "an open wait's tile says who it waits on, and its age stays plain", ctx do
    dana =
      user_fixture("dana@example.com") |> Ecto.Changeset.change(name: "Dana") |> Repo.update!()

    card = card_fixture(ctx.doing)

    {:ok, _} =
      Boards.open_wait(card, Actor.web(ctx.user), %{"needs" => "Region?", "on_user_id" => dana.id})

    {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    assert tile_line(html, card) =~ ~r/^Waiting on Dana · /
  end

  test "AE7: 3h into a list that usually takes 2h, the chip is amber and Stuck finds it", ctx do
    start = DateTime.add(DateTime.utc_now(), -3 * 86_400)

    for _ <- 1..8 do
      c = card_fixture(ctx.done)
      Repo.delete_all(from(m in CardMove, where: m.card_id == ^c.id))

      Repo.insert!(%CardMove{
        card_id: c.id,
        kind: "created",
        board_id: c.board_id,
        to_column_id: ctx.doing.id,
        inserted_at: start
      })

      Repo.insert!(%CardMove{
        card_id: c.id,
        kind: "moved",
        board_id: c.board_id,
        from_column_id: ctx.doing.id,
        to_column_id: ctx.done.id,
        inserted_at: DateTime.add(start, 7200)
      })
    end

    slow = card_fixture(ctx.doing, %{"title" => "Slow"})
    at = DateTime.add(DateTime.utc_now(), -(3 * 3600 + 30))
    Repo.update_all(from(m in CardMove, where: m.card_id == ^slow.id), set: [inserted_at: at])
    fresh = card_fixture(ctx.doing, %{"title" => "Fresh"})
    old_done = card_fixture(ctx.done, %{"title" => "Long done"})

    Repo.update_all(from(m in CardMove, where: m.card_id == ^old_done.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -30 * 86_400)]
    )

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    assert has_element?(
             view,
             "#card-#{slow.id} [data-role=age-chip][data-stuck=true]",
             "3h · 1h over usual"
           )

    assert has_element?(view, "#card-#{fresh.id} [data-role=age-chip][data-stuck=false]")
    assert has_element?(view, "#card-#{old_done.id} [data-role=age-chip][data-stuck=false]")

    view |> element("[phx-click=filter_stuck]") |> render_click()
    assert has_element?(view, "#card-#{slow.id}")
    refute has_element?(view, "#card-#{fresh.id}")
    refute has_element?(view, "#card-#{old_done.id}")
  end

  test "the board's Agent filter shows as many cards as REST driver=agent returns", ctx do
    runner_rule(ctx.board)
    agent = %{Actor.unknown() | kind: "agent", via: "mcp", agent: "claude"}
    by_agent = for _ <- 1..2, do: card_fixture(ctx.todo)
    Enum.each(by_agent, &Boards.move_card(&1.id, ctx.doing.id, nil, actor: agent))
    by_person = card_fixture(ctx.todo)
    Boards.move_card(by_person.id, ctx.doing.id, nil, actor: Actor.web(ctx.user))

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    assert has_element?(view, "#card-#{by_person.id} [data-role=driver-mark][data-driver=human]")

    view |> element("[phx-click=filter_driver][phx-value-driver=agent]") |> render_click()
    shown = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(".kanban-card")

    {token, _} = Accounts.create_api_token(ctx.user, "script")

    rest =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/boards/#{ctx.board.code}/cards?driver=agent")
      |> json_response(200)
      |> Map.fetch!("cards")

    assert Enum.count(shown) == length(rest)
    assert length(rest) == 2
    refute has_element?(view, "#card-#{by_person.id}")

    view |> element("[phx-click=filter_driver][phx-value-driver=all]") |> render_click()
    assert has_element?(view, "#card-#{by_person.id}")
  end

  test "the tile keeps up as a runner moves its job along", ctx do
    card = card_fixture(ctx.doing, %{"title" => "Watch"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
    refute has_element?(view, "#card-#{card.id} [data-role=state-line]")

    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(ctx.runner)
    {:ok, :ok} = Runners.heartbeat(ctx.runner, job.id)

    assert render(view) =~ "Running · runner-2"
    assert has_element?(view, "#card-#{card.id} [data-role=driver-mark][data-driver=agent]")

    {:ok, _} = Runners.finish(ctx.runner, job.id, %{status: "done"})
    refute has_element?(view, "#card-#{card.id} [data-role=state-line]")
  end
end
