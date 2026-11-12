defmodule Slipdock.ReleasesTest do
  @moduledoc """
  Batched releases (#2834): the board's `release_mode` and
  `release_age_cap_hours` (validated, the root's alone, read from the root
  by every board of the tree) and a card's release state worked out from
  the Deployments record: nothing on an on_merge board or for a card that
  hasn't merged; awaiting until a succeeded deploy names it; released after.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments, Releases, Repo}
  alias Slipdock.Boards.Card

  setup do
    owner = user_fixture("releases-#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Releases", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"delivery_metrics" => true})
    [_backlog, todo | _] = board.columns
    %{board: board, todo: todo}
  end

  defp batched!(board, attrs \\ %{}) do
    {:ok, board} =
      Boards.update_board(
        Boards.get_board!(board.id),
        Map.merge(%{"release_mode" => "batched"}, attrs)
      )

    board
  end

  # A card accepted and merged at `sha`, as the merge job leaves it.
  defp merge!(card, fields \\ []) do
    Repo.update_all(
      from(c in Card, where: c.id == ^card.id),
      set:
        Keyword.merge(
          [
            completed: true,
            completed_at: ~U[2026-11-12 10:04:00Z],
            verify_state: "accepted",
            merge_sha: "abc1234def5678"
          ],
          fields
        )
    )

    Repo.get!(Card, card.id)
  end

  defp deploy!(board, card, at, status \\ "succeeded") do
    {:ok, d} =
      Deployments.start(board, %{
        environment: "production",
        sha: "feed00#{System.unique_integer([:positive])}",
        status: status,
        started_at: at,
        finished_at: at,
        commits: [%{"sha" => "abc1234def5678", "subject" => "feat ##{card.id}"}]
      })

    d
  end

  describe "the settings" do
    test "default to on_merge with no age cap", %{board: board} do
      assert {board.release_mode, board.release_age_cap_hours} == {"on_merge", nil}
      assert Releases.settings(board) == %{mode: "on_merge", age_cap_hours: nil, command: nil}
      refute Releases.batched?(board)
    end

    test "batched with an age cap; a mode is tidied (Batched, on-merge)", %{board: board} do
      board = batched!(board, %{"release_mode" => " Batched ", "release_age_cap_hours" => 24})
      assert Releases.settings(board) == %{mode: "batched", age_cap_hours: 24, command: nil}
      assert Releases.batched?(board.id)

      {:ok, board} = Boards.update_board(board, %{"release_mode" => "on-merge"})
      assert board.release_mode == "on_merge"
    end

    test "an unknown mode and an age cap out of range are refused", %{board: board} do
      {:error, cs} = Boards.update_board(board, %{"release_mode" => "weekly"})
      assert "must be on_merge or batched" in errors_on(cs).release_mode

      for hours <- [0, 8761] do
        {:error, cs} = Boards.update_board(board, %{"release_age_cap_hours" => hours})

        assert errors_on(cs).release_age_cap_hours == [
                 "must be 1 hour to 8760 (a year), or blank for off"
               ]
      end

      board = batched!(board, %{"release_age_cap_hours" => 6})
      {:ok, board} = Boards.update_board(board, %{"release_age_cap_hours" => ""})
      assert board.release_age_cap_hours == nil
    end

    test "a sub-board reads its root's and refuses its own, naming the root", %{
      board: board,
      todo: todo
    } do
      board = batched!(board, %{"release_age_cap_hours" => 12})
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(todo, %{"title" => "Epic"}), t)

      assert Releases.settings(sub) == %{mode: "batched", age_cap_hours: 12, command: nil}
      assert Releases.settings(sub.id) == %{mode: "batched", age_cap_hours: 12, command: nil}

      {:error, cs} = Boards.update_board(sub, %{"release_mode" => "batched"})
      assert errors_on(cs).release_mode == ["is set on the tree's root board (#{board.code})"]

      {:error, cs} = Boards.update_board(sub, %{"release_age_cap_hours" => 3})

      assert errors_on(cs).release_age_cap_hours == [
               "is set on the tree's root board (#{board.code})"
             ]

      # Anything else on the sub-board still saves.
      assert {:ok, _} = Boards.update_board(sub, %{"name" => "Renamed"})
    end

    test "a board that isn't there reads as on_merge" do
      assert Releases.settings(-1) == %{mode: "on_merge", age_cap_hours: nil, command: nil}
    end
  end

  describe "a card's release state" do
    test "nothing on an on_merge board, even merged", %{todo: todo} do
      card = todo |> card_fixture(%{"title" => "Feature"}) |> merge!()
      assert Releases.state(card) == nil
    end

    test "nothing on a batched board until it merges", %{board: board, todo: todo} do
      batched!(board)
      card = card_fixture(todo, %{"title" => "Feature"})
      assert Releases.state(card) == nil

      # Completed but not accepted: a person ticked it, nothing merged.
      ticked = merge!(card, verify_state: nil)
      assert Releases.state(ticked) == nil

      # Accepted, but no commit to have merged.
      assert Releases.state(merge!(card, merge_sha: nil)) == nil
    end

    test "nothing for an accepted card with a commit that isn't completed", %{
      board: board,
      todo: todo
    } do
      batched!(board)
      card = todo |> card_fixture(%{"title" => "Reopened"}) |> merge!(completed: false)
      assert Releases.state(card) == nil
    end

    test "an awaiting state with no merge time says no since", %{board: board, todo: todo} do
      batched!(board)
      card = todo |> card_fixture(%{"title" => "Old"}) |> merge!(completed_at: nil)

      assert %{state: "awaiting", merged_at: nil} = state = Releases.state(card)
      assert Releases.text(state) == "Merged abc1234, awaiting release"
    end

    test "awaiting once merged, released once a succeeded deploy names it", %{
      board: board,
      todo: todo
    } do
      batched!(board)
      card = todo |> card_fixture(%{"title" => "Feature"}) |> merge!()

      assert %{state: "awaiting", sha: "abc1234def5678", merged_at: ~U[2026-11-12 10:04:00Z]} =
               state = Releases.state(card)

      assert Releases.text(state) == "Merged abc1234, awaiting release · since 12 Nov 10:04"

      deploy!(board, card, ~U[2026-11-12 13:00:00.000000Z], "failed")
      assert %{state: "awaiting"} = Releases.state(card)

      d = deploy!(board, card, ~U[2026-11-12 14:32:00.000000Z])

      assert %{state: "released", environment: "production", deployment_id: id} =
               state = Releases.state(card)

      assert id == d.id
      assert Releases.text(state) == "Released to production · 12 Nov 14:32"
      assert Releases.text(state, "America/New_York") == "Released to production · 12 Nov 09:32"
    end

    test "on a board that ships by push, the commit it was accepted at", %{
      board: board,
      todo: todo
    } do
      batched!(board)
      card = card_fixture(todo, %{"title" => "Feature"})

      assert %{state: "awaiting", sha: "0ddba11"} =
               Releases.state(merge!(card, merge_sha: nil, verify_commit: "0ddba11"))

      assert %{state: "awaiting", sha: "e1de0ce"} =
               Releases.state(
                 merge!(card, merge_sha: nil, verify_commit: nil, evidence_commit: "e1de0ce")
               )
    end

    test "a subcard on a batched root's sub-board", %{board: board, todo: todo} do
      batched!(board)
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card_fixture(todo, %{"title" => "Epic"}), t)
      [first | _] = Boards.get_board!(sub.id).columns
      child = first |> card_fixture(%{"title" => "Child"}) |> merge!()

      assert %{state: "awaiting"} = Releases.state(child)
    end
  end
end
