defmodule Slipdock.Wiki.LineChangesTest do
  @moduledoc "A revision's changes in lines, as the wiki history shows them (#1698)."
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.{LineChanges, Revision}

  describe "count/2" do
    test "a first version adds every line, the trailing newline making none" do
      assert LineChanges.count(nil, "a\nb\nc\n") == {3, 0}
      assert LineChanges.count("", "a") == {1, 0}
    end

    test "an edit counts the line replaced as one removed and one added" do
      assert LineChanges.count("a\nb\nc", "a\nB\nc") == {1, 1}
    end

    test "the same text changes nothing; nothing to nothing is nothing" do
      assert LineChanges.count("a\nb", "a\nb") == {0, 0}
      assert LineChanges.count(nil, "") == {0, 0}
    end

    test "emptying a page removes every line" do
      assert LineChanges.count("a\nb", "") == {0, 2}
    end

    test "a long page is counted by which lines are there" do
      old = Enum.map_join(1..3_000, "\n", &"line #{&1}")
      new = old <> "\nextra"
      assert LineChanges.count(old, new) == {1, 0}
      assert LineChanges.count(new, old) == {0, 1}
    end
  end

  describe "for_revisions/2" do
    defp rev(id, title, body), do: %Revision{id: id, title: title, body: body}

    test "compares each version with the one before, newest first in" do
      first = rev(1, "T", "a\n")
      second = rev(2, "T", "a\nb\n")
      third = rev(3, "T2", "a\nb\n")

      changes = LineChanges.for_revisions([third, second, first])

      assert changes[1] == %{added: 1, removed: 0, title?: false}
      assert changes[2] == %{added: 1, removed: 0, title?: false}
      assert changes[3] == %{added: 0, removed: 0, title?: true}
    end

    test "the oldest listed is compared with the one before it when given" do
      before = rev(1, "T", "a\nb\n")
      listed = rev(2, "T", "a\n")

      assert LineChanges.for_revisions([listed], before)[2] ==
               %{added: 0, removed: 1, title?: false}
    end

    test "no versions, no changes" do
      assert LineChanges.for_revisions([]) == %{}
    end
  end

  describe "label/1" do
    test "reads as a person would say it" do
      assert LineChanges.label(%{added: 12, removed: 3, title?: false}) == "+12 −3 lines"
      assert LineChanges.label(%{added: 1, removed: 0, title?: false}) == "+1 line"
      assert LineChanges.label(%{added: 4, removed: 0, title?: true}) == "+4 lines"
      assert LineChanges.label(%{added: 0, removed: 1, title?: false}) == "−1 line"
      assert LineChanges.label(%{added: 0, removed: 0, title?: true}) == "title only"
      assert LineChanges.label(%{added: 0, removed: 0, title?: false}) == "no changes"
    end
  end
end
