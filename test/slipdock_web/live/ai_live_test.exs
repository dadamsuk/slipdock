defmodule SlipdockWeb.AILiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture(%{"name" => "Launch"})
    [backlog, _, _, done] = board.columns
    card = card_fixture(backlog, %{"title" => "Write the plan", "priority" => "low"})
    shipped = card_fixture(backlog, %{"title" => "Shipped thing"})
    :ok = Boards.move_card(shipped.id, done.id)
    %{board: reload(board), card: card, backlog: backlog}
  end

  test "the board page has a chat drawer that sends the visible cards as context", %{
    conn: conn,
    board: board,
    card: card
  } do
    Slipdock.AIStub.reply_with("**Write the plan** is the only open card.")
    {:ok, view, html} = live(conn, ~p"/boards/#{board}")
    assert html =~ "Chat about this page with AI"
    refute html =~ "Chat about Launch"

    view |> element("#board-chat") |> render_click()
    assert has_element?(view, "#page-ai [role=dialog]", "Chat about Launch")

    view |> form("#page-ai-form-0", %{"message" => "What is open?"}) |> render_submit()
    assert render(view) =~ "What is open?"

    html = render_async(view)
    assert html =~ "<strong>Write the plan</strong> is the only open card."

    assert_receive {:ai_request,
                    %{
                      "messages" => [
                        %{"role" => "system", "content" => system},
                        %{"content" => "What is open?"}
                      ]
                    }}

    assert system =~ "# Board: Launch"
    assert system =~ "##{card.id} “Write the plan”"
    assert system =~ "“Shipped thing” (list: Done; DONE)"
  end

  test "edit mode proposes changes that apply on click", %{conn: conn, board: board, card: card} do
    Slipdock.AIStub.reply_with(%{
      "reply" => "I'll make it high priority and due on the 5th.",
      "actions" => [
        %{
          "type" => "update",
          "card_id" => card.id,
          "changes" => %{"priority" => "high", "due_date" => "2030-03-05"}
        },
        %{"type" => "update", "card_id" => card.id, "changes" => %{"add_tags" => ["missing"]}}
      ]
    })

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    view |> element("#board-chat") |> render_click()
    view |> element("#page-ai button[phx-value-mode=edit]") |> render_click()
    assert has_element?(view, "#page-ai [role=tab][aria-selected=true]", "Edit")

    view |> form("#page-ai-form-0", %{"message" => "Bump the plan"}) |> render_submit()
    html = render_async(view)
    assert html =~ "I&#39;ll make it high priority" or html =~ "I'll make it high priority"
    assert html =~ "Set priority of “Write the plan” to high"
    assert html =~ "Set the due date of “Write the plan” to Tue 5 Mar 2030"
    assert html =~ "no tag called “missing”"
    assert html =~ "2 changes ready"

    assert_receive {:ai_request, %{"response_format" => %{"type" => "json_object"}}}

    # Nothing has changed yet.
    assert Boards.get_card!(card.id).priority == "low"

    html = view |> element("#page-ai button[phx-click=apply]") |> render_click()
    assert html =~ "Applied 2 of 3"

    fresh = Boards.get_card!(card.id)
    assert fresh.priority == "high"
    assert fresh.due_date == ~D[2030-03-05]
  end

  test "read-only users only get chat mode", %{conn: conn, board: board} do
    stranger = user_fixture("stranger@example.com")
    owner = user_fixture()
    {:ok, _} = Slipdock.Access.grant(board, stranger, "read", owner)

    conn = log_in_user(conn, stranger)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    view |> element("#board-chat") |> render_click()
    refute has_element?(view, "#page-ai button[phx-value-mode=edit]")
  end

  test "the open card gets its own inline assistant", %{conn: conn, board: board, card: card} do
    Slipdock.AIStub.reply_with("It has no due date.")
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert html =~ "Ask AI about this card"

    view |> element("#card-ai-#{card.id} > div > button") |> render_click()

    view
    |> form("#card-ai-#{card.id}-form-0", %{"message" => "When is it due?"})
    |> render_submit()

    assert render_async(view) =~ "It has no due date."

    assert_receive {:ai_request, %{"messages" => [%{"content" => system} | _]}}
    assert system =~ "Card ##{card.id}: “Write the plan”"
    assert system =~ "Due date: none"
  end

  test "the narrative page generates prose at a chosen level", %{conn: conn, board: board} do
    Slipdock.AIStub.reply_with("Shipped thing was completed. Write the plan is still open.")
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/narrative")
    assert html =~ "Generate narrative"

    view |> element("#narrative-generator button", "Generate narrative") |> render_click()
    assert has_element?(view, "#narrative-generator button", "Three-liner")

    view |> element("#narrative-generator button[phx-value-level=three_liner]") |> render_click()
    html = render_async(view)
    assert html =~ "Shipped thing was completed."
    assert html =~ "Three-liner · generated by"
    assert has_element?(view, "#narrative-generator-copy")

    assert_receive {:ai_request,
                    %{"messages" => [%{"role" => "system"}, %{"content" => account}]}}

    assert account =~ "exactly three sentences"
    assert account =~ "moved “Shipped thing” to Done"
  end

  test "the work page chats about the assigned cards", %{conn: conn, card: card} do
    user = user_fixture()
    {:ok, _} = Boards.update_card(card, %{"assignee_id" => user.id, "due_date" => "2020-01-01"})
    Slipdock.AIStub.reply_with("One card is overdue.")

    {:ok, view, _} = live(conn, ~p"/work")
    view |> element("header button[phx-target='#page-ai']") |> render_click()
    view |> form("#page-ai-form-0", %{"message" => "Anything overdue?"}) |> render_submit()
    assert render_async(view) =~ "One card is overdue."

    assert_receive {:ai_request, %{"messages" => [%{"content" => system} | _]}}
    assert system =~ "# My work"
    assert system =~ "## Overdue (1)"
    assert system =~ "##{card.id} “Write the plan”"
  end

  describe "asking the chat to open a card by its id" do
    test "opens it, on any board you can open, without asking the model", %{
      conn: conn,
      board: board
    } do
      other = board_fixture(%{"name" => "Elsewhere"})
      far = card_fixture(hd(other.columns), %{"title" => "Far card"})

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> element("#board-chat") |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#page-ai-form-0", %{"message" => "open card id #{far.id}"})
               |> render_submit()

      assert to == ~p"/boards/#{other}/cards/#{far.id}"
      refute_received {:ai_request, _}
    end

    test "says so when the card is archived or not yours", %{conn: conn, board: board, card: card} do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
      secret = card_fixture(hd(theirs.columns), %{"title" => "Secret"})
      {:ok, _} = Boards.archive_card(card)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> element("#board-chat") |> render_click()

      html =
        view |> form("#page-ai-form-0", %{"message" => "open ##{secret.id}"}) |> render_submit()

      assert html =~ "There&#39;s no card ##{secret.id} you can open."
      refute html =~ "Secret"

      html =
        view |> form("#page-ai-form-1", %{"message" => "Show card #{card.id}"}) |> render_submit()

      assert html =~ "There&#39;s no card ##{card.id} you can open."
      refute_received {:ai_request, _}
    end

    test "anything else still goes to the model", %{conn: conn, board: board} do
      Slipdock.AIStub.reply_with("Which one?")
      {:ok, view, _} = live(conn, ~p"/boards/#{board}")
      view |> element("#board-chat") |> render_click()

      view |> form("#page-ai-form-0", %{"message" => "open the plan"}) |> render_submit()
      assert render_async(view) =~ "Which one?"
      assert_receive {:ai_request, _}
    end

    test "the requests it recognises" do
      alias SlipdockWeb.AIChatComponent, as: Chat

      assert Chat.open_card_request("open card 123") == 123
      assert Chat.open_card_request("Open card id 123") == 123
      assert Chat.open_card_request("  open card id: #123.  ") == 123
      assert Chat.open_card_request("please show me card number 7") == 7
      assert Chat.open_card_request("go to #42") == 42
      assert Chat.open_card_request("take me to the card 9, please") == 9
      assert Chat.open_card_request("jump to card #9!") == 9

      assert Chat.open_card_request("open 123") == nil
      assert Chat.open_card_request("open card 123 and close card 4") == nil
      assert Chat.open_card_request("why is card 123 open?") == nil
      assert Chat.open_card_request("open the plan") == nil
    end
  end

  test "a failing model call is reported in the drawer", %{conn: conn, board: board} do
    Slipdock.AIStub.fail_with(429, "slow down")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    view |> element("#board-chat") |> render_click()
    view |> form("#page-ai-form-0", %{"message" => "hi"}) |> render_submit()
    assert render_async(view) =~ "rate-limited"
  end

  test "without an API key the AI features are hidden", %{conn: conn, board: board} do
    Slipdock.TestConfig.merge(:ai, api_key: nil)

    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/narrative")
    refute html =~ "Generate narrative"
    refute html =~ "phx-target=\"#page-ai\""
  end
end
