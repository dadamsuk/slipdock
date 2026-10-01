defmodule Slipdock.ResearcherTest do
  @moduledoc """
  The assistant that searches for itself: the tool loop, what each tool
  returns, and the fact that every one of them is scoped to the asker.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.AI.Researcher
  alias Slipdock.{Access, Boards, Search}

  setup do
    Slipdock.AIStub.share()

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
    {:ok, template} = Boards.find_template("Simple")
    {:ok, sub} = Boards.create_sub_board(ctx.card, template)
    sub = Boards.get_board!(sub.id)

    deep = card_fixture(hd(sub.columns), %{"title" => "Deep task", "due_date" => "2020-01-01"})
    {:ok, _} = Boards.update_card(deep, %{"assignee_id" => jess.id})

    other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
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
end
