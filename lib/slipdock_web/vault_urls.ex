defmodule SlipdockWeb.VaultUrls do
  @moduledoc """
  The vault view's addresses (#752): `/vaults/GMinds/Jobs/Interview Questions`,
  a vault's name and then the path of the file on disk without its `.md`
  (see `Slipdock.Vaults.addresses/1`), each segment escaped on its own.
  """

  alias Slipdock.Vaults.Vault

  @doc "The vault's view: its top, or what is at `path` in it."
  def url(%Vault{name: name}, path \\ "") do
    base = "/vaults/" <> escape(name)

    case String.trim(to_string(path), "/") do
      "" -> base
      path -> base <> "/" <> (path |> String.split("/") |> Enum.map_join("/", &escape/1))
    end
  end

  @doc "The vault's settings: its mappings, synced folders, name."
  def settings(%Vault{name: name}), do: "/vaults/" <> escape(name) <> "/.settings"

  defp escape(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
