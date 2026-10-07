defmodule Slipdock.QuickAddCaptureTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo}
  alias Slipdock.QuickAdd.Capture

  @today ~D[2026-09-28]

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Plan"})
    tag_fixture(board, "docs")
    %{user: Repo.reload!(user), board: reload(board)}
  end

  defp capture(user, text, opts \\ []),
    do: Capture.capture(user, text, Keyword.put_new(opts, :today, @today))

  describe "with the model" do
    test "what it reads out of the line becomes the card", %{user: user, board: board} do
      Slipdock.AIStub.reply_with(%{
        "title" => "Call the printers about the banners",
        "column" => "To Do",
        "priority" => "critical",
        "due" => "friday",
        "start" => "in 2 days",
        "flags" => ["waiting"],
        "tags" => ["docs"],
        "assignee" => "#{default_email()}"
      })

      assert {:ok, capture} =
               capture(
                 user,
                 "tester to call the printers about the banners by friday, urgent, waiting on them"
               )

      assert capture.card.title == "Call the printers about the banners"
      assert capture.card.priority == "critical"
      assert capture.card.due_date == ~D[2026-10-02]
      assert capture.card.start_date == ~D[2026-09-30]
      assert capture.card.flags == ["waiting"]
      assert capture.card.assignee_id == user.id
      assert capture.column.name == "To Do"
      assert capture.board.id == board.id
      assert Enum.map(Repo.preload(capture.card, :tags).tags, & &1.name) == ["docs"]

      # The chips say what was understood, the list among them since it isn't
      # where quick adds normally go.
      assert {:date, "Due Fri 2 Oct"} in capture.chips
      assert {:priority, "critical"} in capture.chips
      assert {:column, "To Do"} in capture.chips
      assert {:tag, "docs"} in capture.chips
    end

    test "the model is told today, the boards, their lists and tags, and the people", %{
      user: user
    } do
      Slipdock.AIStub.reply_with(%{"title" => "Anything"})
      assert {:ok, _} = capture(user, "anything")

      assert_receive {:ai_request,
                      %{"messages" => [%{"content" => system} | _], "model" => model}}

      assert model == "test/model"
      assert system =~ "TODAY: 2026-09-28 (Monday)"
      assert system =~ ~s(DEFAULT: board "Plan", list "Backlog")
      assert system =~ ~s(- "Plan" — lists: Backlog, To Do, In Progress, Done; tags: docs)
      assert system =~ user.email
    end

    test "names it invents are dropped rather than created", %{user: user, board: board} do
      Slipdock.AIStub.reply_with(%{
        "title" => "Tidy the desk",
        "board" => "Somewhere else",
        "column" => "Nowhere",
        "tags" => ["invented"],
        "assignee" => "ghost@example.com",
        "priority" => "sideways",
        "flags" => ["on fire"]
      })

      assert {:ok, capture} = capture(user, "tidy the desk")
      assert capture.board.id == board.id
      assert capture.column.name == "Backlog"
      assert capture.card.priority == "none"
      assert capture.card.flags == []
      assert capture.card.assignee_id == nil
      assert Repo.preload(capture.card, :tags).tags == []
      assert capture.chips == []
    end

    test "nobody is assigned unless the line named them", %{user: user} do
      Slipdock.AIStub.reply_with(%{
        "title" => "Chase the invoice",
        "assignee" => "#{default_email()}"
      })

      assert {:ok, capture} = capture(user, "chase the invoice, blocked on them")
      assert capture.card.assignee_id == nil
      refute Enum.any?(capture.chips, &match?({:assignee, _}, &1))
    end

    test "a date phrase is resolved here, not by the model", %{user: user} do
      Slipdock.AIStub.reply_with(%{"title" => "Ship it", "due" => "eow", "start" => "tomorrow"})

      assert {:ok, capture} = capture(user, "ship it by the end of the week, starting tomorrow")
      assert capture.card.due_date == ~D[2026-10-04]
      assert capture.card.start_date == ~D[2026-09-29]
    end

    test "a phrase that kept its preposition still resolves", %{user: user} do
      Slipdock.AIStub.reply_with(%{
        "title" => "Ship it",
        "due" => "by friday",
        "start" => "on mon"
      })

      assert {:ok, capture} = capture(user, "ship it by friday, start on monday")
      assert capture.card.due_date == ~D[2026-10-02]
      assert capture.card.start_date == ~D[2026-09-28]
    end

    test "a date decades out is ignored rather than stranding the card", %{user: user} do
      Slipdock.AIStub.reply_with(%{"title" => "Renew the domain", "due" => "2126-10-02"})
      assert {:ok, capture} = capture(user, "renew the domain")
      assert capture.card.due_date == nil
    end

    test "another board the user can write to takes the card", %{user: user} do
      other = board_fixture(%{"name" => "Marketing"})

      Slipdock.AIStub.reply_with(%{
        "title" => "Book the venue",
        "board" => "Marketing",
        "column" => "In Progress"
      })

      assert {:ok, capture} = capture(user, "book the venue on the marketing board, in progress")
      assert capture.board.id == other.id
      assert capture.column.name == "In Progress"
      assert {:board, "Marketing"} in capture.chips
    end

    test "a board the user cannot reach is not an option", %{user: user, board: board} do
      stranger = user_fixture("stranger@example.com")
      board_fixture(%{"name" => "Secret"}, owner: stranger)

      Slipdock.AIStub.reply_with(%{"title" => "Peek", "board" => "Secret"})

      assert {:ok, capture} = capture(user, "peek at the secret board")
      assert capture.board.id == board.id

      assert_receive {:ai_request, %{"messages" => [%{"content" => system} | _]}}
      refute system =~ "Secret"
    end

    test "when the model fails the typed syntax still gets the card in", %{user: user} do
      Slipdock.AIStub.fail_with(500, "upstream exploded")

      assert {:ok, capture} = capture(user, "Write the launch post due: tomorrow #high #docs")
      assert capture.card.title == "Write the launch post"
      assert capture.card.priority == "high"
      assert capture.card.due_date == Date.add(@today, 1)
      assert Enum.map(Repo.preload(capture.card, :tags).tags, & &1.name) == ["docs"]
      assert [note] = capture.notes
      assert note =~ "Added without the model"
    end
  end

  describe "without the model" do
    test "the typed syntax is read on its own", %{user: user} do
      {:ok, user} = Accounts.update_quick_add(user, %{"quick_add_ai" => false})

      assert {:ok, capture} = capture(user, "Write it due: eow #todo")
      assert capture.card.title == "Write it"
      assert capture.column.name == "To Do"
      refute_receive {:ai_request, _}
    end
  end

  describe "where the card lands" do
    test "the user's saved board and list are the default", %{user: user} do
      other = board_fixture(%{"name" => "Errands"})
      doing = Enum.find(other.columns, &(&1.name == "In Progress"))

      {:ok, user} =
        Accounts.update_quick_add(user, %{
          "quick_add_board_id" => other.id,
          "quick_add_column_id" => doing.id,
          "quick_add_ai" => false
        })

      assert {:ok, capture} = capture(user, "Pick up the parcel")
      assert capture.board.id == other.id
      assert capture.column.id == doing.id
    end

    test "a saved board that has gone falls back to the first one", %{user: user, board: board} do
      gone = board_fixture(%{"name" => "Old"})
      {:ok, user} = Accounts.update_quick_add(user, %{"quick_add_board_id" => gone.id})
      {:ok, _} = Boards.delete_board(gone)

      catalogue = Capture.catalogue(Repo.reload!(user))
      assert catalogue.default_board.id == board.id
      assert catalogue.default_column.name == "Backlog"
    end

    test "an empty line is refused", %{user: user} do
      assert {:error, message} = capture(user, "   ")
      assert message =~ "Type what you want to add"
    end

    test "a user with no board is told so", %{} do
      stranger = user_fixture("nobody@example.com")
      assert {:error, message} = capture(stranger, "Something")
      assert message =~ "don't have a board"
    end
  end
end
