defmodule SlipdockWeb.VaultUrls do
  @moduledoc """
  The wiki's addresses (W-2201): `/wiki/Projects/Roadmap`, the path of the
  file on disk without its `.md` (see `Slipdock.Vaults.addresses/1`), each
  segment escaped on its own. A person has one wiki, so no address names it.
  """

  alias Slipdock.Vaults.Vault

  @doc "The wiki: its top, or what is at `path` in it."
  def url(%Vault{}, path \\ "") do
    base = "/wiki"

    case String.trim(to_string(path), "/") do
      "" -> base
      path -> base <> "/" <> (path |> String.split("/") |> Enum.map_join("/", &escape/1))
    end
  end

  @doc "The wiki's settings: its keys, recordings folder and synced folders."
  def settings(%Vault{}), do: "/wiki/.settings"

  defp escape(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
