defmodule SlipdockWeb.VaultUrlsTest do
  @moduledoc "The vault view's addresses (#752): each segment escaped on its own."
  use ExUnit.Case, async: true

  alias Slipdock.Vaults.Vault
  alias SlipdockWeb.VaultUrls

  test "a vault, a path in it, and its settings" do
    vault = %Vault{name: "My Notes"}
    assert VaultUrls.url(vault) == "/vaults/My%20Notes"
    assert VaultUrls.url(vault, "/") == "/vaults/My%20Notes"

    assert VaultUrls.url(vault, "Journal/Q&A: 2026?") ==
             "/vaults/My%20Notes/Journal/Q%26A%3A%202026%3F"

    assert VaultUrls.settings(vault) == "/vaults/My%20Notes/.settings"
  end
end
