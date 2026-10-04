defmodule Slipdock.Importers.TrelloTest do
  @moduledoc """
  A Trello board's JSON export in, a Slipdock board out. The fixture is a small
  board shaped like what Trello writes — lists out of order, a closed list, an
  archived card, unnamed and duplicate labels, two checklists on one card,
  comments newest first — so each test is about one decision in the mapping.
  """
  use Slipdock.DataCase, async: false

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Importers, Repo, Settings}
  alias Slipdock.Boards.{Board, Card, Comment}
  alias Slipdock.Importers.Trello

  @fixture "test/support/fixtures/trello_board.json"

  defp trello, do: @fixture |> File.read!() |> Jason.decode!()

  defp imported(user, opts \\ []) do
    {:ok, report} = Importers.import(user, File.read!(@fixture), opts)
    board = Repo.get!(Board, hd(report.boards).id) |> Repo.preload([:columns, :tags])
    {report, board}
  end

  defp card(board, title) do
    Repo.one!(
      from(c in Card,
        where: c.board_id == ^board.id and c.title == ^title,
        preload: [:tags, :checklist_items, :urls, column: []]
      )
    )
  end

  defp comments(card) do
    Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: [asc: c.id]))
  end

  setup do
    %{user: user_fixture("gardener@example.com")}
  end

  describe "recognising it" do
    test "a Trello export is recognised, and Slipdock's own document is not" do
      assert Trello.recognises?(trello())
      refute Trello.recognises?(%{"slipdock_portable" => 1, "boards" => []})
      refute Trello.recognises?(%{"lists" => [], "cards" => []})
    end

    test "it goes through the Trello reader without being told", %{user: user} do
      {report, _board} = imported(user)
      assert report.source == "trello"
    end

    test "naming another reader is refused rather than guessed at", %{user: user} do
      assert {:error, {:unknown_source, "asana"}} =
               Importers.import(user, trello(), from: "asana")

      assert {:error, :not_a_trello_export} = Importers.import(user, %{}, from: "trello")
    end

    test "a file nobody recognises is still answered as not a Slipdock export", %{user: user} do
      assert {:error, :not_a_slipdock_export} = Importers.import(user, %{"hello" => 1})
    end
  end

  describe "the board" do
    test "the open lists come in Trello's order, with a category from their names", %{
      user: user
    } do
      {_report, board} = imported(user)

      assert board.name == "Garden"
      assert board.description == "Everything outside."

      assert Enum.map(board.columns, &{&1.name, &1.category}) == [
               {"To Do", "todo"},
               {"Doing", "doing"},
               {"Done", "done"}
             ]
    end

    test "cards are in their lists in Trello's order, archived ones archived", %{user: user} do
      {report, board} = imported(user)
      # Five: the card on the closed list stays behind.
      assert report.cards == 5

      todo = Enum.find(board.columns, &(&1.name == "To Do"))

      titles =
        Repo.all(
          from(c in Card,
            where: c.column_id == ^todo.id,
            order_by: c.position,
            select: c.title
          )
        )

      assert titles == ["Plant tomatoes", "Mow the lawn"]
      assert card(board, "Old shed plan").archived_at
      refute Repo.exists?(from(c in Card, where: c.board_id == ^board.id and c.title == "Pond"))
    end

    test "dates, completion and description", %{user: user} do
      {_report, board} = imported(user)

      tomatoes = card(board, "Plant tomatoes")
      assert tomatoes.due_date == ~D[2026-05-01]
      assert tomatoes.start_date == ~D[2026-04-20]
      assert tomatoes.description == "**Cherry** ones, by the wall."
      refute tomatoes.completed

      # "Due complete" on Trello, and anything in a list called Done.
      assert card(board, "Fix the fence").completed
      assert card(board, "Rake leaves").completed
    end
  end

  describe "labels" do
    test "become tags: unnamed ones named by colour, same-named ones merged", %{user: user} do
      {_report, board} = imported(user)

      assert board.tags |> Enum.map(&{&1.name, &1.color}) |> Enum.sort() == [
               {"Easy", "emerald"},
               {"Purple", "violet"},
               {"Urgent", "red"}
             ]

      assert card(board, "Plant tomatoes").tags |> Enum.map(& &1.name) |> Enum.sort() ==
               ["Purple", "Urgent"]

      assert card(board, "Mow the lawn").tags |> Enum.map(& &1.name) == ["Easy"]
    end
  end

  describe "what hangs off a card" do
    test "several checklists are laid end to end; one stays as it was", %{user: user} do
      {_report, board} = imported(user)

      assert card(board, "Plant tomatoes").checklist_items |> Enum.map(&{&1.text, &1.done}) == [
               {"Before: Buy seeds", true},
               {"Before: Buy compost", false},
               {"After: Water", false}
             ]

      assert card(board, "Fix the fence").checklist_items |> Enum.map(& &1.text) ==
               ["Find nails"]
    end

    test "comments come oldest first, saying who wrote them and when", %{user: user} do
      {_report, board} = imported(user)

      assert [first, second] = board |> card("Plant tomatoes") |> comments()
      assert first.body == "*Alex, on Trello, 2026-04-21*\n\nWhich variety?"
      assert second.body =~ "Sam Gardener, on Trello, 2026-04-22"
      assert second.body =~ "Done the seeds."
    end

    test "attachments become web links", %{user: user} do
      {_report, board} = imported(user)

      assert board |> card("Plant tomatoes") |> Map.get(:urls) |> Enum.map(&{&1.url, &1.title}) ==
               [
                 {"https://trello.com/1/cards/card1/attachments/att1/download/seeds.jpg",
                  "Seed packet"},
                 {"https://example.com/tomatoes", nil}
               ]
    end
  end

  describe "what could not come" do
    test "is said in the report", %{user: user} do
      {report, _board} = imported(user)

      assert Enum.any?(report.skipped, &(&1 =~ "1 archived list on Trello stayed behind"))
      assert Enum.any?(report.skipped, &(&1 =~ "no email addresses"))
      assert Enum.any?(report.skipped, &(&1 =~ "need" and &1 =~ "Trello login"))
    end
  end

  describe "the item limit" do
    test "a Trello board that will not fit is refused before anything is built", %{user: user} do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "a@example.com"})
      {:ok, _} = Settings.update(%{"free_card_limit" => 2})

      # Five: the archived card counts — it is built all the same — and the
      # closed list's card never arrives.
      assert {:error, {:card_limit_reached, 5, 2}} = Importers.import(user, trello())
      refute Repo.exists?(from(b in Board, where: b.owner_id == ^user.id))
    end
  end
end
