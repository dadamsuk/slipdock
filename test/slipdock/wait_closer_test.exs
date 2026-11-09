defmodule Slipdock.WaitCloserTest do
  @moduledoc """
  Who a wait names as its closer when nobody answers it (#2599, findings
  #427 and #428). Taking the `waiting` flag off withdraws the wait, and
  completing or archiving the card closes it (`wait_hooks`,
  `auto_close_wait` in `Slipdock.Boards`). Both take the closer from
  `creator/1`: the actor the write's opts give, else the process's
  (`Slipdock.Actor.current/0`, the person behind a LiveView, #2094), and
  the person `:by` when neither names a user. That person is the wait's
  `closed_by_id`, and the withdrawal's comment names them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo}

  setup %{user: owner} do
    dana =
      "closer.dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    board = board_fixture(%{"name" => "Closers", "code" => "closers"}, owner: owner)
    [_backlog, todo | _] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    card = card_fixture(todo, %{"title" => "Ship it"})
    on_exit(fn -> Actor.put(nil) end)
    %{owner: owner, dana: dana, board: board, card: card}
  end

  defp agent(user),
    do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id, agent: "claude"}

  defp open!(ctx) do
    {:ok, wait} = Boards.open_wait(ctx.card, agent(ctx.owner), %{"needs" => "Which region?"})
    wait
  end

  defp card(ctx), do: Boards.get_card!(ctx.card.id)
  defp bodies(ctx), do: ctx |> card() |> Map.get(:comments) |> Enum.map(& &1.body)

  defp withdrawn_by(name),
    do: "#{name} took the waiting flag off, which withdrew the wait “Which region?”"

  describe "taking the waiting flag off withdraws the wait, naming" do
    test "the process's person when the opts name nobody", ctx do
      open!(ctx)
      Actor.put(Actor.web(ctx.dana), "Dana")

      {:ok, _} = Boards.toggle_flag(card(ctx), "waiting")

      assert %{close_reason: "withdrawn", closed_by_id: closed_by} = Boards.last_wait(ctx.card)
      assert closed_by == ctx.dana.id
      assert withdrawn_by("Dana") in bodies(ctx)
      refute "waiting" in card(ctx).flags
    end

    test "the person `:by` when no actor names a user", ctx do
      open!(ctx)

      {:ok, _} = Boards.toggle_flag(card(ctx), "waiting", by: ctx.dana)

      assert Boards.last_wait(ctx.card).closed_by_id == ctx.dana.id
      assert withdrawn_by("Dana") in bodies(ctx)
    end

    test "the opts' actor over the process's", ctx do
      open!(ctx)
      Actor.put(Actor.web(ctx.dana), "Dana")

      {:ok, _} = Boards.toggle_flag(card(ctx), "waiting", actor: Actor.web(ctx.owner))

      assert Boards.last_wait(ctx.card).closed_by_id == ctx.owner.id
      refute withdrawn_by("Dana") in bodies(ctx)
    end

    test "nobody when no one is recorded: no closer, and the comment says someone", ctx do
      open!(ctx)

      {:ok, _} = Boards.toggle_flag(card(ctx), "waiting")

      assert %{close_reason: "withdrawn", closed_by_id: nil} = Boards.last_wait(ctx.card)
      assert withdrawn_by("Someone") in bodies(ctx)
    end
  end

  describe "completing or archiving the card closes the wait, naming" do
    test "the process's person when a completion's opts name nobody", ctx do
      open!(ctx)
      Actor.put(Actor.web(ctx.dana), "Dana")

      {:ok, _} = Boards.toggle_completed(card(ctx))

      assert %{close_reason: "card_completed", closed_by_id: closed_by} =
               Boards.last_wait(ctx.card)

      assert closed_by == ctx.dana.id
      assert "Wait “Which region?” closed: the card was completed." in bodies(ctx)
    end

    test "the person `:by` on an archive", ctx do
      open!(ctx)

      {:ok, _} = Boards.archive_card(card(ctx), by: ctx.dana)

      assert %{close_reason: "archived", closed_by_id: closed_by} = Boards.last_wait(ctx.card)
      assert closed_by == ctx.dana.id
    end

    test "an automation as no person", ctx do
      open!(ctx)

      {:ok, _} = Boards.toggle_completed(card(ctx), actor: Actor.automation())

      assert %{close_reason: "card_completed", closed_by_id: nil} = Boards.last_wait(ctx.card)
    end

    test "nobody when no one is recorded", ctx do
      open!(ctx)

      {:ok, _} = Boards.toggle_completed(card(ctx))

      assert %{close_reason: "card_completed", closed_by_id: nil} = Boards.last_wait(ctx.card)
    end
  end

  describe "on the card panel" do
    setup ctx do
      open!(ctx)

      {:ok, view, _} =
        live(conn_as(ctx.dana), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      %{panel: with_target(view, "#board-card")}
    end

    test "the person who takes the waiting flag off is the wait's closer", ctx do
      render_click(ctx.panel, "toggle_flag", %{"flag" => "waiting"})

      assert %{close_reason: "withdrawn", closed_by_id: closed_by} = Boards.last_wait(ctx.card)
      assert closed_by == ctx.dana.id
      assert withdrawn_by("Dana") in bodies(ctx)
    end

    test "the person who archives the card is the wait's closer", ctx do
      render_click(ctx.panel, "archive_card", %{})

      assert %{close_reason: "archived", closed_by_id: closed_by} = Boards.last_wait(ctx.card)
      assert closed_by == ctx.dana.id
    end
  end
end
