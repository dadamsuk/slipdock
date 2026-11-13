defmodule SlipdockWeb.ModalNoticeLiveTest do
  @moduledoc """
  UX-29 (#1978): the board's other modals (runners, move to another board,
  archive, tags) say what an action did in a callout inside the modal, never
  a flash, and the next action takes it away. The flashes left in the move
  picker (a read-only `open_move_board`, and the move done, on the board or
  carried by the navigation that follows an open card) close it or never
  open it: the last is asserted here, the others in
  `move_board_live_test.exs`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo, Runners, Settings}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Modals"}, owner: user)
    %{board: board}
  end

  defp refute_flash(view) do
    refute has_element?(view, "#flash-error")
    refute has_element?(view, "#flash-info")
  end

  describe "runners" do
    defp runners(view), do: with_target(view, "#board-runners")

    test "an unknown event and a refused resume are callouts, cleared by the next action",
         ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
      refute has_element?(view, "#board-runners #panel-notice")

      render_click(runners(view), "no_such_event", %{})

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=error]",
               "That isn't something this page can do."
             )

      refute_flash(view)

      # Nothing is paused, so resuming is refused, and said in the panel.
      render_click(runners(view), "resume", %{})

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=error]",
               "the whole tree is not paused"
             )

      refute_flash(view)

      view |> element("#pause-tree") |> render_click()
      refute has_element?(view, "#panel-notice")
    end

    test "a pause and a revoke say what they did in the panel", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      view |> element("#pause-tree") |> render_click()
      view |> form("#pause-form", %{"reason" => "Deploy freeze"}) |> render_submit()

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=info]",
               "Paused the whole tree"
             )

      view |> element("#runner-#{runner.id} button[title=Revoke]") |> render_click()

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=info]",
               "Runner “box” revoked"
             )

      refute_flash(view)

      # The runner is gone now: asking for it again is a refusal in the panel.
      render_click(runners(view), "show_runner", %{"id" => runner.id})

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=error]",
               "That runner is gone."
             )
    end

    test "a new token is said in the runner dialog it was made from", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      render_click(runners(view), "regenerate", %{"id" => runner.id})
      render_click(runners(view), "rotate_token", %{"id" => runner.id})

      assert has_element?(
               view,
               "#runner-dialog #panel-notice[data-callout=info]",
               "New token made: the old one no longer works."
             )

      # One notice at a time: the section's is not drawn behind the dialog.
      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#panel-notice")
             |> length() ==
               1

      refute_flash(view)
    end

    test "a runner that is gone is said in the panel: regenerate and revoke", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
      {:ok, _} = Runners.delete_runner(runner)

      for event <- ~w(regenerate revoke_runner) do
        # An event that says nothing in between, so each callout is its own.
        render_click(runners(view), "cancel_pause", %{})
        refute has_element?(view, "#panel-notice")

        render_click(runners(view), event, %{"id" => runner.id})

        assert has_element?(
                 view,
                 "#board-runners #panel-notice[data-callout=error]",
                 "That runner is gone."
               )

        refute has_element?(view, "#runner-dialog")
      end

      refute_flash(view)
    end

    test "a new token for a runner gone since its dialog opened is refused in the dialog",
         ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      render_click(runners(view), "regenerate", %{"id" => runner.id})
      assert has_element?(view, "#runner-dialog")
      {:ok, _} = Runners.delete_runner(runner)

      render_click(runners(view), "rotate_token", %{"id" => runner.id})

      assert has_element?(
               view,
               "#runner-dialog #panel-notice[data-callout=error]",
               "That runner is gone."
             )

      refute_flash(view)
    end

    test "a refused pause is said in the panel: no reason, then already paused", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      # The form's button waits for a reason; the event sent without one is
      # refused by the pause's own changeset.
      render_click(runners(view), "open_pause", %{})
      render_click(runners(view), "pause", %{"reason" => ""})

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=error]",
               "Not paused: reason can't be blank: say why it is paused"
             )

      assert Runners.pauses(ctx.board) == []
      refute_flash(view)

      # Paused from somewhere else while the form is open: refused by name.
      {:ok, _} = Runners.pause(ctx.board, %{"reason" => "Deploy freeze"}, ctx.user)
      render_click(runners(view), "pause", %{"reason" => "Mine"})

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=error]",
               "the whole tree is already paused"
             )

      assert [%{reason: "Deploy freeze"}] = Runners.pauses(ctx.board)
      refute_flash(view)
    end

    test "a resume says what it did in the panel", ctx do
      {:ok, _} = Runners.pause(ctx.board, %{"reason" => "Deploy freeze"}, ctx.user)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      view |> element("#resume-tree") |> render_click()

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=info]",
               "Resumed the whole tree."
             )

      assert Runners.pauses(ctx.board) == []
      refute_flash(view)
    end

    test "someone who no longer owns the board is refused in the panel", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      # The board changes hands, and the section hears of it before the page
      # has closed the panel.
      other = user_fixture("new-owner@example.com")
      board = ctx.board |> Ecto.Changeset.change(owner_id: other.id) |> Repo.update!()

      Phoenix.LiveView.send_update(view.pid, SlipdockWeb.BoardLive.RunnersComponent,
        id: "board-runners-panel",
        board: board,
        current_user: ctx.user
      )

      render_click(runners(view), "revoke_runner", %{"id" => runner.id})

      assert has_element?(
               view,
               "#board-runners #panel-notice[data-callout=error]",
               "Only the board's owner can do that."
             )

      assert {:ok, _} = Runners.find_runner(board, runner.id)
      refute_flash(view)
    end
  end

  describe "move to another board" do
    setup %{user: user, board: board} do
      card = card_fixture(hd(board.columns), %{"title" => "Call the printers"})
      other = user_fixture("theirs@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: other)
      {:ok, _} = Access.grant(theirs, user, "write", other)
      %{card: card, other: other, theirs: theirs}
    end

    defp open_picker(view, card) do
      view
      |> element("#move-menu-#{card.id} button[phx-click=open_move_board]")
      |> render_click()
    end

    test "a refusal in the open picker is a callout, and the picker stays open", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      open_picker(view, ctx.card)

      view
      |> element("button[phx-click=move_board_pick][phx-value-id='#{ctx.theirs.id}']")
      |> render_click()

      # Write access is taken away while the picker is open.
      {:ok, _} = Access.grant(ctx.theirs, ctx.user, "read", ctx.other)

      view
      |> element(
        "button[phx-click=move_card_board][phx-value-column='#{hd(ctx.theirs.columns).id}']"
      )
      |> render_click()

      assert has_element?(
               view,
               "#move-board-modal #panel-notice[data-callout=error]",
               "You have read-only access to that board."
             )

      refute_flash(view)
      assert Boards.Cards.get_card!(ctx.card.id).board_id == ctx.board.id

      # The next action takes it away.
      view
      |> with_target("#board-move")
      |> render_click("move_board_pick", %{"id" => to_string(ctx.theirs.id)})

      assert has_element?(view, "#move-board-modal")
      refute has_element?(view, "#panel-notice")
    end

    test "an unknown event is a callout in the open picker", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      open_picker(view, ctx.card)

      view |> with_target("#board-move") |> render_click("no_such_event", %{})

      assert has_element?(
               view,
               "#move-board-modal #panel-notice[data-callout=error]",
               "That isn't something this page can do."
             )

      refute_flash(view)
    end

    test "a move the far board has no room for is a callout, and the picker stays open",
         ctx do
      # One item each: the far board's owner already has theirs.
      {:ok, _} =
        Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 1})

      card_fixture(hd(ctx.theirs.columns), %{"title" => "Their only one"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      open_picker(view, ctx.card)

      view
      |> element("button[phx-click=move_board_pick][phx-value-id='#{ctx.theirs.id}']")
      |> render_click()

      view
      |> element(
        "button[phx-click=move_card_board][phx-value-column='#{hd(ctx.theirs.columns).id}']"
      )
      |> render_click()

      assert has_element?(
               view,
               "#move-board-modal #panel-notice[data-callout=error]",
               "This board's owner has used all 1 of their cards, pages and files."
             )

      refute_flash(view)
      assert Boards.Cards.get_card!(ctx.card.id).board_id == ctx.board.id
    end

    test "a move the board refuses by name is a callout, and the picker stays open", ctx do
      {:ok, archived} = Boards.Cards.archive_card(ctx.card)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      view
      |> with_target("#board-move")
      |> render_click("open_move_board", %{"id" => to_string(archived.id)})

      view
      |> element("button[phx-click=move_board_pick][phx-value-id='#{ctx.theirs.id}']")
      |> render_click()

      view
      |> element(
        "button[phx-click=move_card_board][phx-value-column='#{hd(ctx.theirs.columns).id}']"
      )
      |> render_click()

      assert has_element?(
               view,
               "#move-board-modal #panel-notice[data-callout=error]",
               "Restore the card before moving it."
             )

      refute_flash(view)
      assert Boards.Cards.get_card!(ctx.card.id).board_id == ctx.board.id
    end

    # The exception (`panel_no_flash_test.exs`): the picker closes and the
    # open card is followed to its new board, so the result travels as a
    # flash with that navigation.
    test "the move of an open card is said in a flash carried to its new board", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      view |> element("#card-move-board") |> render_click()

      view
      |> element("button[phx-click=move_board_pick][phx-value-id='#{ctx.theirs.id}']")
      |> render_click()

      view
      |> element(
        "button[phx-click=move_card_board][phx-value-column='#{hd(ctx.theirs.columns).id}']"
      )
      |> render_click()

      {path, flash} = assert_redirect(view)
      assert path == ~p"/boards/#{ctx.theirs.id}/cards/#{ctx.card.id}"
      assert flash["info"] =~ "Call the printers"
      assert flash["info"] =~ "Theirs"
    end
  end

  describe "archive" do
    setup %{board: board} do
      card = card_fixture(hd(board.columns), %{"title" => "Old news"})
      {:ok, card} = Boards.Cards.archive_card(card)
      %{card: card}
    end

    test "an unknown event is a callout, and the next action clears it", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/archive")

      view |> with_target("#board-archive") |> render_click("no_such_event", %{})

      assert has_element?(
               view,
               "#archive-modal #panel-notice[data-callout=error]",
               "That isn't something this page can do."
             )

      refute_flash(view)

      view |> form("#archive-search", %{"q" => "Old"}) |> render_change()
      refute has_element?(view, "#panel-notice")
    end

    test "a reader's restore is refused in the modal", ctx do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)
      {:ok, view, _} = live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/archive")

      view
      |> with_target("#board-archive")
      |> render_click("restore_card", %{"id" => to_string(ctx.card.id)})

      assert has_element?(
               view,
               "#archive-modal #panel-notice[data-callout=error]",
               "You have read-only access to this board."
             )

      refute_flash(view)
      assert Boards.Cards.get_card!(ctx.card.id).archived_at
    end
  end

  test "tags: an unknown event is said in the panel's callout", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/tags")

    view |> with_target("#board-tags") |> render_click("no_such_event", %{})

    assert has_element?(
             view,
             "#tags-modal #tags-error[data-callout=error]",
             "That isn't something this page can do."
           )

    refute_flash(view)
  end
end
