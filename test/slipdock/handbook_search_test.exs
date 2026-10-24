defmodule Slipdock.HandbookSearchTest do
  @moduledoc """
  A handbook's suggested reading by semantic search (#1264), when the server
  has embeddings: the sections the search index matches come back, by their
  heading path. The model is stubbed (`Slipdock.AIStub`), so this checks the
  wiring, not anybody's vectors.
  """
  # Sync: the search indexer is one process for the node, so the stub is shared.
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Handbook, Repo, Search, Wiki}
  alias Slipdock.Wiki.Page

  setup do
    Slipdock.AIStub.share()
    Slipdock.AIStub.stub_embeddings()
    :ok
  end

  test "a section the search index matches is suggested with its heading path" do
    user = user_fixture()
    board = board_fixture(%{"name" => "Searchable"}, owner: user)
    {:ok, _} = Handbook.install(user, board)

    ops = Repo.get_by!(Page, board_id: board.id, title: "Operations")

    {:ok, ops} =
      Wiki.update_page(ops, %{
        "body" =>
          "# Operations\n\n## Deploy\n\nPush to main.\n\n## Zanzibar rollback\n\nZanzibar quokka rollback procedure.\n"
      })

    for page <- Handbook.find(board).pages, do: {:ok, _} = Search.index_page(page.id)

    [col | _] = board.columns
    card = card_fixture(col, %{"title" => "Zanzibar quokka rollback"})

    suggested = Handbook.for_card(card, user).suggested

    assert %{page: code, section: "Operations/Zanzibar rollback"} =
             Enum.find(suggested, &(&1.why == "matches the card"))

    assert code == ops.code
  end
end
