defmodule Slipdock.CommentsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.Boards

  setup do
    board = board_fixture()
    %{card: card_fixture(hd(board.columns))}
  end

  test "a long comment is kept whole", %{card: card} do
    body = String.duplicate("A very long thought. ", 10_000)
    assert String.length(body) > 200_000

    assert {:ok, comment} = Boards.add_comment(card, body)
    assert comment.body == body

    assert [%{body: stored}] = Boards.get_card!(card.id).comments
    assert String.length(stored) == String.length(body)
  end

  test "a comment past the limit is refused, and an empty one too", %{card: card} do
    assert {:error, changeset} = Boards.add_comment(card, String.duplicate("x", 250_001))
    assert %{body: ["should be at most 250000 character(s)"]} = errors_on(changeset)

    assert {:error, changeset} = Boards.add_comment(card, "")
    assert %{body: ["can't be blank"]} = errors_on(changeset)
  end

  describe "the author" do
    test "is whoever `by` names, kept and read back with the card", %{card: card} do
      user = user_fixture("writer@example.com")

      assert {:ok, comment} = Boards.add_comment(card, "Mine", by: user)
      assert comment.user_id == user.id
      assert comment.user.id == user.id

      assert [%{body: "Mine", user: %{id: id}}] = Boards.get_card!(card.id).comments
      assert id == user.id
    end

    test "is nil when nobody is named: the system's own notes", %{card: card} do
      assert {:ok, comment} = Boards.add_comment(card, "Runner job ended")
      assert comment.user_id == nil
      assert [%{user: nil}] = Boards.get_card!(card.id).comments
    end

    test "anything but a user in `by` is no author, rather than a crash", %{card: card} do
      assert {:ok, comment} = Boards.add_comment(card, "From somewhere", by: :system)
      assert comment.user_id == nil
    end

    test "a deleted account leaves its comment standing, unattributed", %{card: card} do
      user = user_fixture("leaving@example.com")
      {:ok, comment} = Boards.add_comment(card, "Still useful", by: user)
      Slipdock.Repo.delete!(user)

      assert [%{id: id, body: "Still useful", user: nil}] = Boards.get_card!(card.id).comments
      assert id == comment.id
    end
  end
end
