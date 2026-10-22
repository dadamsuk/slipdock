defmodule SlipdockWeb.VaultSwitchingLiveTest do
  @moduledoc """
  Vaults reached the way boards are (#1204): listed in the `b` switcher and
  the command palette, opened by a Ctrl+Shift digit, both keys set on the
  vault's settings and shown on its home-page tile.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Hotkeys, Repo, Vaults}
  alias SlipdockWeb.VaultUrls

  setup %{user: user} do
    plan = board_fixture(%{"name" => "Plan"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain #{plan.id}"})
    %{plan: plan, vault: vault}
  end

  test "the switcher lists your vault with its key, after your boards", ctx do
    %{conn: conn, plan: plan, vault: vault} = ctx
    {:ok, view, _} = live(conn, ~p"/boards/#{plan}")
    html = render_hook(view, "shortcut_panel", %{"panel" => "boards"})

    assert has_element?(
             view,
             ~s{#switch-vault-#{vault.id}[href="#{VaultUrls.url(vault)}"][data-shortcut="#{vault.shortcut}"]},
             vault.name
           )

    {board_at, _} = :binary.match(html, ~s(href="/boards/#{plan.id}"))
    {vault_at, _} = :binary.match(html, "switch-vault-#{vault.id}")
    assert board_at < vault_at
  end

  test "somebody else's vault is not in your switcher", %{conn: conn, plan: plan} do
    {:ok, theirs} = Vaults.create_vault(user_fixture("other@example.com"), %{"name" => "Theirs"})
    {:ok, view, _} = live(conn, ~p"/boards/#{plan}")
    render_hook(view, "shortcut_panel", %{"panel" => "boards"})
    refute has_element?(view, "#switch-vault-#{theirs.id}")
  end

  test "the command palette offers the vault", %{conn: conn, plan: plan, vault: vault} do
    {:ok, view, _} = live(conn, ~p"/boards/#{plan}")
    render_hook(view, "shortcut_panel", %{"panel" => "command"})
    html = render_hook(view, "palette_filter", %{"q" => vault.name})
    assert html =~ VaultUrls.url(vault)
  end

  test "Ctrl+Shift and the vault's digit opens the vault", ctx do
    %{conn: conn, user: user, plan: plan, vault: vault} = ctx
    {:ok, 3} = Hotkeys.put(user, vault, 3)
    {:ok, view, _} = live(conn, ~p"/boards/#{plan}")

    assert {:error, {:live_redirect, %{to: to}}} =
             render_hook(view, "board_hotkey", %{"digit" => "3"})

    assert to == VaultUrls.url(vault)
  end

  test "the home page shows a vault's keys on its tile", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, 8} = Hotkeys.put(user, vault, 8)
    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(view, "#vault-#{vault.id} kbd", vault.shortcut)
    assert has_element?(view, "#vault-hotkey-#{vault.id}", "Ctrl+Shift+8")
  end

  describe "vault settings" do
    test "saves a key and a digit, which then work", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      key = free_key()
      {:ok, view, _} = live(conn, VaultUrls.settings(vault))

      html =
        view
        |> form("#vault-keys-#{vault.id}", %{"shortcut" => key, "hotkey" => "5"})
        |> render_submit()

      assert html =~ "Press b then #{key} to open"
      assert html =~ "Ctrl+Shift+5"
      assert Repo.get!(Slipdock.Vaults.Vault, vault.id).shortcut == key
      assert Hotkeys.target(user, 5).id == vault.id
    end

    test "a board's key is refused and nothing is saved", ctx do
      %{conn: conn, user: user, plan: plan, vault: vault} = ctx
      {:ok, view, _} = live(conn, VaultUrls.settings(vault))

      html =
        view
        |> form("#vault-keys-#{vault.id}", %{"shortcut" => plan.shortcut, "hotkey" => "5"})
        |> render_submit()

      assert html =~ "Shortcut key is already used by a board"
      assert Repo.get!(Slipdock.Vaults.Vault, vault.id).shortcut == vault.shortcut
      assert Hotkeys.get(user, vault) == nil
    end

    test "names the board a digit would move from", ctx do
      %{conn: conn, user: user, plan: plan, vault: vault} = ctx
      {:ok, 2} = Hotkeys.put(user, plan, 2)
      {:ok, view, _} = live(conn, VaultUrls.settings(vault))
      assert has_element?(view, "#vault-hotkey-#{vault.id} option", "Ctrl+Shift+2 (now Plan)")
    end
  end

  defp free_key do
    Enum.find(
      for(a <- ?a..?z, b <- ?a..?z, do: <<a, b>>),
      &(not Slipdock.Boards.shortcut_taken?(&1))
    )
  end
end
