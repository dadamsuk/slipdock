defmodule Slipdock.HeaderLinksTest do
  @moduledoc "Boards and vaults pinned to the header as icons (#1205)."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, HeaderLinks, Repo, Vaults}
  alias Slipdock.HeaderLinks.HeaderLink

  setup do
    user = user_fixture()
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    ops = board_fixture(%{"name" => "Ops"}, owner: user)

    {:ok, vault} =
      Vaults.create_vault(user, %{"name" => "Notes #{System.unique_integer([:positive])}"})

    %{user: user, plan: plan, ops: ops, vault: vault}
  end

  defp names(user), do: Enum.map(HeaderLinks.list(user), & &1.name)

  describe "add/3" do
    test "pins a board and a vault, in the order they were added",
         %{user: user, plan: plan, vault: vault} do
      assert {:ok, %{kind: :board, icon: "star", name: "Plan"}} =
               HeaderLinks.add(user, plan, "star")

      assert {:ok, %{kind: :vault, icon: "book-open"}} = HeaderLinks.add(user, vault, "book-open")

      assert [%{kind: :board, target: %{id: plan_id}}, %{kind: :vault, target: %{id: vault_id}}] =
               HeaderLinks.list(user)

      assert {plan_id, vault_id} == {plan.id, vault.id}
    end

    test "pinning something again changes its icon and keeps its place",
         %{user: user, plan: plan, ops: ops} do
      {:ok, _} = HeaderLinks.add(user, plan, "star")
      {:ok, _} = HeaderLinks.add(user, ops, "flag")
      {:ok, _} = HeaderLinks.add(user, plan, "rocket-launch")

      assert [%{name: "Plan", icon: "rocket-launch"}, %{name: "Ops"}] = HeaderLinks.list(user)
      assert Repo.aggregate(HeaderLink, :count) == 2
    end

    test "refuses an icon that is not in the set", %{user: user, plan: plan} do
      for bad <- [nil, "", "skull", "hero-star"] do
        assert {:error, message} = HeaderLinks.add(user, plan, bad)
        assert message =~ "choose an icon"
      end

      assert HeaderLinks.list(user) == []
    end

    test "refuses a board the user cannot open, and someone else's vault",
         %{plan: plan, vault: vault} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, "board not found"} = HeaderLinks.add(stranger, plan, "star")
      assert {:error, "vault not found"} = HeaderLinks.add(stranger, vault, "star")
      assert HeaderLinks.list(stranger) == []
    end

    test "a board shared for reading can be pinned", %{plan: plan} do
      reader = user_fixture("reader@example.com")
      share_fixture(plan, reader, "read")
      assert {:ok, %{name: "Plan"}} = HeaderLinks.add(reader, plan, "star")
    end

    test "holds at most max/0 links", %{user: user} do
      for _ <- 1..HeaderLinks.max() do
        {:ok, _} = HeaderLinks.add(user, board_fixture(%{}, owner: user), "star")
      end

      assert {:error, message} = HeaderLinks.add(user, board_fixture(%{}, owner: user), "star")
      assert message =~ "holds #{HeaderLinks.max()}"
      assert length(HeaderLinks.list(user)) == HeaderLinks.max()
    end
  end

  describe "list/1" do
    test "leaves out an archived board, and draws it again when it comes back",
         %{user: user, plan: plan} do
      {:ok, _} = HeaderLinks.add(user, plan, "star")
      {:ok, archived} = Boards.archive_board(plan)
      assert HeaderLinks.list(user) == []

      {:ok, _} = Boards.unarchive_board(archived)
      assert names(user) == ["Plan"]
    end

    test "a share taken back takes the link off the header", %{plan: plan} do
      other = user_fixture("other@example.com")
      share_fixture(plan, other, "read")
      {:ok, _} = HeaderLinks.add(other, plan, "star")

      [grant] = Enum.filter(Access.list_grants(plan), &(&1.user_id == other.id))
      {:ok, _} = Access.revoke(grant)

      assert HeaderLinks.list(other) == []
    end

    test "a deleted vault's link goes with it", %{user: user, vault: vault} do
      {:ok, _} = HeaderLinks.add(user, vault, "star")
      {:ok, _} = Vaults.delete_vault(vault)
      assert HeaderLinks.list(user) == []
      assert Repo.aggregate(HeaderLink, :count) == 0
    end

    test "is empty for nobody", do: assert(HeaderLinks.list(nil) == [])

    test "is each person's own", %{user: user, plan: plan} do
      other = user_fixture("other@example.com")
      share_fixture(plan, other, "read")
      {:ok, _} = HeaderLinks.add(user, plan, "star")
      assert HeaderLinks.list(other) == []
    end
  end

  describe "remove/2 and move/3" do
    setup %{user: user, plan: plan, ops: ops, vault: vault} do
      {:ok, a} = HeaderLinks.add(user, plan, "star")
      {:ok, b} = HeaderLinks.add(user, ops, "flag")
      {:ok, c} = HeaderLinks.add(user, vault, "book-open")
      %{a: a, b: b, c: c}
    end

    test "remove takes one off and leaves the rest", %{user: user, b: b, vault: vault} do
      assert :ok = HeaderLinks.remove(user, b.id)
      assert names(user) == ["Plan", vault.name]
      assert {:error, :not_found} = HeaderLinks.remove(user, b.id)
    end

    test "nobody removes or moves someone else's", %{a: a} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, :not_found} = HeaderLinks.remove(stranger, a.id)
      assert {:error, :not_found} = HeaderLinks.move(stranger, a.id, :right)
    end

    test "move swaps a link with its neighbour", %{user: user, a: a, c: c, vault: vault} do
      assert :ok = HeaderLinks.move(user, a.id, :right)
      assert names(user) == ["Ops", "Plan", vault.name]

      assert :ok = HeaderLinks.move(user, c.id, :left)
      assert names(user) == ["Ops", vault.name, "Plan"]
    end

    test "at either end a link stays put", %{user: user, a: a, c: c, vault: vault} do
      assert :ok = HeaderLinks.move(user, a.id, :left)
      assert :ok = HeaderLinks.move(user, c.id, :right)
      assert names(user) == ["Plan", "Ops", vault.name]
    end

    test "a new link goes after a reordered set", %{user: user, a: a, vault: vault} do
      :ok = HeaderLinks.move(user, a.id, :right)
      {:ok, _} = HeaderLinks.add(user, board_fixture(%{"name" => "Last"}, owner: user), "fire")
      assert names(user) == ["Ops", "Plan", vault.name, "Last"]
    end
  end

  describe "resolve/2" do
    test "reads board: and vault: references", %{user: user, plan: plan, vault: vault} do
      assert {:ok, %{id: id}} = HeaderLinks.resolve(user, "board:#{plan.id}")
      assert id == plan.id
      assert {:ok, %{id: id}} = HeaderLinks.resolve(user, "vault:#{vault.id}")
      assert id == vault.id
      assert {:ok, %{id: ^id}} = HeaderLinks.resolve(user, :vault, vault.name)
    end

    test "says what it could not find", %{user: user, vault: vault} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, "vault not found"} = HeaderLinks.resolve(stranger, "vault:#{vault.id}")
      assert {:error, "board not found"} = HeaderLinks.resolve(user, "board:999999999")
      assert {:error, "choose a board or a vault"} = HeaderLinks.resolve(user, "")
      assert {:error, _} = HeaderLinks.resolve(user, "card", "1")
    end
  end
end
