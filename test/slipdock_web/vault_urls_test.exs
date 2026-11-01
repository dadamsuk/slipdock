defmodule SlipdockWeb.VaultUrlsTest do
  @moduledoc """
  The wiki's addresses (W-2201): `/wiki`, then the path, each segment escaped
  on its own. A person has one wiki, so no address names it.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Vaults.Vault
  alias SlipdockWeb.VaultUrls

  test "the wiki, a path in it, and its settings, whatever the vault row is called" do
    vault = %Vault{name: "My Notes"}
    assert VaultUrls.url(vault) == "/wiki"
    assert VaultUrls.url(vault, "/") == "/wiki"
    assert VaultUrls.url(vault, "Journal/Q&A: 2026?") == "/wiki/Journal/Q%26A%3A%202026%3F"
    assert VaultUrls.settings(vault) == "/wiki/.settings"
  end
end
