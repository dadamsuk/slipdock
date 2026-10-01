defmodule Slipdock.DemoTest do
  @moduledoc """
  The demo workspace is what a fresh install shows and what the README
  screenshots are taken from, so it has to keep building.
  """
  use Slipdock.DataCase, async: false

  alias Slipdock.{Boards, Demo, Fields, Wiki}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.Board
  alias Slipdock.Search.Indexer

  # Building a workspace queues every card for embedding, and that queue is
  # global: left full, it drains into whichever search test runs next. The
  # rows are rolled back with the sandbox, so flushing only sweeps the ids.
  setup do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()
    on_exit(fn -> drain() end)
  end

  defp drain, do: drain(20)

  defp drain(0), do: :ok

  defp drain(tries) do
    if Indexer.pending() > 0 do
      Indexer.flush()
      drain(tries - 1)
    end
  end

  test "builds a workspace with everything the screenshots show" do
    assert {:ok, board} = Demo.build()
    assert board.name == "Product Launch"

    cards = Boards.list_cards(board)
    assert length(cards) > 10

    # An epic with a board of its own.
    epic = Enum.find(cards, &(&1.title == "Self-serve trial sign-up"))
    sub = Repo.get_by!(Board, parent_card_id: epic.id)
    assert Boards.list_cards(sub) |> length() == 4

    # A dependency, a scoring scheme, a wiki and an automation.
    notes = Boards.get_card!(Enum.find(cards, &(&1.title == "Write release notes")).id)
    assert [_blocker] = notes.blocked_by
    assert Enum.any?(Fields.list_fields(Board.root_id(board)), &(&1.key == "rice"))
    assert length(Wiki.list_pages(board)) == 2
    assert Repo.aggregate(Rule, :count) == 1

    # Nothing in it belongs to a real person.
    assert Demo.owner_email() =~ "@example.com"
  end

  test "refuses to build over an existing workspace unless forced" do
    assert {:ok, _} = Demo.build()
    assert {:error, :not_empty} = Demo.build()
    assert {:ok, _} = Demo.build(force: true)
  end
end
