defmodule Slipdock.Gardener.Checks.StaleDecisionTest do
  @moduledoc "Decisions that supersede one without linking back, or aren't titled as decisions (#1790)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Gardener, Handbook, Wiki}
  alias Slipdock.Gardener.Checks.StaleDecision
  alias Slipdock.Gardener.Settings

  setup do
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    %{user: user, board: board}
  end

  defp install(user, board) do
    {:ok, _} = Handbook.install(user, board)
    {:ok, folder} = Wiki.Folders.find(board, "/" <> Handbook.decisions_folder())
    %{handbook: Handbook.find(board), folder: folder}
  end

  defp decision(board, folder, title, body, user) do
    {:ok, page} =
      Wiki.create_page(board, %{"title" => title, "folder_id" => folder.id, "body" => body},
        user: user
      )

    page
  end

  test "a board without a handbook finds nothing", %{user: user, board: board} do
    page_fixture(board, %{"title" => "Decision: Old store"}, user: user)

    page_fixture(board, %{"title" => "Use Redis", "body" => "Supersedes Decision: Old store."},
      user: user
    )

    assert find(StaleDecision, board) == []
  end

  test "a decision that names the one it supersedes without linking it is found; a link isn't",
       %{user: user, board: board} do
    %{handbook: hb, folder: folder} = install(user, board)
    assert find(StaleDecision, board) == []

    old = decision(board, folder, "Decision: Use Postgres", "We chose Postgres.", user)

    new =
      decision(board, folder, "Decision: Use SQLite", "Supersedes Decision: Use Postgres.", user)

    assert [finding] = find(StaleDecision, board)
    assert finding.subject == %{"pages" => [new.id, old.id, hb.index.id]}

    assert finding.explanation ==
             "“Decision: Use SQLite” supersedes “Decision: Use Postgres” without linking back to it"

    assert [%{"op" => "comment", "page" => index_id, "body" => body}] = finding.proposal
    assert index_id == hb.index.id
    assert body =~ "`Supersedes [[Decision: Use Postgres]].`"

    # The near miss: the same words, as a link.
    {:ok, _} = Wiki.update_page(new, %{"body" => "Supersedes [[Decision: Use Postgres]]."})
    assert find(StaleDecision, board) == []
  end

  test "named by its short title, or from the old page's 'superseded by'; a bare code links",
       %{user: user, board: board} do
    %{folder: folder} = install(user, board)
    old = decision(board, folder, "Decision: Queue on Oban", "Body.", user)

    new =
      decision(board, folder, "Decision: Queue on Broadway", "This replaces queue on oban.", user)

    assert [%{explanation: e}] = find(StaleDecision, board)
    assert e =~ "“Decision: Queue on Broadway” supersedes “Decision: Queue on Oban”"

    # The wiki reads a bare code as a link, so naming it by code links back.
    {:ok, _} = Wiki.update_page(new, %{"body" => "Supersedes #{old.code}, for throughput."})
    assert find(StaleDecision, board) == []

    # The old page says so instead; the new one says nothing of it.
    {:ok, _} = Wiki.update_page(new, %{"body" => "Broadway it is."})
    assert find(StaleDecision, board) == []

    {:ok, _} =
      Wiki.update_page(old, %{"body" => "Superseded by [[Decision: Queue on Broadway]]."})

    assert [%{explanation: e}] = find(StaleDecision, board)
    assert e =~ "“Decision: Queue on Broadway” supersedes “Decision: Queue on Oban”"

    {:ok, _} = Wiki.update_page(new, %{"body" => "Broadway, after [[Decision: Queue on Oban]]."})
    assert find(StaleDecision, board) == []
  end

  test "near misses: a mention that isn't superseding, and a short title", %{
    user: user,
    board: board
  } do
    %{folder: folder} = install(user, board)
    decision(board, folder, "Decision: Redis", "Body.", user)

    decision(
      board,
      folder,
      "Decision: Use Postgres",
      "Unlike Decision: Redis, this one stays.",
      user
    )

    decision(board, folder, "Decision: Caching", "Supersedes nothing; redis is still fine.", user)
    assert find(StaleDecision, board) == []
  end

  test "a page in Decisions without Decision: in its title is found; elsewhere it isn't",
       %{user: user, board: board} do
    %{handbook: hb, folder: folder} = install(user, board)
    page = decision(board, folder, "Use Redis", "Body.", user)
    decision(board, folder, "decision: lower case counts", "Body.", user)
    page_fixture(board, %{"title" => "Meeting notes"}, user: user)

    assert [finding] = find(StaleDecision, board)
    assert finding.subject == %{"pages" => [page.id, hb.index.id]}

    assert finding.explanation ==
             "“Use Redis” is filed in Handbook/Decisions without “Decision:” in its title"

    assert [%{"op" => "comment", "body" => body}] = finding.proposal
    assert body =~ "Rename “Use Redis” (#{page.code}) to “Decision: <what was chosen>”"

    {:ok, _} = Gardener.run(board, only: ["stale_decision"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.dismiss(s, user)
    {:ok, run} = Gardener.run(board, only: ["stale_decision"])
    assert run.counts["total"] == 0

    # Renamed: gone for good.
    {:ok, _} = Wiki.update_page(page, %{"title" => "Decision: Use Redis"})
    assert find(StaleDecision, board) == []

    {:ok, board} = Settings.put(board, StaleDecision, %{"enabled" => false})
    refute Settings.enabled?(board, StaleDecision)
  end
end
