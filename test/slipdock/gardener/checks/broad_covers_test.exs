defmodule Slipdock.Gardener.Checks.BroadCoversTest do
  @moduledoc "Handbook pages whose `covers:` matches nearly everything (#1790)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.GardenerHelpers

  alias Slipdock.{Boards, Gardener, Handbook, Wiki}
  alias Slipdock.Gardener.Checks.BroadCovers
  alias Slipdock.Gardener.Settings

  setup do
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    %{user: user, board: board}
  end

  defp page(board, title), do: Enum.find(Handbook.find(board).pages, &(&1.title == title))

  defp set_covers(page, covers) do
    front = String.replace(page.front_matter, ~r/^covers:.*$/m, "covers: #{covers}")
    {:ok, page} = Wiki.update_page(page, %{"front_matter" => front})
    page
  end

  test "broad?/1: ** with fewer than two folders before the first wildcard" do
    for glob <- ["**", "lib/**", "./lib/**", "lib/sl*/**", "**/*.ex", " lib/** "],
        do: assert(BroadCovers.broad?(glob), glob)

    for glob <- ["lib/slipdock/**", "config/*.exs", "lib/*", "mix.exs", "priv/repo/migrations/**"],
        do: refute(BroadCovers.broad?(glob), glob)
  end

  test "a board without a handbook finds nothing", %{user: user, board: board} do
    page_fixture(board, %{"front_matter" => "---\ncovers: [lib/**]\n---\n"}, user: user)
    assert find(BroadCovers, board) == []
  end

  test "a page covering lib/** is found, its narrow globs aren't named; applying asks on the Index",
       %{user: user, board: board} do
    {:ok, _} = Handbook.install(user, board)
    # A new handbook covers nothing yet.
    assert find(BroadCovers, board) == []
    hb = Handbook.find(board)

    arch = set_covers(page(board, "Architecture"), "[lib/**, lib/app/accounts/**]")
    _near = set_covers(page(board, "Data model"), "[lib/app/schemas/**, priv/repo/*.exs]")

    assert [finding] = find(BroadCovers, board)
    assert finding.subject == %{"pages" => [arch.id, hb.index.id]}
    assert finding.state == ["lib/**", "lib/app/accounts/**"]

    assert finding.explanation =~
             "“Architecture” covers `lib/**`, which matches nearly every path"

    refute finding.explanation =~ "accounts"

    assert [%{"op" => "comment", "page" => index_id, "body" => body}] = finding.proposal
    assert index_id == hb.index.id
    assert body =~ "Narrow `covers:` on “Architecture” (#{arch.code})"

    {:ok, _} = Gardener.run(board, only: ["broad_covers"])
    [s] = Gardener.list_open(board)
    {:ok, _} = Gardener.apply(s, user)

    assert [^body] =
             Repo.all(from(c in Boards.Comment, where: c.page_id == ^hb.index.id, select: c.body))
  end

  test "narrowing covers clears it; off is off", %{user: user, board: board} do
    {:ok, _} = Handbook.install(user, board)
    set_covers(page(board, "Architecture"), "[\"**\"]")
    {:ok, run} = Gardener.run(board, only: ["broad_covers"])
    assert run.counts["total"] == 1

    set_covers(page(board, "Architecture"), "[lib/app/web/**]")
    {:ok, run} = Gardener.run(board, only: ["broad_covers"])
    assert run.counts["total"] == 0

    set_covers(page(board, "Architecture"), "[lib/**]")
    {:ok, board} = Settings.put(board, BroadCovers, %{"enabled" => false})
    {:ok, run} = Gardener.run(board, only: ["broad_covers"])
    assert run.counts["total"] == 0
  end
end
