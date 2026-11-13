defmodule SlipdockWeb.PagesGrantLoweredLiveTest do
  @moduledoc """
  A board's other pages and its owner's panels, sent an event after their
  reader's level is lowered, store nothing (#2998).

  The Health, Tidy up, Findings and Agentic Building pages, and the
  Automations, Runners, Overseer and Settings panels, gate their events on
  what the reader may do, and read that again before each, as the board
  itself (`BoardGrantLoweredLiveTest`, #2981), its panels
  (`PanelGrantLoweredLiveTest`, #2771) and its list settings
  (`ColumnGrantLoweredLiveTest`, #2946) do. The wiki's editor is in
  `WikiGrantLoweredLiveTest`.

  The level is lowered two ways. `:told` tells the board (`Access.grant/4`,
  or a `board_changed` broadcast). `:untold` changes the row and tells
  nobody: it stands for a lowering the open page never hears of, and for an
  event that arrives before the page has taken the news in. The pages here
  don't listen for a board's changes at all, so for them both are untold.

  What gates on write is lowered on the grant's row. What gates on owner
  can't be: owning a board is `boards.owner_id`, and a grant stops at
  write. So an owner is lowered by the board's row naming somebody else, as
  when an account is deleted and its shared boards handed on, or a board
  moves to another tree.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Automations, Boards, Gardener, Health, Overseer, Repo, Runners}
  alias Slipdock.Access.Grant
  alias Slipdock.Findings.Finding

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Lowered"}, owner: owner)
    writer = user_fixture("writer@example.com")
    successor = user_fixture("successor@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)
    # What an owner is left with once the board is somebody else's. Given
    # before any page opens, so that telling the board of it is not a
    # second message racing the handover.
    {:ok, _} = Access.grant(board, owner, "write", owner)

    %{board: board, owner: owner, writer: writer, successor: successor}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp grants(ctx, user),
    do: from(g in Grant, where: g.board_id == ^ctx.board.id and g.user_id == ^user.id)

  defp lower(:told, ctx) do
    {:ok, _} = Access.grant(ctx.board, ctx.writer, "read", ctx.owner)
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp lower(:untold, ctx) do
    assert {1, _} = Repo.update_all(grants(ctx, ctx.writer), set: [level: "read"])
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp remove(ctx, user) do
    assert {1, _} = Repo.delete_all(grants(ctx, user))
  end

  defp hand_over(how, ctx) do
    assert {1, _} =
             Repo.update_all(from(b in Boards.Board, where: b.id == ^ctx.board.id),
               set: [owner_id: ctx.successor.id]
             )

    if how == :told, do: Boards.PubSub.broadcast(ctx.board.id)
    assert Access.board_permission(ctx.owner, Boards.get_board!(ctx.board.id)) == :write
  end

  # An event for a panel, if the board still draws it: told, the board
  # takes the panel away from a reader who no longer owns it.
  defp push(view, target, event, params) do
    if has_element?(view, target),
      do: view |> with_target(target) |> render_hook(event, params)

    render(view)
  end

  defp finding(board) do
    Repo.insert!(%Finding{
      board_id: board.id,
      kind: "gotcha",
      source: "agent",
      text: "a lesson",
      by: "Builder"
    })
  end

  @read_only "You have read-only access to this board."
  @no_access "You don&#39;t have access to that board."

  for how <- [:told, :untold] do
    describe "the grant lowered to read, the board #{how}:" do
      test "Health looks nothing over", ctx do
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/health")
        assert has_element?(view, "button[phx-click=run]")
        before = Health.last_run()

        lower(unquote(how), ctx)
        html = render_hook(view, "run", %{})

        assert html =~ @read_only
        refute html =~ "Looked the tree over"
        assert Health.last_run() == before
        # Drawn again for a reader: no button to press.
        refute has_element?(view, "button[phx-click=run]")
      end

      test "Tidy up runs nothing and decides nothing", ctx do
        {:ok, _} = Gardener.run(ctx.board, trigger: "manual", user: ctx.owner)
        ran = Gardener.last_run(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/tidy")

        lower(unquote(how), ctx)

        assert render_hook(view, "run", %{}) =~ @read_only
        assert render_hook(view, "apply_group", %{"check" => "stale"}) =~ @read_only
        assert Gardener.last_run(ctx.board).id == ran.id
      end

      test "Findings triages nothing", ctx do
        finding = finding(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/findings")
        assert has_element?(view, "[data-role=triage]")

        lower(unquote(how), ctx)

        assert render_hook(view, "dismiss", %{"id" => "#{finding.id}"}) =~ @read_only
        assert Repo.reload!(finding).status == "open"
        refute has_element?(view, "[data-role=triage]")
      end
    end

    describe "the board handed to another owner, the board #{how}:" do
      test "Agentic Building saves nothing and releases nothing", ctx do
        {:ok, board} = Boards.update_board(ctx.board, %{"agentic_building" => true})
        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{board}/agentic")
        refute has_element?(view, "#agentic-read-only")

        hand_over(unquote(how), ctx)

        html = render_hook(view, "save", %{"board" => %{"bar_required" => "true"}})

        assert html =~ "Only the board&#39;s owner can change these."
        refute Boards.get_board!(board.id).bar_required
        # Drawn again for somebody who can't change it.
        assert has_element?(view, "#agentic-read-only")
      end

      test "the Automations panel changes no rule", ctx do
        rule =
          rule_fixture(ctx.board, %{
            "trigger" => %{"type" => "card_created"},
            "actions" => [%{"type" => "email", "to" => ctx.writer.email}]
          })

        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/automations")
        assert has_element?(view, "#board-automations")

        hand_over(unquote(how), ctx)

        push(view, "#board-automations", "toggle_rule", %{"id" => "#{rule.id}"})
        push(view, "#board-automations", "delete_rule", %{"id" => "#{rule.id}"})

        assert Automations.get_rule!(rule.id).enabled == rule.enabled
        # The board is read again, and no longer draws its owner's panel.
        refute has_element?(view, "#board-automations")
      end

      test "the Runners panel pauses nothing", ctx do
        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/automations")
        # Opened while still the owner: the pause form is up.
        push(view, "#board-runners", "open_pause", %{})
        assert has_element?(view, "#pause-form")

        hand_over(unquote(how), ctx)

        push(view, "#board-runners", "pause", %{"reason" => "Hold everything"})

        assert Runners.pauses(ctx.board) == []
        refute has_element?(view, "#board-runners")
      end

      test "the Overseer panel saves nothing", ctx do
        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/automations")
        assert has_element?(view, "#board-overseer")

        hand_over(unquote(how), ctx)

        push(view, "#board-overseer", "save", %{"overseer" => %{"enabled" => "true"}})

        refute Overseer.settings(ctx.board).enabled
        refute has_element?(view, "#board-overseer")
      end

      test "the Settings panel saves nothing and shares with nobody", ctx do
        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/settings")
        assert has_element?(view, "#board-settings")
        shared = Repo.aggregate(grants(ctx, ctx.successor), :count)

        hand_over(unquote(how), ctx)

        push(view, "#board-settings", "save_board", %{"board" => %{"name" => "Renamed"}})
        push(view, "#board-settings", "set_board_color", %{"color" => "rose"})

        board = Boards.get_board!(ctx.board.id)
        assert board.name == "Lowered"
        assert board.color == ctx.board.color
        assert Repo.aggregate(grants(ctx, ctx.successor), :count) == shared
        refute has_element?(view, "#board-settings")
      end
    end
  end

  # The grant's row itself, for what gates on owner: a writer was never let
  # in, so there is nothing a lowered grant could leave behind.
  describe "the grant lowered to read, the board untold, on what only an owner changes:" do
    test "Agentic Building refused its writer before, and refuses its reader", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"agentic_building" => true})
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{board}/agentic")
      assert has_element?(view, "#agentic-read-only")

      lower(:untold, ctx)

      assert render_hook(view, "save", %{"board" => %{"bar_required" => "true"}}) =~
               "Only the board&#39;s owner can change these."

      refute Boards.get_board!(board.id).bar_required
    end

    test "the board draws a writer none of its owner's panels", ctx do
      for path <- [~p"/boards/#{ctx.board}/automations", ~p"/boards/#{ctx.board}/settings"] do
        {:ok, view, _} = live(as(ctx.writer), path)

        lower(:untold, ctx)
        render(view)

        for panel <- ~w(#board-automations #board-runners #board-overseer #board-settings),
            do: refute(has_element?(view, panel))

        {:ok, _} = Access.grant(ctx.board, ctx.writer, "write", ctx.owner)
      end
    end
  end

  describe "an owner's panel says why, when the board hasn't heard:" do
    test "Automations, Runners and Overseer", ctx do
      for {target, event, params, said} <- [
            {"#board-automations", "use_example", %{"text" => "x"},
             "Only the board&#39;s owner can do that."},
            {"#board-runners", "open_wizard", %{}, "Only the board&#39;s owner can do that."},
            {"#board-overseer", "save", %{"overseer" => %{"enabled" => "true"}},
             "Only the board&#39;s owner can change the overseer."}
          ] do
        ctx = put_board_back(ctx)
        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/automations")

        hand_over(:untold, ctx)

        assert view |> with_target(target) |> render_hook(event, params) =~ said or
                 render(view) =~ said
      end
    end

    test "Settings", ctx do
      {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/settings")

      hand_over(:untold, ctx)

      view |> with_target("#board-settings") |> render_hook("settings_tab", %{"tab" => "sharing"})
      assert render(view) =~ "Only the board&#39;s owner can do that."
    end
  end

  # The owner's again, for the next panel of a test that hands it over.
  defp put_board_back(ctx) do
    Repo.update_all(from(b in Boards.Board, where: b.id == ^ctx.board.id),
      set: [owner_id: ctx.owner.id]
    )

    ctx
  end

  describe "the grant removed, nobody told:" do
    # A page stops when it sends its reader away.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "Health sends its reader away", ctx do
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/health")
      before = Health.last_run()

      remove(ctx, ctx.writer)

      assert {:error, {:live_redirect, %{to: "/"}}} = render_hook(view, "run", %{})
      assert Health.last_run() == before
    end

    test "Tidy up sends its reader away", ctx do
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/tidy")

      remove(ctx, ctx.writer)

      assert {:error, {:live_redirect, %{to: "/"}}} = render_hook(view, "run", %{})
      assert Gardener.last_run(ctx.board) == nil
    end

    test "Findings sends its reader away, from a read event too", ctx do
      finding = finding(ctx.board)
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/findings")

      remove(ctx, ctx.writer)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               render_hook(view, "dismiss", %{"id" => "#{finding.id}"})

      assert Repo.reload!(finding).status == "open"
    end

    test "Agentic Building sends its reader away", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"agentic_building" => true})
      {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{board}/agentic")

      hand_over(:untold, ctx)
      remove(ctx, ctx.owner)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               render_hook(view, "save", %{"board" => %{"bar_required" => "true"}})

      refute Boards.get_board!(board.id).bar_required
    end
  end

  describe "the board deleted, nobody told:" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "nobody has a level on it, its owner included", ctx do
      {:ok, _} = Boards.delete_board(ctx.board)

      assert Access.board_permission_now(ctx.owner, ctx.board) == :none
      assert Access.board_permission_now(ctx.writer, ctx.board) == :none
    end

    test "Findings opened from a sub-board sends its reader away", ctx do
      [backlog | _] = ctx.board.columns
      card = card_fixture(backlog, %{"title" => "Epic"})
      [template | _] = Boards.Templates.list_templates(ctx.owner)
      {:ok, sub} = sub_board(card, template)
      finding = finding(ctx.board)
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{sub}/findings")

      # The tree's root is still the writer's to write on.
      {:ok, _} = Boards.delete_board(sub)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               render_hook(view, "dismiss", %{"id" => "#{finding.id}"})

      assert Repo.reload!(finding).status == "open"
    end
  end

  test "a reader who was never lowered is still refused, and stays", ctx do
    {:ok, _} = Access.grant(ctx.board, ctx.writer, "read", ctx.owner)
    {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/health")

    assert render_hook(view, "run", %{}) =~ @read_only
    refute render(view) =~ @no_access
  end

  test "a writer who was never lowered still runs the checks", ctx do
    {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/tidy")

    assert render_hook(view, "run", %{}) =~ "Looked the board over"
    assert %Gardener.Run{} = Gardener.last_run(ctx.board)
  end
end
