defmodule Slipdock.Wiki.ExcalidrawReconcileTest do
  @moduledoc """
  Excalidraw's merge rule, ported (#823, W-1730): the same answers
  `reconcileElements` gives in the browser, so the server and every editor
  settle on the same drawing.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.Excalidraw.Reconcile

  defp el(id, version, nonce, extra \\ %{}),
    do: Map.merge(%{"id" => id, "version" => version, "versionNonce" => nonce}, extra)

  test "concurrent edits to one element: the higher version wins, whichever side it is on" do
    held = [el("a", 3, 50, %{"x" => 1})]

    assert {[%{"x" => 2}], [%{"x" => 2}]} = Reconcile.merge(held, [el("a", 4, 99, %{"x" => 2})])
    assert {[%{"x" => 1}], []} = Reconcile.merge(held, [el("a", 2, 1, %{"x" => 2})])
  end

  test "a tie on version goes to the lower nonce; an equal nonce lets the incoming one in" do
    held = [el("a", 3, 50, %{"x" => "held"})]

    assert {[%{"x" => "in"}], [_]} = Reconcile.merge(held, [el("a", 3, 10, %{"x" => "in"})])
    assert {[%{"x" => "held"}], []} = Reconcile.merge(held, [el("a", 3, 90, %{"x" => "in"})])
    assert {[%{"x" => "in"}], [_]} = Reconcile.merge(held, [el("a", 3, 50, %{"x" => "in"})])

    # Both sides reach the same answer, whichever of them is "held".
    {one, _} = Reconcile.merge([el("a", 3, 10, %{"x" => 1})], [el("a", 3, 90, %{"x" => 2})])
    {two, _} = Reconcile.merge([el("a", 3, 90, %{"x" => 2})], [el("a", 3, 10, %{"x" => 1})])
    assert one == two
  end

  test "a deletion against an edit is decided by version, and the tombstone is kept" do
    edited = el("a", 5, 1, %{"x" => 9})
    deleted = el("a", 6, 1, %{"isDeleted" => true})

    assert {[%{"isDeleted" => true}], [_]} = Reconcile.merge([edited], [deleted])
    assert {[%{"isDeleted" => true}], []} = Reconcile.merge([deleted], [edited])
    assert {[%{"x" => 9}], [_]} = Reconcile.merge([deleted], [el("a", 7, 1, %{"x" => 9})])
  end

  test "new elements from both sides are all kept, in z-order by index then id" do
    held = [el("h1", 1, 1, %{"index" => "a2"}), el("h2", 1, 1, %{"index" => "a0"})]
    incoming = [el("i1", 1, 1, %{"index" => "a1"}), el("i0", 1, 1, %{"index" => "a1"})]

    {merged, winners} = Reconcile.merge(held, incoming)
    assert Enum.map(merged, & &1["id"]) == ["h2", "i0", "i1", "h1"]
    assert Enum.map(winners, & &1["id"]) == ["i1", "i0"]
  end

  test "without indices the incoming come first, then the rest as they were held" do
    held = [el("h1", 1, 1), el("shared", 1, 1), el("h2", 1, 1)]
    {merged, _} = Reconcile.merge(held, [el("shared", 2, 1), el("new", 1, 1)])
    assert Enum.map(merged, & &1["id"]) == ["shared", "new", "h1", "h2"]

    loose = [el("z", 1, 1), el("y", 1, 1, %{"index" => "a0"})]
    assert Enum.map(Reconcile.order(loose), & &1["id"]) == ["y", "z"]
  end

  test "an element sent twice counts once; one without an id or a version is handled" do
    {merged, winners} = Reconcile.merge([], [el("a", 2, 1), el("a", 9, 1), %{"x" => 1}])
    assert [%{"version" => 2}] = merged
    assert length(winners) == 1

    # No version reads as 0: anything versioned beats it.
    assert {[%{"version" => 1}], [_]} = Reconcile.merge([%{"id" => "b"}], [el("b", 1, 1)])
  end
end
