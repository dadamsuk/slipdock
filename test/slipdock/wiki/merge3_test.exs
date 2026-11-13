defmodule Slipdock.Wiki.Merge3Test do
  @moduledoc "The line-level three-way merge proposals on one section apply through (#2772)."
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.Merge3

  @base ~w(a b c d e)

  test "changes to different lines are both kept" do
    assert Merge3.merge(@base, ~w(A b c d e), ~w(a b c d E)) == {:ok, ~w(A b c d E)}
  end

  test "changes to neighbouring lines are both kept" do
    assert Merge3.merge(@base, ~w(a B c d e), ~w(a b C d e)) == {:ok, ~w(a B C d e)}
  end

  test "the same change on both sides is taken once" do
    assert Merge3.merge(@base, ~w(a X c d e), ~w(a X c d E)) == {:ok, ~w(a X c d E)}
  end

  test "different changes to the same line conflict, naming it" do
    assert Merge3.merge(@base, ~w(a X c d e), ~w(a Y c d e)) == {:conflict, ["b"]}
  end

  test "a change and a deletion of the same line conflict" do
    assert {:conflict, ["b"]} = Merge3.merge(@base, ~w(a X c d e), ~w(a c d e))
  end

  test "an insertion inside lines the other replaces conflicts" do
    assert {:conflict, _} = Merge3.merge(@base, ~w(a X e), ~w(a b c new d e))
  end

  test "two insertions at one place are both kept, ours first" do
    assert Merge3.merge(@base, ~w(a b c d e x), ~w(a b c d e y)) == {:ok, ~w(a b c d e x y)}
  end

  test "an insertion and a deletion elsewhere" do
    assert Merge3.merge(@base, ~w(a b new c d e), ~w(a b c e)) == {:ok, ~w(a b new c e)}
  end

  test "one side unchanged gives the other" do
    assert Merge3.merge(@base, @base, ~w(z a c)) == {:ok, ~w(z a c)}
    assert Merge3.merge(@base, ~w(z a c), @base) == {:ok, ~w(z a c)}
  end

  test "merge_text/3 works on text, ignoring trailing blank lines" do
    assert Merge3.merge_text("a\nb\nc\n\n", "A\nb\nc", "a\nb\nC\n") == {:ok, "A\nb\nC"}
  end
end
