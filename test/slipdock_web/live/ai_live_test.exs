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
    :ok = Boards.Cards.move_card(shipped.id, done.id)
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

  test "the open card's dependencies reach the chat as the reader sees them", %{
    board: board,
    card: card
  } do
    other = board_fixture(%{"name" => "Elsewhere"})
    blocker = card_fixture(hd(other.columns), %{"title" => "Hush project"})
    {:ok, _} = Boards.Dependencies.add_dependency(card, blocker)

    shared = board_fixture(%{"name" => "Shared"})
    readable = card_fixture(hd(shared.columns), %{"title" => "Open plan"})
    {:ok, _} = Boards.Dependencies.add_dependency(card, readable)

    reader = user_fixture("reader-#{System.unique_integer([:positive])}@example.com")
    share_fixture(board, reader, "read")
    share_fixture(shared, reader, "read")
    conn = log_in_user(Phoenix.ConnTest.build_conn(), reader)

    Slipdock.AIStub.reply_with("Something you can't see.")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
    view |> element("#board-chat") |> render_click()
    view |> form("#page-ai-form-0", %{"message" => "What blocks it?"}) |> render_submit()
    render_async(view)

    assert_receive {:ai_request,
                    %{"messages" => [%{"role" => "system", "content" => system} | _]}}

    [blocked_by] = Regex.run(~r/^Blocked by: .*$/m, system)
    assert blocked_by =~ "##{blocker.id} A card you can't see"
    assert blocked_by =~ "##{readable.id} Open plan"
    refute system =~ "Hush project"
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
        %{"type" => "update", "card_id" => card.id, "changes" => %{"remove_tags" => ["missing"]}},
        %{"type" => "update", "card_id" => card.id, "changes" => %{"add_tags" => ["fresh"]}}
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
    assert html =~ "Create tag “fresh” and add it to “Write the plan”"
    assert html =~ "3 changes ready"

    assert_receive {:ai_request, %{"response_format" => %{"type" => "json_object"}}}

    # Nothing has changed yet.
    assert Boards.Cards.get_card!(card.id).priority == "low"
    refute "fresh" in Enum.map(Boards.Tags.list_tags(board.id), & &1.name)

    html = view |> element("#page-ai button[phx-click=apply]") |> render_click()
    assert html =~ "Applied 3 of 4"

    fresh = Boards.Cards.get_card!(card.id)
    assert fresh.priority == "high"
    assert fresh.due_date == ~D[2030-03-05]
    assert Enum.map(fresh.tags, & &1.name) == ["fresh"]
    assert "fresh" in Enum.map(Boards.Tags.list_tags(board.id), & &1.name)
  end

  test "edit mode tags several cards in one step", %{
    conn: conn,
    board: board,
    card: card,
    backlog: backlog
  } do
    other = card_fixture(backlog, %{"title" => "Book the venue"})

    Slipdock.AIStub.reply_with(%{
      "reply" => "I'll tag both as urgent, a new tag.",
      "actions" => [%{"type" => "tag", "card_ids" => [card.id, other.id], "add" => ["urgent"]}]
    })

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}")
    view |> element("#board-chat") |> render_click()
    view |> element("#page-ai button[phx-value-mode=edit]") |> render_click()
    view |> form("#page-ai-form-0", %{"message" => "Tag both urgent"}) |> render_submit()

    html = render_async(view)

    assert html =~
             "Create tag “urgent” and add it to 2 cards: “Write the plan”, “Book the venue”"

    refute "urgent" in Enum.map(Boards.Tags.list_tags(board.id), & &1.name)

    html = view |> element("#page-ai button[phx-click=apply]") |> render_click()
    assert html =~ "Applied"

    for id <- [card.id, other.id],
        do: assert(Enum.map(Boards.Cards.get_card!(id).tags, & &1.name) == ["urgent"])
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

  test "the chat lists only the wiki pages its reader may read", %{conn: conn, board: board} do
    owner = user_fixture()
    page_fixture(board, %{"title" => "Board-wide notes", "status" => "published"})
    granted = page_fixture(board, %{"title" => "Granted notes", "status" => "published"})

    # A saved view granted, and nothing else on the board, is :view.
    viewer = user_fixture("viewer@example.com")
    {:ok, saved} = Boards.SavedViews.create_saved_view(board, %{"name" => "Due soon"})
    {:ok, _} = Slipdock.Access.grant(saved, viewer, "read", owner)
    assert Slipdock.Access.board_permission(viewer, board) == :view

    # They reach the board only through the view.
    view_path = ~p"/boards/#{board}/swimlanes?view=#{saved.id}"

    assert ask_board_chat(log_in_user(conn, viewer), view_path) =~
             "## Wiki pages on this board (0)"

    # A page granted to them is theirs to read, and so to be told of.
    {:ok, _} = Slipdock.Access.grant(granted, viewer, "read", owner)
    system = ask_board_chat(log_in_user(conn, viewer), view_path)
    assert system =~ "## Wiki pages on this board (1)"
    assert system =~ "Granted notes"
    refute system =~ "Board-wide notes"

    # Read on the board reaches every page.
    reader = user_fixture("reader@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)
    system = ask_board_chat(log_in_user(conn, reader), ~p"/boards/#{board}")
    assert system =~ "Board-wide notes"
    assert system =~ "Granted notes"
  end

  defp ask_board_chat(conn, path) do
    Slipdock.AIStub.reply_with("Noted.")
    {:ok, view, _} = live(conn, path)
    view |> element("#board-chat") |> render_click()
    view |> form("#page-ai-form-0", %{"message" => "Which pages are there?"}) |> render_submit()
    render_async(view)

    assert_receive {:ai_request,
                    %{"messages" => [%{"role" => "system", "content" => system} | _]}}

    system
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

  test "the open card's chat reads the card's record with tools (#1875)", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, _} = Boards.Comments.add_comment(card, "CI went red on credo")

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"card_comments", %{}}]},
      "Comment says CI went red on credo."
    ])

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    view |> element("#card-ai-#{card.id} > div > button") |> render_click()

    view
    |> form("#card-ai-#{card.id}-form-0", %{"message" => "Why did CI fail?"})
    |> render_submit()

    assert render_async(view) =~ "Comment says CI went red on credo."

    assert_receive {:ai_request, %{"tools" => tools}}
    assert "card_jobs" in Enum.map(tools, & &1["function"]["name"])
    assert_receive {:ai_request, %{"messages" => messages}}
    tool = Enum.find(messages, &(&1["role"] == "tool"))
    assert tool["content"] =~ "CI went red on credo"
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

  test "the narrative says which model answered, not just the one asked first (#1670)", %{
    conn: conn,
    board: board
  } do
    # The server asks admin/model; the stub answers as test/model, as an
    # OpenRouter fallback would.
    {:ok, _} = Slipdock.Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    {:ok, _} = Slipdock.Settings.update(%{"ai_model" => "admin/model"})
    Slipdock.AIStub.reply_with("Shipped thing was completed.")
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/narrative")

    view |> element("#narrative-generator button", "Generate narrative") |> render_click()
    view |> element("#narrative-generator button[phx-value-level=three_liner]") |> render_click()

    assert render_async(view) =~ "Three-liner · generated by test/model"
    assert_receive {:ai_request, %{"model" => "admin/model"}}
  end

  test "the work page chats about the assigned cards", %{conn: conn, card: card} do
    user = user_fixture()

    {:ok, _} =
      Boards.Cards.update_card(card, %{"assignee_id" => user.id, "due_date" => "2020-01-01"})

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
      {:ok, _} = Boards.Cards.archive_card(card)

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
