defmodule Slipdock.VaultSwitchingTest do
  @moduledoc """
  Vaults reached the way boards are (#1204): a switcher key from the boards'
  own set, and a Ctrl+Shift digit from the same ten.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Hotkeys, Repo, Vaults}
  alias Slipdock.Vaults.Vault

  setup do
    user = user_fixture()
    plan = board_fixture(%{"name" => "Plan"}, owner: user)

    {:ok, vault} =
      Vaults.create_vault(user, %{"name" => "Notes #{System.unique_integer([:positive])}"})

    %{user: user, plan: plan, vault: vault}
  end

  describe "the switcher key" do
    test "a new vault gets one, never a board's", %{vault: vault} do
      assert is_binary(vault.shortcut) and vault.shortcut != ""
      refute Repo.exists?(from(b in Slipdock.Boards.Board, where: b.shortcut == ^vault.shortcut))
    end

    test "set_shortcut gives the key asked for, cleaned up", %{vault: vault} do
      key = free_key()
      assert {:ok, %Vault{shortcut: ^key}} = Vaults.set_shortcut(vault, String.upcase(key))
    end

    test "blank takes a fresh key from the name", %{vault: vault} do
      assert {:ok, %Vault{shortcut: key}} = Vaults.set_shortcut(vault, "")
      assert key != ""
      refute Boards.shortcut_taken?(key, {:vault, vault.id})
    end

    test "a board's key is refused, and the vault keeps its own", %{vault: vault, plan: plan} do
      assert {:error, cs} = Vaults.set_shortcut(vault, plan.shortcut)
      assert {"is already used by a board", _} = cs.errors[:shortcut]
      assert Repo.get!(Vault, vault.id).shortcut == vault.shortcut
    end

    test "another vault's key is refused", %{user: user, vault: vault} do
      {:ok, other} = Vaults.create_vault(user, %{"name" => "Other #{vault.id}"})
      assert {:error, cs} = Vaults.set_shortcut(other, vault.shortcut)
      assert cs.errors[:shortcut]
    end

    test "a vault re-saving its own key keeps it", %{vault: vault} do
      assert {:ok, %Vault{shortcut: key}} = Vaults.set_shortcut(vault, vault.shortcut)
      assert key == vault.shortcut
    end

    test "a board cannot take a vault's key", %{plan: plan, vault: vault} do
      assert {:error, cs} = Boards.update_board(plan, %{"shortcut" => vault.shortcut})
      assert {"is already used by a vault", _} = cs.errors[:shortcut]
    end

    test "a new board's key steps round a vault's", %{user: user, vault: vault} do
      {:ok, vault} = Vaults.set_shortcut(vault, free_key())
      board = board_fixture(%{"name" => vault.shortcut}, owner: user)
      assert board.shortcut != vault.shortcut
    end

    test "switchable lists only your vaults, giving a key to one made before keys", %{
      user: user,
      vault: vault
    } do
      Repo.update_all(from(v in Vault, where: v.id == ^vault.id), set: [shortcut: nil])

      {:ok, theirs} =
        Vaults.create_vault(user_fixture("other@example.com"), %{"name" => "Theirs #{vault.id}"})

      listed = Vaults.switchable(user)
      assert [%Vault{id: id, shortcut: key}] = listed
      assert id == vault.id and is_binary(key)
      assert Repo.get!(Vault, vault.id).shortcut == key
      refute Enum.any?(listed, &(&1.id == theirs.id))
    end

    test "switchable is empty without a user" do
      assert Vaults.switchable(nil) == []
    end
  end

  describe "hotkeys on a vault" do
    test "a vault takes a digit, which then opens it", %{user: user, vault: vault} do
      assert {:ok, 2} = Hotkeys.put(user, vault, "2")
      assert Hotkeys.get(user, vault) == 2
      assert %Vault{id: id} = Hotkeys.target(user, 2)
      assert id == vault.id
      assert [{2, %Vault{}}] = Hotkeys.list(user)
      assert Hotkeys.boards(user) == []
    end

    test "a digit moves between a board and a vault", %{user: user, plan: plan, vault: vault} do
      {:ok, 1} = Hotkeys.put(user, plan, 1)
      {:ok, 1} = Hotkeys.put(user, vault, 1)
      assert Hotkeys.get(user, plan) == nil
      assert %Vault{} = Hotkeys.target(user, 1)

      {:ok, 1} = Hotkeys.put(user, plan, 1)
      assert Hotkeys.get(user, vault) == nil
      assert Hotkeys.target(user, 1).id == plan.id
    end

    test "choices tells a board from a vault with the same id" do
      # Ids come from different tables, so the two can be equal.
      hotkeys = [{3, %Slipdock.Boards.Board{id: 9, name: "Same"}}]

      assert {"Ctrl+Shift+3 (now Same)", "3"} in Hotkeys.choices(hotkeys, %Vault{id: 9})
      assert {"Ctrl+Shift+3", "3"} in Hotkeys.choices(hotkeys, %Slipdock.Boards.Board{id: 9})
    end

    test "only the owner can give their vault a digit", %{vault: vault} do
      stranger = user_fixture("stranger@example.com")
      assert {:error, "vault not found"} = Hotkeys.put(stranger, vault, 1)
      assert Hotkeys.list(stranger) == []
    end

    test "none takes it away, and deleting the vault takes the digit with it", %{
      user: user,
      vault: vault
    } do
      {:ok, 5} = Hotkeys.put(user, vault, 5)
      assert {:ok, nil} = Hotkeys.put(user, vault, "none")
      assert Hotkeys.target(user, 5) == nil

      {:ok, 5} = Hotkeys.put(user, vault, 5)
      {:ok, _} = Vaults.delete_vault(vault)
      assert Hotkeys.target(user, 5) == nil
      assert Hotkeys.list(user) == []
    end

    test "choices names the vault holding a digit on a board's form", %{
      user: user,
      plan: plan,
      vault: vault
    } do
      {:ok, 6} = Hotkeys.put(user, vault, 6)
      choices = Hotkeys.choices(Hotkeys.list(user), plan)
      assert {"Ctrl+Shift+6 (now #{vault.name})", "6"} in choices
      assert {"Ctrl+Shift+6", "6"} in Hotkeys.choices(Hotkeys.list(user), vault)
    end
  end

  # A key nothing has, from the two-character range so it does not collide
  # with the single letters other async tests' boards are given.
  defp free_key do
    Enum.find(for(a <- ?a..?z, b <- ?a..?z, do: <<a, b>>), &(not Boards.shortcut_taken?(&1)))
  end
end
