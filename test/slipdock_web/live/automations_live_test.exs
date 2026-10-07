defmodule SlipdockWeb.AutomationsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Automations

  setup do
    board = board_fixture(%{"name" => "Launch"})
    [backlog, doing, _review, done] = board.columns
    %{board: board, backlog: backlog, doing: doing, done: done}
  end

  describe "the automations panel" do
    test "lists recent callbacks and adds new ones as they land", %{conn: conn, board: board} do
      log = fn n, status ->
        Automations.log_callback(%{
          board_id: board.id,
          rule_name: "Tell the robot",
          card_title: "Card #{n}",
          method: "POST",
          url: "https://example.com/hook/#{n}",
          status: status,
          error: if(status != 200, do: "HTTP #{status}")
        })
      end

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")
      refute has_element?(view, "#callback-log")

      # The view refreshes the panel with send_update, a second message to
      # itself, so one render round-trip first lets that land.
      log.(1, 200)
      render(view)
      assert has_element?(view, "#callback-log", "https://example.com/hook/1")
      assert has_element?(view, "#callback-log", "Tell the robot")

      log.(2, 503)
      render(view)
      assert has_element?(view, "#callback-log", "HTTP 503")
      assert has_element?(view, "#callback-log", "Card 2")
    end

    test "opens from the board menu and describes what rules are for", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      assert view |> element("header a[href*='/automations']") |> render_click() =~ "Automations"
      assert has_element?(view, "#automations-modal", "describe what should happen")
      assert has_element?(view, "#automations-modal", "No rules yet.")
    end

    test "writes a rule from a sentence and shows what it will do", %{
      conn: conn,
      board: board,
      doing: doing
    } do
      Slipdock.AIStub.reply_with(%{
        "name" => "Tell ops about new work",
        "spec" => %{
          "trigger" => %{"type" => "card_created", "column" => doing.name},
          "actions" => [
            %{"type" => "email", "to" => "tester@example.com", "subject" => "{{card.title}}"}
          ]
        }
      })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")

      view
      |> form("#rule-form", %{
        "text" => "when creating a new card in #{doing.name}, email tester@example.com"
      })
      |> render_submit()

      html = render_async(view)
      assert html =~ "Tell ops about new work"
      assert html =~ "When a card is added to #{doing.name}, email tester@example.com."

      assert [rule] = Automations.list_rules(board.id)
      assert rule.source =~ "tester@example.com"
    end

    test "a rule the model got wrong is reported, not saved", %{conn: conn, board: board} do
      Slipdock.AIStub.reply_with(%{"error" => "There's no list called Sprint on this board."})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")
      view |> form("#rule-form", %{"text" => "move everything to Sprint"}) |> render_submit()

      assert render_async(view) =~ "There&#39;s no list called Sprint on this board."
      assert Automations.list_rules(board.id) == []
    end

    test "rules can be turned off, reworded and deleted", %{
      conn: conn,
      board: board,
      doing: doing
    } do
      rule =
        rule_fixture(
          board,
          %{
            "trigger" => %{"type" => "card_created"},
            "actions" => [%{"type" => "add_flags", "flags" => ["review"]}]
          },
          %{"name" => "Flag new cards", "source" => "flag every new card for review"}
        )

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/automations")
      assert html =~ "Flag new cards"
      assert html =~ "flag every new card for review"

      view |> element("#rule-#{rule.id} input[type=checkbox]") |> render_click()
      refute Automations.get_rule!(rule.id).enabled

      # Turned off, the rule leaves new cards alone.
      card_fixture(doing)
      assert Automations.get_rule!(rule.id).run_count == 0

      view |> element("#rule-#{rule.id} button[phx-click=edit_rule]") |> render_click()
      assert has_element?(view, "#rule-form textarea", "flag every new card for review")

      view |> element("#rule-#{rule.id} button[phx-click=delete_rule]") |> render_click()
      assert Automations.list_rules(board.id) == []
    end

    test "a timed rule can be run by hand", %{conn: conn, board: board, backlog: backlog} do
      rule_fixture(board, %{
        "trigger" => %{"type" => "card_overdue"},
        "actions" => [
          %{"type" => "alert", "title" => "Overdue: {{card.title}}", "severity" => "urgent"}
        ]
      })

      card_fixture(backlog, %{
        "title" => "Late thing",
        "due_date" => Date.to_iso8601(Date.add(Date.utc_today(), -3))
      })

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")
      view |> element("button[phx-click=run_rule]") |> render_click()
      assert render(view) =~ "ran once"

      # The alert it raised reaches the header bar of the page that ran it.
      view |> element("#alerts-bar button[phx-click=toggle_alerts]") |> render_click()
      assert render(view) =~ "Overdue: Late thing"
    end

    test "someone with read-only access can't manage rules", %{conn: _conn, board: board} do
      reader = user_fixture("reader@example.com")
      Slipdock.Access.grant(board, reader, "read", user_fixture())

      {:ok, view, html} = live(conn_as(reader), ~p"/boards/#{board}/automations")
      refute html =~ "automations-modal"
      refute has_element?(view, "a[href*='/automations']")
    end
  end

  describe "ready-made rules" do
    test "a preset is picked, filled in and added without the AI", %{
      conn: conn,
      board: board,
      doing: doing
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")

      view |> element("#rule-preset-follow_list") |> render_click()
      assert has_element?(view, "#rule-preset-form", "Follow a list")

      html =
        view
        |> form("#rule-preset-form", %{"preset" => %{"column" => doing.name, "notify" => "alert"}})
        |> render_submit()

      assert html =~ "Followed: #{doing.name}"
      refute has_element?(view, "#rule-preset-form")

      assert [rule] = Automations.list_rules(board.id)
      assert rule.spec["trigger"] == %{"type" => "card_entered", "column" => doing.name}
    end

    test "a value the preset can't use is said, and nothing is saved", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")

      view |> element("#rule-preset-follow_card") |> render_click()

      html =
        view
        |> form("#rule-preset-form", %{"preset" => %{"card" => "the big one"}})
        |> render_submit()

      assert html =~ "Card number must be a number"
      assert Automations.list_rules(board.id) == []
    end
  end

  describe "the alerts section in the header" do
    test "is on every page, and counts what is waiting", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s(id="alerts-bar")
      assert html =~ "No alerts"

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [
          %{"type" => "alert", "title" => "New card: {{card.title}}", "body" => "Have a look."}
        ]
      })

      card_fixture(backlog, %{"title" => "Something"})

      {:ok, view, _html} = live(conn, ~p"/work")
      assert has_element?(view, "#alerts-bar", "1")

      html = view |> element("#alerts-bar button[phx-click=toggle_alerts]") |> render_click()
      assert html =~ "New card: Something"
      assert html =~ "Have a look."
    end

    test "an alert links to the card it is about", %{conn: conn, board: board, backlog: backlog} do
      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "alert", "title" => "Look at this"}]
      })

      card = card_fixture(backlog, %{"title" => "The card"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      view |> element("#alerts-bar button[phx-click=toggle_alerts]") |> render_click()

      assert has_element?(view, ~s|#alerts-panel a[href="/boards/#{board.id}/cards/#{card.id}"]|)
    end

    test "dismissing one leaves the rest, and dismiss all clears them", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      for severity <- ~w(info warning) do
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [
            %{"type" => "alert", "title" => "A #{severity} alert", "severity" => severity}
          ]
        })
      end

      card_fixture(backlog)
      [first | _] = Automations.list_alerts(user_fixture())

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
      view |> element("#alerts-bar button[phx-click=toggle_alerts]") |> render_click()

      view |> element("#alert-#{first.id} button[phx-click=dismiss_alert]") |> render_click()
      assert length(Automations.list_alerts(user_fixture())) == 1
      refute has_element?(view, "#alert-#{first.id}")

      view |> element("#alerts-panel button[phx-click=dismiss_all_alerts]") |> render_click()
      assert Automations.list_alerts(user_fixture()) == []
      assert has_element?(view, "#alerts-bar", "0")
    end

    test "an alert raised elsewhere reaches an open page", %{
      conn: conn,
      board: board,
      backlog: backlog
    } do
      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "alert", "title" => "Raised elsewhere"}]
      })

      {:ok, view, _html} = live(conn, ~p"/work")
      refute render(view) =~ "Raised elsewhere"

      card_fixture(backlog)

      view |> element("#alerts-bar button[phx-click=toggle_alerts]") |> render_click()
      assert render(view) =~ "Raised elsewhere"
    end

    test "alerts don't leak to people who can't read the board", %{board: board, backlog: backlog} do
      stranger = user_fixture("stranger@example.com")

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "alert", "title" => "Private business"}]
      })

      card_fixture(backlog)

      {:ok, _view, html} = live(conn_as(stranger), ~p"/work")
      refute html =~ "Private business"
    end
  end
end
