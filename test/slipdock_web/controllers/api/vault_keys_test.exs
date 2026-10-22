defmodule SlipdockWeb.API.VaultKeysTest do
  @moduledoc """
  A vault's switcher key and Ctrl+Shift digit over HTTP (#1204):
  `PATCH /api/vaults/:id {"shortcut", "hotkey"}`, shown on the vault and in
  `GET /api/hotkeys`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Hotkeys, Vaults}

  setup %{conn: conn, user: user} do
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain #{plan.id}"})
    %{conn: put_req_header(conn, "accept", "application/json"), plan: plan, vault: vault}
  end

  test "a vault shows its key, and its hotkey once given one", %{conn: conn, vault: vault} do
    assert %{"vault" => %{"shortcut" => key, "hotkey" => nil}} =
             conn |> get(~p"/api/vaults/#{vault.id}") |> json_response(200)

    assert key == vault.shortcut

    assert %{"vault" => %{"hotkey" => 4}} =
             conn |> patch(~p"/api/vaults/#{vault.id}", %{hotkey: "4"}) |> json_response(200)

    assert %{"hotkeys" => [entry]} = conn |> get(~p"/api/hotkeys") |> json_response(200)
    assert entry == %{"digit" => 4, "vault" => %{"id" => vault.id, "name" => vault.name}}
  end

  test "sets the key, and a blank one takes a fresh key", %{conn: conn, vault: vault} do
    key =
      Enum.find(
        for(a <- ?a..?z, b <- ?a..?z, do: <<a, b>>),
        &(not Slipdock.Boards.shortcut_taken?(&1))
      )

    assert %{"vault" => %{"shortcut" => ^key}} =
             conn |> patch(~p"/api/vaults/#{vault.id}", %{shortcut: key}) |> json_response(200)

    assert %{"vault" => %{"shortcut" => fresh}} =
             conn |> patch(~p"/api/vaults/#{vault.id}", %{shortcut: ""}) |> json_response(200)

    assert is_binary(fresh) and fresh != ""
  end

  test "a board's key is refused", %{conn: conn, plan: plan, vault: vault} do
    assert %{"error" => error} =
             conn
             |> patch(~p"/api/vaults/#{vault.id}", %{shortcut: plan.shortcut})
             |> json_response(422)

    assert error =~ "shortcut is already used by a board"
  end

  test "a bad digit is refused before anything is saved", ctx do
    %{conn: conn, user: user, vault: vault} = ctx

    assert %{"error" => error} =
             conn
             |> patch(~p"/api/vaults/#{vault.id}", %{hotkey: "12", name: "Renamed #{vault.id}"})
             |> json_response(422)

    assert error =~ "hotkey must be a single digit"
    assert {:ok, %{name: name}} = Vaults.get_vault(user, vault.id)
    assert name == vault.name
    assert Hotkeys.get(user, vault) == nil
  end

  test "none takes the digit away", %{conn: conn, user: user, vault: vault} do
    {:ok, 6} = Hotkeys.put(user, vault, 6)

    assert %{"vault" => %{"hotkey" => nil}} =
             conn |> patch(~p"/api/vaults/#{vault.id}", %{hotkey: "none"}) |> json_response(200)
  end
end
