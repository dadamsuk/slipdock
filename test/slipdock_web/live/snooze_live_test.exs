defmodule SlipdockWeb.SnoozeLiveTest do
  @moduledoc """
  Snooze in the browser (W-1803): the Snooze… picker and its presets in the
  reader's timezone, the in-progress and past-due prompts, waking by hand,
  the list's "N snoozed" footer, select mode, the views that show snoozed
  cards, quick add's `snooze:` and the search badge.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Repo, Snooze, Timezones}
  alias Slipdock.Boards.Card

  # Auckland is far enough from UTC that a preset computed in the wrong
  # timezone shows up as the wrong instant.
  @zone "Pacific/Auckland"

  setup %{user: owner} do
    {:ok, owner} = Accounts.update_profile(owner, %{"timezone" => @zone})
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo, doing | _] = board.columns
    card = card_fixture(todo, %{"title" => "Chase the quote"})
    %{owner: owner, board: board, todo: todo, doing: doing, card: card}
  end

  defp today, do: Timezones.today(@zone)
  defp midnight(date), do: Timezones.to_utc(date, ~T[00:00:00], @zone)
  defp card!(card), do: Repo.get!(Card, card.id)

  defp open(conn, ctx, card \\ nil),
    do: live(conn, ~p"/boards/#{ctx.board}/cards/#{(card || ctx.card).id}")

  describe "the picker" do
    test "Snooze… on the card offers presets in the reader's timezone; tomorrow snoozes", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      assert has_element?(view, "#snooze-open", "Snooze…")
      view |> element("#snooze-open") |> render_click()

      tomorrow = Date.add(today(), 1)
      assert has_element?(view, "#snooze-picker", "Snooze Chase the quote")
      # The picker stands in for the card: the card's click-away would
      # otherwise close it on every click inside the picker.
      refute has_element?(view, "#card-modal")

      assert has_element?(
               view,
               ~s|#snooze-tomorrow[data-snooze-key="z"]|,
               Calendar.strftime(tomorrow, "%a %-d %b")
             )

      assert has_element?(view, ~s|#snooze-monday[data-snooze-key="m"]|)
      assert has_element?(view, ~s|#snooze-week[data-snooze-key="w"]|)
      assert has_element?(view, ~s|#snooze-month[data-snooze-key="n"]|)

      view |> element("#snooze-tomorrow") |> render_click()

      assert card!(ctx.card).snoozed_until == midnight(tomorrow)
      refute has_element?(view, "#snooze-picker")
      assert render(view) =~ "Snoozed 1 card until"
      # The open card says so, and offers to wake it.
      assert has_element?(view, "#snooze-current", Calendar.strftime(tomorrow, "%a %-d %b %Y"))
      assert has_element?(view, "#snooze-wake")
    end

    test "a day of one's own, with a note and notify", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#snooze-open") |> render_click()
      day = Date.add(today(), 20)

      view
      |> form("#snooze-form",
        snooze: %{date: Date.to_iso8601(day), note: "after the audit", notify: "true"}
      )
      |> render_submit()

      card = card!(ctx.card)
      assert card.snoozed_until == midnight(day)
      assert card.snooze_note == "after the audit"
      assert card.snooze_notify
      assert has_element?(view, "#snooze-note", "after the audit")
    end

    test "the note typed survives choosing a preset", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#snooze-open") |> render_click()
      view |> form("#snooze-form", snooze: %{note: "vendor"}) |> render_change()
      view |> element("#snooze-week") |> render_click()
      assert card!(ctx.card).snooze_note == "vendor"
    end

    test "no day, or one in the past, is refused in the picker", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#snooze-open") |> render_click()

      view |> form("#snooze-form", snooze: %{date: ""}) |> render_submit()
      assert has_element?(view, "#snooze-error", "Pick a day to wake it.")

      view
      |> form("#snooze-form", snooze: %{date: Date.to_iso8601(Date.add(today(), -1))})
      |> render_submit()

      assert has_element?(view, "#snooze-error", "the snooze must end in the future")
      refute Card.snoozed?(card!(ctx.card))
    end

    test "an in-progress card is offered a move back to the ready list", ctx do
      first = card_fixture(ctx.todo, %{"title" => "Already there"})
      busy = card_fixture(ctx.doing, %{"title" => "Busy"})
      {:ok, view, _} = open(ctx.conn, ctx, busy)
      view |> element("#snooze-open") |> render_click()
      assert has_element?(view, "#snooze-back", "It's in progress. Move it back to To Do?")

      view |> element("#snooze-week") |> render_click()
      # The open card still shows, snoozed, after its move.
      assert has_element?(view, "#snooze-current")
      busy = card!(busy)
      assert Card.snoozed?(busy)
      assert busy.column_id == ctx.todo.id
      assert hd(Slipdock.Boards.active_items(ctx.todo.id)) == {:card, busy.id}
      assert card!(first).column_id == ctx.todo.id
    end

    test "unticking the move leaves it where it is", ctx do
      busy = card_fixture(ctx.doing, %{"title" => "Busy"})
      {:ok, view, _} = open(ctx.conn, ctx, busy)
      view |> element("#snooze-open") |> render_click()
      view |> form("#snooze-form", snooze: %{back: "false"}) |> render_change()
      view |> element("#snooze-week") |> render_click()
      assert card!(busy).column_id == ctx.doing.id
    end

    test "a card due before the day picked warns", ctx do
      due = Date.add(today(), 3)
      card = card_fixture(ctx.todo, %{"due_date" => Date.to_iso8601(due)})
      {:ok, view, _} = open(ctx.conn, ctx, card)
      view |> element("#snooze-open") |> render_click()

      assert has_element?(view, "#snooze-due", "Due #{Calendar.strftime(due, "%a %-d %b")}")
      assert has_element?(view, "#snooze-week", "past due")
      refute has_element?(view, "#snooze-tomorrow", "past due")
    end

    test "Escape and the close button cancel; the card stays awake", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#snooze-open") |> render_click()
      render_hook(view, "cancel_snooze", %{})
      refute has_element?(view, "#snooze-picker")
      refute Card.snoozed?(card!(ctx.card))
    end

    test "a completed card offers no Snooze…", ctx do
      done = card_fixture(ctx.todo, %{"completed" => true})
      {:ok, view, _} = open(ctx.conn, ctx, done)
      refute has_element?(view, "#snooze-open")
    end

    test "z: the event takes a card on this board only, and a writer only", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      render_hook(view, "open_snooze", %{"id" => to_string(ctx.card.id)})
      assert has_element?(view, "#snooze-picker")
      render_hook(view, "cancel_snooze", %{})

      other = card_fixture(hd(board_fixture().columns))

      assert render_hook(view, "open_snooze", %{"id" => to_string(other.id)}) =~
               "Pick an open card to snooze."

      refute has_element?(view, "#snooze-picker")

      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{ctx.board}")

      assert render_hook(view, "open_snooze", %{"id" => to_string(ctx.card.id)}) =~
               "read-only access"

      assert render_hook(view, "wake_card", %{"id" => to_string(ctx.card.id)}) =~
               "read-only access"
    end
  end

  describe "on the board" do
    setup ctx do
      {:ok, asleep} =
        Snooze.snooze(card_fixture(ctx.todo, %{"title" => "Asleep"}), ctx.owner, "next week")

      %{asleep: asleep}
    end

    test "a list leaves its snoozed cards out, and its footer shows them faded", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      col = ctx.todo.id

      refute has_element?(view, "#cards-#{col} #card-#{ctx.asleep.id}")
      assert has_element?(view, "#cards-#{col} #card-#{ctx.card.id}")
      assert has_element?(view, "#snoozed-#{col}", "1 snoozed")
      refute has_element?(view, "#snoozed-cards-#{col}")

      view |> element("#snoozed-#{col}") |> render_click()
      assert has_element?(view, "#snoozed-cards-#{col} #snoozed-card-#{ctx.asleep.id}.opacity-60")

      assert has_element?(
               view,
               ~s|#snoozed-card-#{ctx.asleep.id} [data-role="snooze-mark"]|,
               ctx.asleep.snoozed_until
               |> Timezones.to_local(@zone)
               |> Calendar.strftime("%-d %b")
             )

      view |> element("#snoozed-#{col}") |> render_click()
      refute has_element?(view, "#snoozed-cards-#{col}")
    end

    test "Wake now brings it back to the top of its list", ctx do
      {:ok, view, _} = open(ctx.conn, ctx, ctx.asleep)
      view |> element("#snooze-wake") |> render_click()
      refute Card.snoozed?(card!(ctx.asleep))
      refute has_element?(view, "#snooze-current")
      assert has_element?(view, "#cards-#{ctx.todo.id} #card-#{ctx.asleep.id}")
    end

    test "select mode snoozes every card picked out", ctx do
      other = card_fixture(ctx.todo, %{"title" => "Other"})
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      render_hook(view, "toggle_select_mode", %{})
      render_hook(view, "open_card", %{"id" => to_string(ctx.card.id)})
      render_hook(view, "open_card", %{"id" => to_string(other.id)})

      view |> element("#bulk-snooze") |> render_click()
      assert has_element?(view, "#snooze-picker", "Snooze 2 cards")
      view |> element("#snooze-month") |> render_click()

      assert Card.snoozed?(card!(ctx.card))
      assert Card.snoozed?(card!(other))
      assert render(view) =~ "Snoozed 2 cards until"
      assert has_element?(view, "#bulk-count", "Click cards to select them")
    end

    test "the table shows snoozed cards only with Show snoozed on", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")
      refute render(view) =~ "Asleep"
      assert has_element?(view, "#display-snoozed")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table?snoozed=show")
      assert render(view) =~ "Asleep"
    end

    test "the calendar always shows them, by their own dates", ctx do
      {:ok, _} =
        Slipdock.Boards.update_card(card!(ctx.asleep), %{
          "due_date" => Date.to_iso8601(Date.utc_today())
        })

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/calendar")
      assert render(view) =~ "Asleep"
    end
  end

  describe "quick add" do
    test "snooze: adds the card asleep, with a chip while typing", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/table")

      html =
        view
        |> form("#table-add", %{"title" => "Renew the domain snooze: tomorrow"})
        |> render_change()

      tomorrow = Date.add(today(), 1)
      assert html =~ "💤 " <> Calendar.strftime(tomorrow, "%a %-d %b")

      view
      |> form("#table-add", %{"title" => "Renew the domain snooze: tomorrow"})
      |> render_submit()

      card = Repo.get_by!(Card, title: "Renew the domain")
      assert card.snoozed_until == midnight(tomorrow)
    end
  end

  describe "search" do
    test "a snoozed card is still found, marked with the day it wakes", ctx do
      Slipdock.AIStub.stub_embeddings()

      {:ok, asleep} =
        Snooze.snooze(
          card_fixture(ctx.todo, %{"title" => "Invoice rounding is wrong on refunds"}),
          ctx.owner,
          "next week"
        )

      {:ok, _} = Slipdock.Search.index_cards(Slipdock.Search.load_cards([asleep.id]))
      {:ok, view, _} = live(ctx.conn, ~p"/search")
      view |> form("#deep-search") |> render_change(%{"q" => "invoice rounding refunds"})
      html = render_async(view)

      assert html =~ "Invoice rounding is wrong on refunds"

      assert html =~
               "💤 until " <>
                 (asleep.snoozed_until
                  |> Timezones.to_local(@zone)
                  |> Calendar.strftime("%a %-d %b"))
    end
  end
end
