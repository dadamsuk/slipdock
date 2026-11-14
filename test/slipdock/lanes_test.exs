defmodule Slipdock.LanesTest do
  @moduledoc """
  Card paths (#1628): how globs overlap, and how a card's `paths` are
  written and checked. What they still do once lanes went (#3178) is in
  `Slipdock.CardPathsTest`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Lanes}

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Paths"}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns
    %{owner: owner, board: board, todo: todo}
  end

  defp card(column, title, paths) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.Cards.update_card(card, %{"paths" => paths})
    card
  end

  describe "glob overlap" do
    test "the same path, or one under the other, overlaps" do
      assert Lanes.glob_overlap?("lib/a.ex", "lib/a.ex")
      assert Lanes.glob_overlap?("lib/foo", "lib/foo/bar.ex")
      assert Lanes.glob_overlap?("lib/foo/", "lib/foo/bar/baz.ex")
      assert Lanes.glob_overlap?("lib/foo/bar.ex", "lib")
      refute Lanes.glob_overlap?("lib/foo", "lib/foobar")
      refute Lanes.glob_overlap?("lib/a.ex", "lib/b.ex")
      refute Lanes.glob_overlap?("lib/a.ex", "test/a.ex")
    end

    test "** is any number of segments, * and ? stay in one" do
      assert Lanes.glob_overlap?("lib/**", "lib/a/b/c.ex")
      assert Lanes.glob_overlap?("**/*_test.exs", "test/slipdock/lanes_test.exs")
      assert Lanes.glob_overlap?("lib/**/runner.ex", "lib/slipdock/runners/runner.ex")
      assert Lanes.glob_overlap?("lib/*.ex", "lib/lanes.ex")
      refute Lanes.glob_overlap?("lib/*.ex", "test/lanes.ex")
      refute Lanes.glob_overlap?("lib/*.ex", "lib/lanes.exs")
      assert Lanes.glob_overlap?("lib/?.ex", "lib/a.ex")
      refute Lanes.glob_overlap?("lib/?.ex", "lib/ab.ex")
      # A * never crosses a /, but the file's own directory is under it.
      assert Lanes.glob_overlap?("lib/*", "lib/a/b.ex")
    end

    test "two wildcards overlap when some name matches both" do
      assert Lanes.glob_overlap?("lib/*_live.ex", "lib/board_*")
      refute Lanes.glob_overlap?("lib/*.ex", "lib/*.md")
      assert Lanes.glob_overlap?("**", "anything/at/all")
      assert Lanes.glob_overlap?("a/**/z", "a/b/**")
    end

    test "plain names are compared whole, wildcards by character (#1977)" do
      assert Lanes.glob_overlap?("lib/a/b/c/d/e.ex", "lib/a/b/c/d/e.ex")
      refute Lanes.glob_overlap?("lib/a/b/c/d/e.ex", "lib/a/b/c/d/f.ex")
      refute Lanes.glob_overlap?("lib/a/b/c/d/e.ex", "test/a/b/c/d/e.ex")
      assert Lanes.glob_overlap?("lib/**/e.ex", "lib/a/b/c/d/e.ex")
      refute Lanes.glob_overlap?("lib/**/e.ex", "test/a/b/c/d/e.ex")
      assert Lanes.glob_overlap?("lib/a/*/c/[de].ex", "lib/a/b/c/x.ex")
      assert Lanes.glob_overlap?("lib/a/?/c.ex", "lib/a/b/c.ex")
      refute Lanes.glob_overlap?("lib/a/?/c.ex", "lib/a/bb/c.ex")
      # The same wildcard segment on both sides overlaps.
      assert Lanes.glob_overlap?("lib/*_test.exs", "lib/*_test.exs")
    end

    test "{a,b} is either, and [..] is taken as any one character" do
      assert Lanes.glob_overlap?("docs/{manual,agents}.md", "docs/agents.md")
      refute Lanes.glob_overlap?("docs/{manual,agents}.md", "docs/readme.md")
      assert Lanes.glob_overlap?("lib/{a,b/{c,d}}.ex", "lib/b/d.ex")
      assert Lanes.glob_overlap?("lib/[ab].ex", "lib/c.ex")
    end

    test "lists overlap when any pair does; an empty list overlaps nothing" do
      assert Lanes.overlap?(["lib/a/**", "docs/x.md"], ["test/**", "docs/*.md"])
      refute Lanes.overlap?(["lib/a/**"], ["lib/b/**", "test/**"])
      refute Lanes.overlap?([], ["**"])
    end
  end

  describe "writing paths" do
    test "a list or a string, tidied", ctx do
      card = card(ctx.todo, "Tidy", " ./lib/a/** ,\ndocs/{manual,agents}.md\n\nlib/a/** ")
      assert card.paths == ["lib/a/**", "docs/{manual,agents}.md"]

      {:ok, card} = Boards.Cards.update_card(card, %{paths: ["test/x.exs"]})
      assert card.paths == ["test/x.exs"]

      {:ok, card} = Boards.Cards.update_card(card, %{"paths" => []})
      assert card.paths == []
    end

    test "absolute paths, .., unbalanced braces and too many are refused", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Bad"})

      for {paths, words} <- [
            {"/etc/passwd", "relative"},
            {"C:/x", "relative"},
            {"~/x", "relative"},
            {"lib/../secret", ".."},
            {"lib/{a,b.ex", "braces"},
            {Enum.map(1..51, &"p#{&1}"), "at most 50"},
            {[String.duplicate("a", 201)], "over 200"}
          ] do
        assert {:error, changeset} = Boards.Cards.update_card(card, %{"paths" => paths})
        {message, _} = changeset.errors[:paths]
        assert message =~ words, inspect(paths)
      end
    end
  end
end
