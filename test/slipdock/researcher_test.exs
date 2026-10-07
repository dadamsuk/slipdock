defmodule Slipdock.ResearcherTest do
  @moduledoc """
  The assistant that searches for itself: the tool loop, what each tool
  returns, and the fact that every one of them is scoped to the asker.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.AI.Researcher
  alias Slipdock.{Access, Boards, Search}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Launch", "code" => "launch"}, owner: owner)
    column = hd(board.columns)

    card = card_fixture(column, %{"title" => "Refund rounding is wrong", "priority" => "high"})
    {:ok, _} = Boards.add_comment(card, "finance want this fixed before the audit")

    %{owner: owner, board: board, column: column, card: card}
  end

  defp index_everything do
    Slipdock.AIStub.stub_embeddings()
    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))
  end

  test "searches, then answers, and reports both", ctx do
    index_everything()

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "refund rounding"}}]},
      "The **refund rounding** card is high priority."
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "What's happening with refunds?")
    assert answer.reply =~ "refund rounding"
    assert answer.searches == ["refund rounding"]
    assert [%{card: %{id: id}, why: "refund rounding"}] = answer.sources
    assert id == ctx.card.id

    # The tool's result went back to the model as a tool message.
    assert_receive {:ai_request, %{"messages" => messages}}
    assert_receive {:ai_request, %{"messages" => second}}
    assert length(second) > length(messages)
    tool = Enum.find(second, &(&1["role"] == "tool"))
    assert tool["name"] == "search_cards"
    assert tool["content"] =~ "Refund rounding is wrong"
  end

  test "read_card returns the card in full, and only to someone who may read it", ctx do
    index_everything()
    stranger = user_fixture("stranger@example.com")

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"read_card", %{"card_id" => ctx.card.id}}]},
      "Read it."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "Tell me about that card")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    tool = Enum.find(messages, &(&1["role"] == "tool"))
    assert tool["content"] =~ "Refund rounding is wrong"
    assert tool["content"] =~ "finance want this fixed"

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"read_card", %{"card_id" => ctx.card.id}}]},
      "Nothing to see."
    ])

    assert {:ok, _} = Researcher.ask(stranger, [], "Tell me about card #{ctx.card.id}")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    tool = Enum.find(messages, &(&1["role"] == "tool"))
    assert tool["content"] =~ "There is no card"
    refute tool["content"] =~ "finance want this fixed"
  end

  test "search results never cross a permission boundary" do
    index_everything()
    stranger = user_fixture("stranger@example.com")

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "refund rounding"}}]},
      "I found nothing."
    ])

    assert {:ok, answer} = Researcher.ask(stranger, [], "Anything about refunds?")
    assert answer.sources == []

    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    tool = Enum.find(messages, &(&1["role"] == "tool"))
    assert tool["content"] =~ "No cards matched"
  end

  test "list_boards lists only the asker's boards", ctx do
    stranger = user_fixture("stranger@example.com")
    Slipdock.AIStub.reply_sequence([{:tool_calls, [{"list_boards", %{}}]}, "Done."])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What boards are there?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] =~ "Launch [launch]"

    Slipdock.AIStub.reply_sequence([{:tool_calls, [{"list_boards", %{}}]}, "Done."])
    assert {:ok, _} = Researcher.ask(stranger, [], "What boards are there?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] == "You have no boards."
  end

  test "list_cards counts every list on the board, including the empty ones", ctx do
    todo = Enum.find(ctx.board.columns, &(&1.name == "To Do"))
    card_fixture(todo, %{"title" => "Write the runbook"})
    card_fixture(todo, %{"title" => "Chase the invoice", "completed" => true})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"board" => "Launch"}}]},
      "Three cards."
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "How many cards are on Launch?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "3 top-level cards"
    assert content =~ "Launch [launch] — 3 cards"
    assert content =~ "Backlog — 1 card"
    assert content =~ "To Do — 2 cards"
    assert content =~ "In Progress — 0 cards"
    assert content =~ "Write the runbook"

    # Every card it listed is offered as a source, board and all.
    assert "Write the runbook" in Enum.map(answer.sources, & &1.card.title)
    assert Enum.all?(answer.sources, &(&1.card.board.name == "Launch"))
  end

  test "list_cards restricts to one list, and reports an unknown one", ctx do
    todo = Enum.find(ctx.board.columns, &(&1.name == "To Do"))
    card_fixture(todo, %{"title" => "Write the runbook"})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"board" => "Launch", "column" => "to do"}}]},
      "One card."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What's in To Do?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "1 top-level card matching list “to do”"
    assert content =~ "To Do — 1 card"
    refute content =~ "Refund rounding"

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"board" => "Launch", "column" => "Icebox"}}]},
      "No such list."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What's in Icebox?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "No list called “Icebox”"
    assert content =~ "Its lists are: Backlog, To Do, In Progress, Done"
  end

  test "list_cards filters, and covers every board when none is named", ctx do
    elsewhere = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: ctx.owner)
    card_fixture(hd(elsewhere.columns), %{"title" => "Urgent thing", "priority" => "high"})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"priority" => "high"}}]},
      "Two of them."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "How many high priority cards?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "2 top-level cards matching priority high"
    assert content =~ "Launch [launch] — 1 card"
    assert content =~ "Elsewhere [elsewhere] — 1 card"
    assert content =~ "Urgent thing"
  end

  test "list_cards counts subcards when asked for depth, and says so when it isn't", ctx do
    {:ok, template} = Boards.find_template("Simple")
    {:ok, sub} = Boards.create_sub_board(ctx.card, template)
    sub = Boards.get_board!(sub.id)
    card_fixture(hd(sub.columns), %{"title" => "Check the rounding maths"})
    card_fixture(hd(sub.columns), %{"title" => "Add a regression test", "completed" => true})

    # Depth 1: the board's own cards, and an honest note about the rest.
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"board" => "Launch"}}]},
      "One at the top."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "How many cards on Launch?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "1 top-level card"
    assert content =~ "Not counted: 2 subcards beneath them"
    refute content =~ "Check the rounding maths"

    # Depth "all": the whole tree, split into what is where.
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"board" => "Launch", "depth" => "all"}}]},
      "Three in all."
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "How many including subcards?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "3 cards to depth"
    assert content =~ "1 on the boards themselves, 2 on the sub-boards beneath"
    assert content =~ "Launch › Refund rounding is wrong (sub-board) — 2 cards"
    assert content =~ "Check the rounding maths"
    assert "Check the rounding maths" in Enum.map(answer.sources, & &1.card.title)
  end

  test "list_cards filters by due date, dependency and assignee", ctx do
    jess = user_fixture("jess@example.com")
    share_fixture(ctx.board, jess)
    todo = Enum.find(ctx.board.columns, &(&1.name == "To Do"))

    late = card_fixture(todo, %{"title" => "Overdue thing", "due_date" => "2020-01-01"})
    card_fixture(todo, %{"title" => "Far off thing", "due_date" => "2099-01-01"})
    blocked = card_fixture(todo, %{"title" => "Waiting on the overdue one"})
    {:ok, _} = Boards.add_dependency(blocked, late)
    {:ok, _} = Boards.update_card(late, %{"assignee_id" => jess.id})

    # Titles are quoted in a card's line; a blocker is named without quotes,
    # so quoting is what tells "listed" from "mentioned".
    for {args, expected, unexpected} <- [
          {%{"due" => "overdue"}, "“Overdue thing”", "“Far off thing”"},
          {%{"deps" => "blocked"}, "“Waiting on the overdue one”", "“Far off thing”"},
          {%{"assignee" => "jess@example.com"}, "“Overdue thing”", "“Far off thing”"},
          {%{"assignee" => "none"}, "“Far off thing”", "“Overdue thing”"}
        ] do
      Slipdock.AIStub.reply_sequence([
        {:tool_calls, [{"list_cards", Map.put(args, "board", "Launch")}]},
        "Here you go."
      ])

      assert {:ok, _} = Researcher.ask(ctx.owner, [], "Filtered, please")
      assert_receive {:ai_request, _}
      assert_receive {:ai_request, %{"messages" => messages}}
      content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

      assert content =~ expected, "expected #{expected} for #{inspect(args)}:\n#{content}"
      refute content =~ unexpected
    end
  end

  test "read_board describes the board without listing its cards", ctx do
    {:ok, _} = Boards.create_tag(ctx.board, %{"name" => "finance"})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"read_board", %{"board" => "launch"}}]},
      "Described."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "Tell me about Launch")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "# Board: Launch [launch]"
    assert content =~ "Lists (columns), in order: “Backlog”, “To Do”, “In Progress”, “Done”"
    assert content =~ "Tags available: “finance”"
    assert content =~ "People who can be assigned: owner@example.com"
    assert content =~ "Top-level cards: 1 (0 done)."
    # The furniture, not the contents.
    refute content =~ "Refund rounding is wrong"
  end

  test "assigned_cards is one person's work, across boards and levels", ctx do
    jess = user_fixture("jess@example.com")
    {:ok, jess} = Slipdock.Accounts.update_profile(jess, %{"name" => "Jess Smith"})
    share_fixture(ctx.board, jess)
    {:ok, template} = Boards.find_template("Simple")
    {:ok, sub} = Boards.create_sub_board(ctx.card, template)
    sub = Boards.get_board!(sub.id)

    deep = card_fixture(hd(sub.columns), %{"title" => "Deep task", "due_date" => "2020-01-01"})
    {:ok, _} = Boards.update_card(deep, %{"assignee_id" => jess.id})

    other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner) |> share_fixture(jess)
    mine = card_fixture(hd(other.columns), %{"title" => "Shallow task"})
    {:ok, _} = Boards.update_card(mine, %{"assignee_id" => jess.id})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"assigned_cards", %{"person" => "Jess"}}]},
      "Two things."
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "What is Jess working on?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~
             "2 unfinished cards assigned to Jess Smith <jess@example.com> across every board"

    assert content =~ "Overdue (1)"
    assert content =~ "Deep task"
    assert content =~ "on: Launch › Refund rounding is wrong"
    assert content =~ "Shallow task"

    assert Enum.map(answer.sources, & &1.card.title) |> Enum.sort() == [
             "Deep task",
             "Shallow task"
           ]

    # Everything done is not the same as nothing assigned.
    {:ok, _} = Boards.update_card(mine, %{"completed" => true})
    {:ok, _} = Boards.update_card(deep, %{"completed" => true})

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"assigned_cards", %{"person" => "jess@example.com"}}]},
      "All done."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "Anything left for Jess?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "0 unfinished cards assigned to Jess Smith"
    assert content =~ "2 completed cards are assigned to them as well"

    # Somebody nobody knows, and the asker's own work by default.
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"assigned_cards", %{"person" => "Nobody Here"}}]},
      "No such person."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What is Nobody Here working on?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}

    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] =~
             "Nobody here is called “Nobody Here”"
  end

  test "recent_activity reports what happened, with what was said", ctx do
    {:ok, _} =
      Boards.add_status_update(ctx.card, ctx.owner, %{
        "health" => "at_risk",
        "body" => "vendor is late"
      })

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"recent_activity", %{"board" => "Launch"}}]},
      "Here's the week."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What happened this week?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "What happened on Launch and its sub-boards"
    assert content =~ "newest first"
    # The comment's text, not just the fact of it.
    assert content =~ "comment on “Refund rounding is wrong”: finance want this fixed"
    assert content =~ "reported “Refund rounding is wrong” at risk: vendor is late"
    assert content =~ "added “Refund rounding is wrong”"
    refute content =~ "commented on “Refund rounding is wrong”"

    # A window with nothing in it says so, and a bad date is reported.
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"recent_activity", %{"since" => "2001-01-01", "until" => "2001-01-31"}}]},
      "Nothing then."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What happened in January 2001?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] =~ "Nothing happened"

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"recent_activity", %{"since" => "last Tuesday"}}]},
      "Bad date."
    ])

    assert {:ok, _} = Researcher.ask(ctx.owner, [], "What happened lately?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] =~ "not a date I can read"
  end

  test "recent_activity and alerts are scoped to the asker", ctx do
    stranger = user_fixture("stranger@example.com")

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"recent_activity", %{}}]},
      "Nothing for you."
    ])

    assert {:ok, _} = Researcher.ask(stranger, [], "What's been happening?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "Nothing happened"
    refute content =~ ctx.card.title

    Slipdock.AIStub.reply_sequence([{:tool_calls, [{"alerts", %{}}]}, "No alerts."])

    assert {:ok, _} = Researcher.ask(stranger, [], "Any alerts?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] =~ "No alerts"
  end

  test "list_cards reaches only the asker's boards", ctx do
    stranger = user_fixture("stranger@example.com")

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"list_cards", %{"board" => "Launch"}}]},
      "Nothing to see."
    ])

    assert {:ok, answer} = Researcher.ask(stranger, [], "What's on Launch?")
    assert answer.sources == []
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    content = Enum.find(messages, &(&1["role"] == "tool"))["content"]

    assert content =~ "There is no board called “Launch”"
    refute content =~ ctx.card.title
  end

  test "a board argument narrows the search to that board", ctx do
    elsewhere = board_fixture(%{"name" => "Elsewhere", "code" => "elsewhere"}, owner: ctx.owner)
    card_fixture(hd(elsewhere.columns), %{"title" => "Refund rounding elsewhere"})
    index_everything()

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "refund rounding", "board" => "elsewhere"}}]},
      "Only the one."
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "Refunds on Elsewhere?")
    assert Enum.map(answer.sources, & &1.card.title) == ["Refund rounding elsewhere"]
  end

  test "an answer with no tool calls comes straight back", ctx do
    Slipdock.AIStub.reply_with("I can't change anything from here.")
    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "Delete everything")
    assert answer.reply =~ "can't change anything"
    assert answer.searches == []
    assert answer.sources == []
  end

  test "an unknown tool is reported back rather than crashing the loop", ctx do
    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"drop_database", %{}}]},
      "I'll stick to reading."
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "Do something rash")
    assert answer.reply =~ "stick to reading"

    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}

    assert Enum.find(messages, &(&1["role"] == "tool"))["content"] =~
             "no tool called drop_database"
  end

  test "a model that only ever calls tools is stopped rather than looped forever", ctx do
    index_everything()

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "round and round"}}]}
    ])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "Go on then")
    assert answer.reply =~ "without settling on an answer"
    assert length(answer.searches) == 8
  end

  test "an empty turn is asked again rather than failing the question", ctx do
    # Cheap models sometimes answer with neither prose nor a tool call.
    Slipdock.AIStub.reply_sequence(["", "Second time lucky."])

    assert {:ok, answer} = Researcher.ask(ctx.owner, [], "Anything?")
    assert answer.reply == "Second time lucky."
  end

  test "an endlessly empty model does eventually give up", ctx do
    Slipdock.AIStub.reply_sequence([""])
    assert {:error, message} = Researcher.ask(ctx.owner, [], "Anything?")
    assert message =~ "empty answer"
  end

  test "a failing model is reported, not swallowed", ctx do
    Slipdock.AIStub.fail_with(429, "slow down")
    assert {:error, message} = Researcher.ask(ctx.owner, [], "Anything?")
    assert message =~ "rate-limited"
  end

  test "a card shared on its own is reachable, and its neighbours are not", ctx do
    neighbour = card_fixture(ctx.column, %{"title" => "Refund rounding neighbour"})
    index_everything()

    stranger = user_fixture("stranger@example.com")
    {:ok, _} = Access.grant(ctx.card, stranger, "read", ctx.owner)

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "refund rounding"}}]},
      "Just the one."
    ])

    assert {:ok, answer} = Researcher.ask(stranger, [], "Refunds?")
    assert Enum.map(answer.sources, & &1.card.id) == [ctx.card.id]
    refute neighbour.id in Enum.map(answer.sources, & &1.card.id)
  end

  ## Each tool's arguments and refusals ---------------------------------------

  # Runs one tool call through the loop and returns what the tool said back
  # to the model, alongside the answer.
  defp tool_output(user, tool, args, history \\ []) do
    Slipdock.AIStub.reply_sequence([{:tool_calls, [{tool, args}]}, "Done."])
    assert {:ok, answer} = Researcher.ask(user, history, "Question?")
    assert_receive {:ai_request, _}
    assert_receive {:ai_request, %{"messages" => messages}}
    {Enum.find(messages, &(&1["role"] == "tool"))["content"], answer}
  end

  describe "read_card" do
    test "takes an id as a string, and refuses one that isn't a number", ctx do
      {content, answer} = tool_output(ctx.owner, "read_card", %{"card_id" => "#{ctx.card.id}"})
      assert content =~ "Refund rounding is wrong"
      # Reading a card is not a search, and does not count as a source.
      assert answer.searches == []

      {content, _} = tool_output(ctx.owner, "read_card", %{"card_id" => "the refund one"})
      assert content == "read_card needs a numeric card_id."

      {content, _} = tool_output(ctx.owner, "read_card", %{})
      assert content == "read_card needs a numeric card_id."

      {content, _} = tool_output(ctx.owner, "read_card", %{"card_id" => 999_999_999})
      assert content == "There is no card #999999999 you can see."
    end
  end

  describe "list_boards" do
    test "someone with no boards is told so", _ctx do
      nobody = user_fixture("boardless@example.com")
      {content, _} = tool_output(nobody, "list_boards", %{})
      assert content == "You have no boards."
    end

    test "each board has its code, card count and lists, and archived ones say so", ctx do
      old = board_fixture(%{"name" => "Old plans", "code" => "old"}, owner: ctx.owner)
      {:ok, _} = Boards.archive_board(old)

      {content, _} = tool_output(ctx.owner, "list_boards", %{})
      lines = String.split(content, "\n")

      launch = Enum.find(lines, &(&1 =~ "Launch"))
      assert launch =~ "- Launch [launch] — 1 active cards; lists: #{ctx.column.name}"
      assert Enum.find(lines, &(&1 =~ "Old plans")) =~ "(archived)"
    end
  end

  describe "read_board" do
    test "describes a board's description, lists and done count", ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"description" => "Everything for launch"})
      done = card_fixture(ctx.column, %{"title" => "Shipped"})
      {:ok, _} = Boards.update_card(done, %{"completed" => true})

      {content, _} = tool_output(ctx.owner, "read_board", %{"board" => board.code})
      assert content =~ "# Board: Launch [launch]"
      assert content =~ "Description: Everything for launch"
      assert content =~ "Top-level cards: 2 (1 done)."
      refute content =~ "This board is archived."
    end

    test "an archived board says so", ctx do
      {:ok, _} = Boards.archive_board(ctx.board)
      {content, _} = tool_output(ctx.owner, "read_board", %{"board" => "Launch"})
      assert content =~ "This board is archived."
    end

    test "a missing or unknown board is refused with the boards there are", ctx do
      {content, _} = tool_output(ctx.owner, "read_board", %{})
      assert content =~ "There is no board called “” that you can see."
      assert content =~ "The boards you can see are: Launch."

      {content, _} = tool_output(ctx.owner, "read_board", %{"board" => "Moonshot"})
      assert content =~ "There is no board called “Moonshot”"

      stranger = user_fixture("stranger@example.com")
      {content, _} = tool_output(stranger, "read_board", %{"board" => "Launch"})
      assert content =~ "There is no board called “Launch”"
      assert content =~ "You have no boards."
    end

    test "a board is found by a name it only contains", ctx do
      {content, _} = tool_output(ctx.owner, "read_board", %{"board" => "the launch board"})
      assert content =~ "# Board: Launch"
    end
  end

  describe "list_cards arguments" do
    test "a depth that is not a number is refused", ctx do
      {content, _} =
        tool_output(ctx.owner, "list_cards", %{"board" => "Launch", "depth" => "lots"})

      assert content == ~s(depth must be a number or "all".)
    end

    test "someone with no boards is told so", _ctx do
      nobody = user_fixture("boardless@example.com")
      {content, _} = tool_output(nobody, "list_cards", %{})
      assert content == "You have no boards."
    end

    test "the filters applied are written into the header", ctx do
      {content, answer} =
        tool_output(ctx.owner, "list_cards", %{
          "board" => "Launch",
          "priority" => "high",
          "completed" => false
        })

      assert content =~ "1 top-level card matching priority high, not done"
      assert [%{why: "cards on Launch"}] = answer.sources
    end
  end

  describe "assigned_cards arguments" do
    test "a name that fits several people is asked again by email", ctx do
      ann = user_fixture("ann.one@example.com")
      ann2 = user_fixture("ann.two@example.com")

      for u <- [ann, ann2],
          do: {:ok, _} = Access.grant(ctx.board, u, "read", ctx.owner)

      {content, _} = tool_output(ctx.owner, "assigned_cards", %{"person" => "ann"})
      assert content =~ "“ann” could be any of:"
      assert content =~ "ann.one@example.com"
      assert content =~ "ann.two@example.com"
      assert content =~ "Ask again with the email."
    end

    test "an unknown board is refused", ctx do
      {content, _} = tool_output(ctx.owner, "assigned_cards", %{"board" => "Moonshot"})
      assert content =~ "There is no board called “Moonshot”"
    end

    test "completed cards are left out and counted, unless asked for", ctx do
      {:ok, _} =
        Boards.update_card(ctx.card, %{"assignee_id" => ctx.owner.id, "completed" => true})

      {content, answer} = tool_output(ctx.owner, "assigned_cards", %{"person" => "me"})
      assert content =~ "0 unfinished cards assigned to"
      assert content =~ "1 completed card is assigned to them as well"
      assert answer.sources == []

      {content, answer} =
        tool_output(ctx.owner, "assigned_cards", %{"person" => "me", "include_done" => true})

      assert content =~ "1 card assigned to"
      refute content =~ "completed card"
      assert [%{why: "assigned to " <> _}] = answer.sources
    end
  end

  describe "recent_activity arguments" do
    test "a limit shows the most recent entries and says how many there were", ctx do
      for n <- 1..3, do: {:ok, _} = Boards.add_comment(ctx.card, "note #{n}")

      {content, _} = tool_output(ctx.owner, "recent_activity", %{"limit" => 2})
      assert content =~ "the 2 most recent of"
      assert content =~ "on every board you can see"
    end

    test "an unknown board is refused", ctx do
      {content, _} = tool_output(ctx.owner, "recent_activity", %{"board" => "Moonshot"})
      assert content =~ "There is no board called “Moonshot”"
    end
  end

  describe "alerts" do
    test "a raised alert is listed with its board, card and body", ctx do
      {:ok, _} =
        Slipdock.Automations.raise_alert(%{
          "title" => "Overdue",
          "body" => "past its due date",
          "severity" => "urgent",
          "board_id" => ctx.board.id,
          "card_id" => ctx.card.id
        })

      {content, _} = tool_output(ctx.owner, "alerts", %{})
      assert content =~ "1 alert(s), most urgent first:"

      assert content =~
               "- [urgent] Overdue — past its due date (Launch, on “Refund rounding is wrong”, raised"
    end
  end

  describe "the wiki tools" do
    setup ctx do
      {:ok, page} =
        Slipdock.Wiki.create_page(
          ctx.board,
          %{"title" => "Refund policy", "body" => "Refunds are rounded down to the penny."},
          user: ctx.owner
        )

      {:ok, child} =
        Slipdock.Wiki.create_page(
          ctx.board,
          %{"title" => "Refund exceptions", "body" => "None.", "parent_id" => page.id},
          user: ctx.owner
        )

      %{page: page, child: child}
    end

    test "list_pages lists the board's wiki as a tree", ctx do
      {content, _} = tool_output(ctx.owner, "list_pages", %{"board" => "launch"})
      assert content =~ "The wiki of Launch:"
      assert content =~ "- #{ctx.page.code} Refund policy"
      assert content =~ "\n  - #{ctx.child.code} Refund exceptions"
    end

    test "list_pages on a board with no wiki, or one the asker can't see", ctx do
      board_fixture(%{"name" => "Bare", "code" => "bare"}, owner: ctx.owner)
      {content, _} = tool_output(ctx.owner, "list_pages", %{"board" => "Bare"})
      assert content == "Bare has no wiki pages yet."

      stranger = user_fixture("stranger@example.com")
      {content, _} = tool_output(stranger, "list_pages", %{"board" => "Launch"})
      assert content =~ "There is no board called “Launch” that you can see."
      refute content =~ "Refund policy"
    end

    test "list_pages with no board, or a blank one, picks none rather than the first", ctx do
      for args <- [%{}, %{"board" => "   "}] do
        {content, _} = tool_output(ctx.owner, "list_pages", args)
        assert content =~ "There is no board called “” that you can see."
        assert content =~ "The boards you can see are: Launch."
        refute content =~ "Refund policy"
      end
    end

    test "search_pages with a blank board searches everywhere, not the first board", ctx do
      # The page is on the board listed last, so a blank name that fell back
      # to "the first board" would miss it.
      later = board_fixture(%{"name" => "Zeta", "code" => "zeta"}, owner: ctx.owner)

      {:ok, _} =
        Slipdock.Wiki.create_page(later, %{"title" => "Ledger", "body" => "Ledger rows balance."},
          user: ctx.owner
        )

      Slipdock.AIStub.stub_embeddings()
      {:ok, _} = Search.index_pages(Search.load_pages(Search.all_page_ids()))

      for board <- ["launch", "zeta"] do
        {content, _} = tool_output(ctx.owner, "read_board", %{"board" => board})
        assert content =~ "# Board:"
      end

      {content, _} =
        tool_output(ctx.owner, "search_pages", %{"query" => "ledger rows balance", "board" => " "})

      assert content =~ "Ledger"
      assert content =~ "Zeta › wiki"
    end

    test "read_page returns the page in full and remembers it as a source", ctx do
      {content, answer} = tool_output(ctx.owner, "read_page", %{"page" => ctx.page.code})
      assert content =~ "#{ctx.page.code} “Refund policy” — Launch › wiki"
      assert content =~ "Refunds are rounded down to the penny."
      assert [%{page: %{id: id}, why: "read_page"}] = answer.sources
      assert id == ctx.page.id
    end

    test "read_page refuses a page that doesn't exist, or that the asker can't read", ctx do
      {content, _} = tool_output(ctx.owner, "read_page", %{"page" => "W-99999"})
      assert content == ~s(There is no page called "W-99999".)

      stranger = user_fixture("stranger@example.com")
      {content, answer} = tool_output(stranger, "read_page", %{"page" => ctx.page.code})
      assert content == ~s(There is no page you can read called "#{ctx.page.code}".)
      refute content =~ "rounded down"
      assert answer.sources == []
    end

    test "search_pages finds pages by what they say, and says when nothing matched", ctx do
      Slipdock.AIStub.stub_embeddings()
      {:ok, _} = Search.index_pages(Search.load_pages(Search.all_page_ids()))

      {content, answer} =
        tool_output(ctx.owner, "search_pages", %{"query" => "refunds rounded penny"})

      assert content =~ "#{ctx.page.code} “Refund policy” — Launch › wiki"
      assert content =~ "rounded down to the penny"
      assert answer.searches == ["refunds rounded penny"]
      assert Enum.any?(answer.sources, &(&1[:page] && &1.page.id == ctx.page.id))

      stranger = user_fixture("stranger@example.com")
      {content, answer} = tool_output(stranger, "search_pages", %{"query" => "refunds"})
      assert content =~ "No wiki pages matched “refunds”."
      assert answer.searches == ["refunds"]
    end
  end

  describe "the loop itself" do
    test "only the user and assistant turns of the history are sent, and empty ones dropped",
         ctx do
      Slipdock.AIStub.reply_with("Fine.")

      history = [
        %{role: :user, content: "earlier question"},
        %{role: :assistant, content: "earlier answer"},
        %{role: :system, content: "do something else entirely"},
        %{role: "assistant", content: ""}
      ]

      assert {:ok, _} = Researcher.ask(ctx.owner, history, "And now?")
      assert_receive {:ai_request, %{"messages" => [system | rest]}}
      assert system["role"] == "system"

      assert rest == [
               %{"role" => "user", "content" => "earlier question"},
               %{"role" => "assistant", "content" => "earlier answer"},
               %{"role" => "user", "content" => "And now?"}
             ]
    end

    test "a malformed tool call is answered as such, and arguments that aren't JSON are empty",
         ctx do
      test_pid = self()
      {:ok, turns} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Slipdock.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:ai_request, Jason.decode!(body)})

        message =
          case Agent.get_and_update(turns, &{&1, &1 + 1}) do
            0 ->
              %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{"id" => "bad", "type" => "function"},
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{"name" => "read_card", "arguments" => "{not json"}
                  }
                ]
              }

            _ ->
              %{"role" => "assistant", "content" => "Gave up."}
          end

        Req.Test.json(conn, %{"choices" => [%{"message" => message}]})
      end)

      assert {:ok, %{reply: "Gave up."}} = Researcher.ask(ctx.owner, [], "Anything?")
      assert_receive {:ai_request, _}
      assert_receive {:ai_request, %{"messages" => messages}}
      tools = Enum.filter(messages, &(&1["role"] == "tool"))

      assert Enum.map(tools, & &1["content"]) == [
               "Malformed tool call.",
               "read_card needs a numeric card_id."
             ]
    end

    test "a search that fails is reported to the model, not raised", ctx do
      test_pid = self()
      {:ok, turns} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Slipdock.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        cond do
          String.ends_with?(conn.request_path, "/embeddings") ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => %{"message" => "embedder down"}})

          true ->
            send(test_pid, {:ai_request, Jason.decode!(body)})

            message =
              case Agent.get_and_update(turns, &{&1, &1 + 1}) do
                0 ->
                  %{
                    "role" => "assistant",
                    "content" => nil,
                    "tool_calls" => [
                      %{
                        "id" => "c0",
                        "type" => "function",
                        "function" => %{
                          "name" => "search_cards",
                          "arguments" => ~s({"query": "refunds"})
                        }
                      },
                      %{
                        "id" => "c1",
                        "type" => "function",
                        "function" => %{
                          "name" => "search_pages",
                          "arguments" => ~s({"query": "refunds"})
                        }
                      }
                    ]
                  }

                _ ->
                  %{"role" => "assistant", "content" => "Search is down."}
              end

            Req.Test.json(conn, %{"choices" => [%{"message" => message}]})
        end
      end)

      assert {:ok, answer} = Researcher.ask(ctx.owner, [], "Refunds?")
      assert answer.reply == "Search is down."
      # A failed search isn't counted as one that ran.
      assert answer.searches == []
      assert_receive {:ai_request, _}
      assert_receive {:ai_request, %{"messages" => messages}}
      tools = Enum.filter(messages, &(&1["role"] == "tool"))
      assert Enum.all?(tools, &(&1["content"] =~ "The search failed:"))
      assert length(tools) == 2
    end
  end
end
