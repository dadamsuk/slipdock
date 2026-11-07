defmodule SlipdockWeb.CardFinderOpenTest do
  @moduledoc """
  A card opened from the Ctrl-O finder stays open, as one clicked on the
  board does (#2019).

  The finder's row is a `navigate` link, so the board mounts afresh with the
  card open. A fresh mount asks the browser for its remembered Display
  options (`SlipdockWeb.BoardLive.DisplayPrefs`), and the restore used to
  patch to the board's bare address, closing the card. Clicking a card on
  the board is a patch inside the running LiveView, which never restores.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Runners}

  @remembered %{"density" => "compact"}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Finder"}, owner: user)
    [_backlog, _todo, doing, done] = board.columns

    # A completed card far down a long Done list, as #1885 was (position 179).
    for n <- 1..40, do: card_fixture(done, %{"title" => "Shipped #{n}"})
    deep = card_fixture(done, %{"title" => "Deep in Done"})
    {:ok, deep} = Boards.update_card(deep, %{"completed" => true})

    %{board: board, doing: doing, deep: deep}
  end

  # Ctrl-O on the board, the card's id typed, its row clicked: the row's own
  # `navigate`, followed as the browser would.
  defp open_from_finder(conn, board, card) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    render_hook(view, "shortcut_panel", %{"panel" => "find"})
    render_hook(view, "palette_filter", %{"q" => "##{card.id}"})

    row = element(view, ~s{#palette-rows a[href="/boards/#{board.id}/cards/#{card.id}"]})
    {:ok, view, _html} = row |> render_click() |> follow_redirect(conn)
    view
  end

  defp card_open?(view, card),
    do: has_element?(view, "#card-modal") and render(view) =~ card.title

  describe "opened from the finder" do
    test "a completed card far down a list stays open through the Display restore", ctx do
      view = open_from_finder(ctx.conn, ctx.board, ctx.deep)
      assert card_open?(view, ctx.deep)

      # The fresh mount asks the browser to restore; it remembers something.
      assert_push_event(view, "display-prefs", %{restore: true})
      render_hook(view, "display_restore", %{"query" => @remembered})

      # Patched in place: the card's own address, with the options on it.
      assert_patch(view, ~p"/boards/#{ctx.board}/cards/#{ctx.deep}?density=compact")
      assert card_open?(view, ctx.deep)
      assert has_element?(view, "input[name=density][value=compact][checked]")
    end

    test "a card a runner is writing to stays open", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Being built"})
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "r1", "pool" => "dev"})
      {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
      job = Runners.claim(runner)
      {:ok, :ok} = Runners.heartbeat(runner, job.id)

      view = open_from_finder(ctx.conn, ctx.board, card)
      assert_push_event(view, "display-prefs", %{restore: true})
      render_hook(view, "display_restore", %{"query" => @remembered})
      assert_patch(view, ~p"/boards/#{ctx.board}/cards/#{card}?density=compact")

      # The runner writes while it is open: a comment, a handoff, a step.
      {:ok, _} = Boards.add_comment(card, "Building it now.", by: nil)
      {:ok, _} = Boards.leave_handoff(card, nil, %{next_step: "Tests next", via: "runner"})
      {:ok, :ok} = Runners.heartbeat(runner, job.id)

      assert card_open?(view, card)
      assert render(view) =~ "Building it now."
    end

    test "nothing remembered patches nothing, and the card stays open", ctx do
      view = open_from_finder(ctx.conn, ctx.board, ctx.deep)
      assert_push_event(view, "display-prefs", %{restore: true})

      # The hook sends nothing back when it remembers nothing; a set that
      # changes nothing is the same.
      render_hook(view, "display_restore", %{"query" => %{"density" => "normal"}})
      refute_push_event(view, "display-prefs", %{})
      assert card_open?(view, ctx.deep)
    end
  end

  describe "opened on the board" do
    test "a click is a patch in the running view: no restore, and it stays open", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert_push_event(view, "display-prefs", %{restore: true})
      render_hook(view, "display_restore", %{"query" => @remembered})
      assert_patch(view, ~p"/boards/#{ctx.board}?density=compact")

      render_patch(view, ~p"/boards/#{ctx.board}/cards/#{ctx.deep}?density=compact")
      # The mode was restored once already: opening a card asks nothing.
      assert_push_event(view, "display-prefs", %{restore: false})
      assert card_open?(view, ctx.deep)
    end
  end

  describe "the restore keeps the address the tab is on" do
    test "in another mode, with a filter beside the card", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table/cards/#{ctx.deep}?q=Deep")
      assert_push_event(view, "display-prefs", %{restore: true})

      render_hook(view, "display_restore", %{"query" => %{"density" => "compact"}})

      assert_patch(
        view,
        ~p"/boards/#{ctx.board}/table/cards/#{ctx.deep}?density=compact&q=Deep"
      )

      assert card_open?(view, ctx.deep)
    end

    test "a flash the mount put survives the patch", ctx do
      # Opening an archived card's address says so, in the board's archive.
      {:ok, archived} = Boards.archive_card(card_fixture(ctx.doing, %{"title" => "Gone"}))

      {:ok, view, _} =
        ctx.conn
        |> live(~p"/boards/#{ctx.board}/cards/#{archived}")
        |> follow_redirect(ctx.conn)

      assert render(view) =~ "That card is archived."
      assert_push_event(view, "display-prefs", %{restore: true})

      render_hook(view, "display_restore", %{"query" => @remembered})
      assert_patch(view, ~p"/boards/#{ctx.board}/archive?card=#{archived.id}&density=compact")
      assert render(view) =~ "That card is archived."
    end
  end
end
