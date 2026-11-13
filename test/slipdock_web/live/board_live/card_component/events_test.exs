defmodule SlipdockWeb.BoardLive.CardComponent.EventsTest do
  @moduledoc """
  The card panel's events, in the modules `BoardLive.CardComponent` hands
  them to: that between them they handle the panel's own events and each is
  reached, and what a card form's change, a logged time and the Repeat…
  form's opening do with what they are sent.

  The clauses are called as the component calls them, with a socket holding
  what they read.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Recurrence, Wiki}
  alias Slipdock.Boards.Card
  alias SlipdockWeb.BoardLive.{CardComponent, ItemEvents}

  alias SlipdockWeb.BoardLive.CardComponent.{
    FieldEvents,
    HandoffEvents,
    LinkEvents,
    RepeatEvents,
    WaitEvents
  }

  @modules [FieldEvents, WaitEvents, HandoffEvents, RepeatEvents, LinkEvents]

  setup %{user: user} do
    board = board_fixture(%{}, owner: user)
    [first, second | _] = board.columns

    card =
      card_fixture(first, %{
        "title" => "Review invoices",
        "start_date" => "2027-01-05",
        "due_date" => "2027-01-12"
      })

    %{board: board, first: first, second: second, card: card}
  end

  # The component's socket, as far as the event clauses read it.
  defp socket(ctx, assigns \\ %{}) do
    held = %{
      __changed__: %{},
      board: reload(ctx.board),
      card: Boards.Cards.get_card!(ctx.card.id),
      current_user: ctx.user,
      can_write: true,
      form_key: 0,
      panel_notice: nil,
      uploads: %{desc_image: %{entries: []}}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(held, assigns)}
  end

  defp change(ctx, fields, extra \\ %{}) do
    {:noreply, socket} =
      FieldEvents.handle_event("card_change", Map.put(extra, "card", fields), socket(ctx))

    socket
  end

  defp stored(ctx), do: Boards.Cards.get_card!(ctx.card.id)

  defp card_panel(view), do: with_target(view, "#board-card")

  describe "the event modules" do
    test "between them handle the panel's own events, each in one module" do
      handled = Enum.flat_map(@modules, & &1.events())

      assert handled == Enum.uniq(handled)
      assert Enum.sort(handled) == Enum.sort(CardComponent.events() -- ItemEvents.events())
    end

    test "an event of each module, and one of the shared sections', reaches it", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      view |> card_panel() |> render_hook("set_cover", %{"color" => "sky"})
      assert stored(ctx).color == "sky"

      view
      |> card_panel()
      |> render_hook("ask_save", %{"ask" => %{"questions" => %{"1" => "Which one?"}}})

      assert Card.open_wait(stored(ctx))

      view |> card_panel() |> render_hook("edit_handoff", %{})
      assert has_element?(view, "#handoff-form")

      view |> card_panel() |> render_hook("edit_repeat", %{})
      assert has_element?(view, "#repeat-form")

      view |> card_panel() |> render_hook("add_check", %{"text" => "Count them"})
      assert [%{text: "Count them"}] = stored(ctx).checklist_items

      view |> card_panel() |> render_hook("write_up", %{})
      assert [_page] = Wiki.pages_for_card(stored(ctx), ctx.user)
    end
  end

  describe "card_change" do
    test "changes the fields the form carries and no others", ctx do
      socket = change(ctx, %{"title" => "Review the invoices", "color" => "rose"})

      assert %{title: "Review the invoices", color: nil} = stored(ctx)
      # The panel holds the card as it now is.
      assert socket.assigns.card.title == "Review the invoices"
      assert socket.assigns.panel_notice == nil
    end

    test "a blank date, percentage or assignee clears it", ctx do
      {:ok, _} =
        Boards.Cards.update_card(ctx.card, %{
          "percent_complete" => 40,
          "assignee_id" => ctx.user.id
        })

      assert %{percent_complete: 40, assignee_id: id} = stored(ctx)
      assert id == ctx.user.id

      change(ctx, %{"start_date" => ""})
      assert %{start_date: nil, due_date: ~D[2027-01-12]} = stored(ctx)

      change(ctx, %{"due_date" => ""})
      assert stored(ctx).due_date == nil

      change(ctx, %{"percent_complete" => ""})
      assert stored(ctx).percent_complete == nil

      change(ctx, %{"assignee_id" => ""})
      assert stored(ctx).assignee_id == nil
    end

    test "Add someone puts a person on the card beside whoever is there", ctx do
      ada = user_fixture("ada@example.com")
      share_fixture(ctx.board, [ada])
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"assignee_id" => ctx.user.id})

      change(ctx, %{"add_assignee_id" => to_string(ada.id)})

      assert stored(ctx) |> Card.assignees() |> Enum.map(& &1.id) == [ctx.user.id, ada.id]
    end

    test "somebody who can't open the card isn't put on it, and nothing else changes", ctx do
      stranger = user_fixture("stranger@example.com")

      socket = change(ctx, %{"title" => "Theirs now", "assignee_id" => to_string(stranger.id)})

      assert socket.assigns.panel_notice == {:error, "That person can't be put on this card."}
      assert %{title: "Review invoices", assignee_id: nil} = stored(ctx)
    end

    test "the marker of an image still uploading is left out of the description", ctx do
      change(ctx, %{"description" => "Before\n![Uploading image…]()\nAfter"})

      assert stored(ctx).description == "Before\nAfter"
    end

    test "of the time fields, only the one that changed goes through", ctx do
      time = %{"time_spent" => "2", "time_estimate" => "3", "time_unit" => "days"}

      change(ctx, time, %{"_target" => ["card", "time_spent"]})
      assert %{time_spent: 120, time_estimate: nil, time_unit: "hours"} = stored(ctx)

      change(ctx, time, %{"_target" => ["card", "time_unit"]})
      assert %{time_spent: 120, time_estimate: nil, time_unit: "days"} = stored(ctx)

      # A field of another form, or no target at all, sends no time.
      change(ctx, %{time | "time_spent" => "5"}, %{"_target" => ["card", "title"]})
      change(ctx, %{time | "time_spent" => "5"})
      assert %{time_spent: 120, time_estimate: nil} = stored(ctx)
    end

    test "another list moves the card there, as the person at the page", ctx do
      change(ctx, %{"column_id" => to_string(ctx.second.id)})

      assert stored(ctx).column_id == ctx.second.id

      move =
        Slipdock.Repo.get_by!(Slipdock.Boards.CardMove,
          card_id: ctx.card.id,
          kind: "moved",
          to_column_id: ctx.second.id
        )

      assert {move.user_id, move.actor_kind, move.via} == {ctx.user.id, "human", "web"}
    end

    test "its own list, no list or something that isn't one moves nothing", ctx do
      later = card_fixture(ctx.first, %{"title" => "Later"})

      order = fn ->
        reload(ctx.board).columns |> hd() |> Map.fetch!(:cards) |> Enum.map(& &1.id)
      end

      moves = fn ->
        Slipdock.Repo.aggregate(
          from(m in Slipdock.Boards.CardMove, where: m.card_id == ^ctx.card.id),
          :count
        )
      end

      assert order.() == [ctx.card.id, later.id]
      before = moves.()

      for column <- [to_string(ctx.first.id), "", "the last one"] do
        change(ctx, %{"column_id" => column})

        assert order.() == [ctx.card.id, later.id]
        assert moves.() == before
      end
    end

    test "a change the card refuses is shown in its form, and the card kept", ctx do
      socket = change(ctx, %{"start_date" => "2027-02-01"})

      assert socket.assigns.card_form.errors != []
      assert socket.assigns.card.start_date == ~D[2027-01-05]
      assert stored(ctx).start_date == ~D[2027-01-05]
    end
  end

  describe "log_time" do
    test "adds the time to what is spent and clears the box", ctx do
      {:noreply, socket} =
        FieldEvents.handle_event("log_time", %{"amount" => "1.5h"}, socket(ctx))

      assert stored(ctx).time_spent == 90
      assert socket.assigns.card.time_spent == 90
      assert socket.assigns.form_key == 1
      assert socket.assigns.panel_notice == nil
    end

    test "says so when the amount isn't a time", ctx do
      {:noreply, socket} =
        FieldEvents.handle_event("log_time", %{"amount" => "a while"}, socket(ctx))

      assert socket.assigns.panel_notice ==
               {:error, "Couldn't read “a while” as a time — try 45m, 1.5h or 2d."}

      assert socket.assigns.form_key == 0
      assert stored(ctx).time_spent in [nil, 0]
    end

    test "is refused for a reader who can't change the card", ctx do
      {:noreply, socket} =
        FieldEvents.handle_event(
          "log_time",
          %{"amount" => "1h"},
          socket(ctx, %{can_write: false})
        )

      assert socket.assigns.panel_notice == {:error, "You have read-only access to that card."}
      assert stored(ctx).time_spent in [nil, 0]
    end
  end

  describe "edit_repeat" do
    defp repeat_form(ctx) do
      {:noreply, socket} = RepeatEvents.handle_event("edit_repeat", %{}, socket(ctx))
      socket.assigns.repeat.form.params
    end

    test "a card with no series opens on weekly on its day, at seven", ctx do
      # Tuesday 12 January 2027 is the card's due date.
      assert repeat_form(ctx) == %{
               "preset" => "FREQ=WEEKLY;BYDAY=TU",
               "custom" => "",
               "at" => "07:00"
             }
    end

    test "a series on a preset opens on it, with its own settings", ctx do
      {:ok, _} =
        Recurrence.set(
          ctx.card,
          %{
            "rule" => "FREQ=DAILY",
            "at" => "08:30",
            "lead_days" => 2,
            "on_missed" => "stack",
            "ends" => "after",
            "count" => 6
          },
          ctx.user
        )

      assert repeat_form(ctx) == %{
               "preset" => "FREQ=DAILY",
               "custom" => "",
               "at" => "08:30",
               "lead_days" => "2",
               "on_missed" => "stack",
               "ends" => "after",
               "ends_on" => nil,
               "count" => "6"
             }
    end

    test "a series on a rule of its own opens on Custom, with the rule and its end date", ctx do
      {:ok, series} =
        Recurrence.set(
          ctx.card,
          %{"rule" => "2w mon thu", "ends" => "on", "ends_on" => "2027-06-01"},
          ctx.user
        )

      refute series.rule in Enum.map(Recurrence.presets(ctx.card.due_date), &elem(&1, 0))

      assert %{
               "preset" => "custom",
               "custom" => rule,
               "ends" => "on",
               "ends_on" => "2027-06-01",
               "count" => nil
             } = repeat_form(ctx)

      assert rule == series.rule
    end
  end

  describe "the modal's parts" do
    test "a subcard's panel links back to its parent card and that card's board", ctx do
      {:ok, template} = Boards.Templates.find_template(nil, "Sprint planning")
      {:ok, sub} = Boards.create_sub_board(ctx.card, template)
      child = card_fixture(hd(reload(sub).columns), %{"title" => "A part of it"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{sub}/cards/#{child.id}")

      assert has_element?(
               view,
               ~s|#card-parent a[href="/boards/#{ctx.board.id}/cards/#{ctx.card.id}"]|,
               "Review invoices"
             )

      assert has_element?(
               view,
               ~s|#card-parent a[href="/boards/#{ctx.board.id}"]|,
               ctx.board.name
             )
    end

    test "a card that is nobody's subcard has no parent line", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      refute has_element?(view, "#card-parent")
      # Its sections are drawn, and a reader who can't change it finds them disabled.
      assert has_element?(view, "#card-modal fieldset:not([disabled]) #card-attachments")
    end

    test "the sections follow what the reader may do", ctx do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)

      {:ok, view, _} =
        live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      assert has_element?(view, "#card-modal fieldset[disabled] #card-attachments")
    end
  end
end
