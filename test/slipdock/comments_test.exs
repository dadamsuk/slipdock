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
end
