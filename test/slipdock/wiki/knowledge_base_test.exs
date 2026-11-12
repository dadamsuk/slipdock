defmodule Slipdock.Wiki.KnowledgeBaseTest do
  @moduledoc """
  Everybody's Knowledge Base (W-2201): a board of kind "wiki", made the first
  time it is wanted, first in the wiki's tree, on no list of boards, and
  counted against no limit. An existing board can be adopted as one.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Quota, Repo}
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Change, KnowledgeBase}

  setup do
    %{user: user_fixture("kbase-#{System.unique_integer([:positive])}@example.com")}
  end

  test "made the first time it is wanted, then the same one", %{user: user} do
    assert KnowledgeBase.get(user) == nil

    assert {:ok, %Board{kind: "wiki", name: "Knowledge Base"} = kb} = KnowledgeBase.ensure(user)
    assert kb.owner_id == user.id
    assert {:ok, %Board{id: id}} = KnowledgeBase.ensure(user)
    assert id == kb.id
    assert KnowledgeBase.get(user).id == kb.id
  end

  test "is on no list of boards to work on, but is readable", %{user: user} do
    {:ok, kb} = KnowledgeBase.ensure(user)
    work = board_fixture(%{"name" => "Work", "code" => "kbwork"}, owner: user)

    assert Enum.map(Access.list_boards(user, wiki: false), & &1.id) == [work.id]
    assert kb.id in Enum.map(Access.list_boards(user), & &1.id)
    assert Access.can_write?(Access.board_permission(user, kb))
  end

  test "counts against no board limit, so a full account still gets one", %{user: user} do
    board_fixture(%{"name" => "Work", "code" => "kblimit"}, owner: user)
    used = Quota.used(user.id, :boards)

    {:ok, _} = KnowledgeBase.ensure(user)
    assert Quota.used(user.id, :boards) == used
  end

  test "is first in the home order, whatever the hand-made order says", %{user: user} do
    work = board_fixture(%{"name" => "Aardvark", "code" => "kbfirst"}, owner: user)
    {:ok, kb} = KnowledgeBase.ensure(user)
    :ok = Boards.Arrangement.reorder_boards(user, [work.id])

    assert Boards.Arrangement.home_ranks(user, [work, kb]) == %{kb.id => 0, work.id => 1}
  end

  describe "adopt" do
    test "makes a board the Knowledge Base, renamed, and the feed hears it", %{user: user} do
      board = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbadopt"}, owner: user)

      assert {:ok, %Board{kind: "wiki", name: "Knowledge Base"}} =
               KnowledgeBase.adopt(user, board)

      assert KnowledgeBase.get(user).id == board.id

      assert Repo.exists?(
               from(c in Change,
                 where: c.board_id == ^board.id and c.subject == "board",
                 select: c.id
               )
             )

      # Already it: nothing to do.
      assert {:ok, %Board{id: id}} = KnowledgeBase.adopt(user, KnowledgeBase.get(user))
      assert id == board.id
    end

    test "keeps a name given", %{user: user} do
      board = board_fixture(%{"name" => "Notes", "code" => "kbname"}, owner: user)
      assert {:ok, %Board{name: "GMinds"}} = KnowledgeBase.adopt(user, board, name: "GMinds")
    end

    test "refuses a second one, somebody else's board, and a sub-board", %{user: user} do
      {:ok, _} = KnowledgeBase.ensure(user)
      board = board_fixture(%{"name" => "Another", "code" => "kbsecond"}, owner: user)
      assert {:error, "you have a Knowledge Base already"} = KnowledgeBase.adopt(user, board)

      theirs = board_fixture(%{"name" => "Theirs", "code" => "kbtheirs"})
      assert {:error, "the board isn't yours"} = KnowledgeBase.adopt(user, theirs)

      other = user_fixture("kbase-sub-#{System.unique_integer([:positive])}@example.com")
      parent = board_fixture(%{"name" => "Parent", "code" => "kbparent"}, owner: other)
      sub = %{parent | id: parent.id, parent_card_id: 1, owner_id: other.id}

      assert {:error, "a sub-board can't be the Knowledge Base"} =
               KnowledgeBase.adopt(other, sub)
    end
  end

  test "its kind can't be set from settings", %{user: user} do
    board = board_fixture(%{"name" => "Plain", "code" => "kbkind"}, owner: user)
    assert {:error, changeset} = Boards.update_board(board, %{"kind" => "wiki"})
    assert changeset.errors[:kind]
  end
end
