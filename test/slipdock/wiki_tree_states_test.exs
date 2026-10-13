defmodule Slipdock.WikiTreeStatesTest do
  @moduledoc "What a reader has open in a wiki's tree, kept per reader and per tree (W-103 R11.7)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki.TreeStates

  test "nothing kept is nil; what is put comes back, replacing the last" do
    user = user_fixture()
    scope = TreeStates.scope(:board, 4)

    assert TreeStates.get(user, scope) == nil
    assert {:ok, ["folder:1", "page:2"]} = TreeStates.put(user, scope, ["folder:1", "page:2"])
    assert TreeStates.get(user, scope) == ["folder:1", "page:2"]

    TreeStates.put(user, scope, [])
    assert TreeStates.get(user, scope) == []
  end

  test "each reader and each tree keeps its own" do
    one = user_fixture("one.tree@example.com")
    two = user_fixture("two.tree@example.com")

    TreeStates.put(one, TreeStates.scope(:board, 1), ["folder:1"])
    TreeStates.put(one, TreeStates.scope(:vault, 1), ["dir:Projects", "board:3"])

    assert TreeStates.get(two, TreeStates.scope(:board, 1)) == nil
    assert TreeStates.get(one, "vault:1") == ["dir:Projects", "board:3"]
    assert TreeStates.get(nil, "board:1") == nil
  end

  test "only the tree's own keys are kept, each once, and at most 300" do
    user = user_fixture()
    junk = ["folder:x", "card:3", 7, nil, "folder:1", "folder:1", "dir:", "root"]

    assert {:ok, ["folder:1"]} = TreeStates.put(user, "board:9", junk)

    many = for n <- 1..400, do: "page:#{n}"
    {:ok, kept} = TreeStates.put(user, "board:9", many)
    assert length(kept) == 300
    assert TreeStates.put(user, nil, ["folder:1"]) == {:error, :invalid}
  end
end
