defmodule SlipdockWeb.API.GardenJSONTest do
  @moduledoc """
  A suggestion's steps name their page by code as well as id (#2592): the
  proposal's and each alternative's, a page the subject doesn't list too,
  and a deleted page keeps its id alone.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Gardener.Suggestion
  alias SlipdockWeb.API.GardenJSON

  setup do
    owner = user_fixture("garden-json@example.com")
    board = board_fixture(%{}, owner: owner)
    {:ok, page} = Slipdock.Wiki.create_page(board, %{"title" => "Runbok", "body" => "x"})
    {:ok, other} = Slipdock.Wiki.create_page(board, %{"title" => "Runbook", "body" => "y"})
    %{board: board, page: page, other: other}
  end

  test "each step on a page gains its page_code; card steps and a gone page don't", ctx do
    s = %Suggestion{
      id: 1,
      board_id: ctx.board.id,
      check: "orphan_pages",
      state: "open",
      explanation: "nothing links to it",
      # The subject lists one page; the alternative's step is on another.
      subject: %{"cards" => [], "pages" => [ctx.page.id]},
      proposal: [
        %{"op" => "archive", "page" => ctx.page.id},
        %{"op" => "comment", "card" => 7, "body" => "hi"},
        %{"op" => "archive", "page" => -1}
      ],
      alternatives: %{
        "file" => [%{"op" => "file_page", "page" => ctx.other.id, "folder" => nil}]
      }
    }

    [json] = GardenJSON.suggestions([s])

    assert [archive, comment, gone] = json.proposal
    assert archive == %{"op" => "archive", "page" => ctx.page.id, "page_code" => ctx.page.code}
    assert comment == %{"op" => "comment", "card" => 7, "body" => "hi"}
    assert gone == %{"op" => "archive", "page" => -1}

    assert [%{"page" => other_id, "page_code" => other_code}] = json.alternatives["file"]
    assert {other_id, other_code} == {ctx.other.id, ctx.other.code}
    assert is_binary(other_code) and other_code =~ ~r/^[A-Z]+-\d+$/

    # The subject's pages are as they were: the alternative's page isn't added.
    assert [%{id: id}] = json.pages
    assert id == ctx.page.id
  end

  test "a suggestion with no alternatives keeps an empty map", ctx do
    s = %Suggestion{
      id: 2,
      board_id: ctx.board.id,
      check: "proposal",
      state: "open",
      explanation: "e",
      subject: %{"cards" => [], "pages" => []},
      proposal: [],
      alternatives: nil
    }

    assert [%{alternatives: %{}, proposal: []}] = GardenJSON.suggestions([s])
  end
end
