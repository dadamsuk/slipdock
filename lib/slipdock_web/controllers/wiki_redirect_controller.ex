defmodule SlipdockWeb.WikiRedirectController do
  @moduledoc """
  An address from when a wiki was a named vault (`/vaults/Notes/Projects/Plan`,
  `/vaults/Notes/.settings`) to the same place in the person's one wiki
  (`/wiki/Projects/Plan`, `/wiki/.settings`), so old links and bookmarks
  still land (W-2201).
  """
  use SlipdockWeb, :controller

  def show(conn, params) do
    rest =
      case params["rest"] do
        [_vault | path] when path != [] -> "/" <> Enum.map_join(path, "/", &escape/1)
        _ -> ""
      end

    redirect(conn, to: "/wiki" <> rest <> query(conn))
  end

  defp escape(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp query(%Plug.Conn{query_string: ""}), do: ""
  defp query(%Plug.Conn{query_string: q}), do: "?" <> q
end
