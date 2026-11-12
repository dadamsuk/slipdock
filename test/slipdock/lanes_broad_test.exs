defmodule Slipdock.LanesBroadTest do
  @moduledoc """
  Broad lanes (#2698): `Lanes.broad?/2` judges a glob that claims a whole
  top-level directory (a `**` at most one directory below the root, not
  wholly inside a shared path), and the claimed job's Paths block marks it
  beside the glob. Advice only: nothing is refused for it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Lanes, Runners}

  describe "broad?/2" do
    test "a ** at depth 0 or 1 under the root is broad" do
      for glob <- ~w(** lib/** lib/slipdock/** lib/slipdock_web/** cli/** cli/lib/** docs/**
                     assets/** test/** ./lib/** lib/slipdock/**/ */**) do
        assert Lanes.broad?(glob, []), glob
      end
    end

    test "a deeper ** is not broad" do
      for glob <- ~w(lib/slipdock/runners/** cli/lib/slipdock_cli/** test/slipdock/lanes/**) do
        refute Lanes.broad?(glob, []), glob
      end
    end

    test "a file, or a glob whose last segment isn't **, is not broad" do
      for glob <-
            ~w(lib/slipdock/lanes.ex README.md lib/*.ex lib/slipdock/* lib test/**/*_test.exs) do
        refute Lanes.broad?(glob, []), glob
      end
    end

    test "a glob wholly inside a shared path is not broad; one only partly inside still is" do
      refute Lanes.broad?("test/**", ["test/**"])
      refute Lanes.broad?("docs/manual/**", ["docs/**"])
      assert Lanes.broad?("docs/**", ["docs/manual.md"])
      assert Lanes.broad?("test/**", nil)
    end

    test "a {a,b} glob is broad when any expansion is" do
      assert Lanes.broad?("{lib/slipdock/runners,docs}/**", [])
      refute Lanes.broad?("lib/slipdock/{runners,lanes}/**", [])
    end

    test "broad_paths/2 keeps the broad globs in order, and reads nil as none" do
      assert Lanes.broad_paths(["lib/a.ex", "docs/**", "lib/**"], []) == ["docs/**", "lib/**"]
      assert Lanes.broad_paths(nil, []) == []
      assert Lanes.broad_reason() =~ "overlaps most cards"
    end
  end

  describe "broad_overlap/3" do
    test "names the side whose broad glob meets the other's paths" do
      wide = %Boards.Card{paths: ["lib/**"]}
      narrow = %Boards.Card{paths: ["lib/slipdock/runners/a.ex"]}

      assert Lanes.broad_overlap(narrow, wide, []) == %{
               side: "other",
               this: [],
               other: ["lib/**"]
             }

      assert %{side: "this", this: ["lib/**"]} = Lanes.broad_overlap(wide, narrow, [])
      assert %{side: "both"} = Lanes.broad_overlap(wide, %Boards.Card{paths: ["lib/x/**"]}, [])

      assert Lanes.broad_overlap(narrow, %Boards.Card{paths: ["lib/slipdock/runners/**"]}, []) ==
               nil
    end

    test "a broad glob that doesn't meet the other's paths, or is shared, isn't named" do
      card = %Boards.Card{paths: ["docs/**", "lib/slipdock/a.ex"]}
      other = %Boards.Card{paths: ["lib/slipdock/a.ex"]}
      assert Lanes.broad_overlap(card, other, []) == nil

      # The other card's broad glob that misses this card's paths isn't named either.
      assert Lanes.broad_overlap(other, card, []) == nil

      assert Lanes.broad_overlap(
               %Boards.Card{paths: ["docs/**"]},
               %Boards.Card{paths: ["docs/a.md"]},
               ["docs/**"]
             ) == nil
    end
  end

  describe "the claimed job's Paths block" do
    setup do
      owner = user_fixture()
      board = board_fixture(%{"name" => "Broad"}, owner: owner)
      [_backlog, todo, _doing, _done] = board.columns
      %{board: board, todo: todo, owner: owner}
    end

    defp prompt_for(column, paths) do
      card = card_fixture(column, %{"title" => "Pathed"})
      {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths})
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
      Runners.claimed_prompt(Repo.reload!(job))
    end

    test "a broad glob is marked beside itself, with the reason and that it is advice", ctx do
      prompt = prompt_for(ctx.todo, "lib/**\nlib/slipdock/runners/a.ex")

      assert prompt =~
               "lib/**  (broad: it overlaps most cards; name the files or the deepest directory the change touches)\nlib/slipdock/runners/a.ex"

      assert prompt =~ "narrow it on the card before you start"
      assert prompt =~ "nothing is refused for it"
    end

    test "narrow and shared globs are not marked", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"shared_paths" => ["test/**"]})
      prompt = prompt_for(ctx.todo, "lib/slipdock/runners/**\ntest/**")
      refute prompt =~ "broad"
      assert prompt =~ "lib/slipdock/runners/**\ntest/**"
    end
  end
end
