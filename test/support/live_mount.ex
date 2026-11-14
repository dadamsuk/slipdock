defmodule SlipdockWeb.LiveMount do
  @moduledoc """
  Mount a LiveView in a test, trying once more when the join is refused as
  stale (#3163, after #2828 and #2732).

  Under load the host's wall clock can step back by tens of milliseconds
  (WSL2 does; W-1950 §A runner machine). The LiveView's session token was
  signed a moment "later" than the join that checks it, plug_crypto reads it
  as signed in the future and refuses it, and `live/2` comes back as
  `{:error, {:redirect, %{to: <the same page>}}}`: a test that passes alone
  fails once in a few hundred runs (#2732, #2806, #2821, #2828, #2870).

  A test that only reads a page gets it over HTTP instead (W-1950 §Tests,
  #2639). One that drives the page mounts it with `mount_live/2`, which
  tries a refused join once more. A page that really sends itself to itself
  is refused again, and the caller's `{:ok, view, html}` match fails as it
  would have.
  """

  @doc """
  `Phoenix.LiveViewTest.live/2`, tried once more on a redirect to the same
  path. Needs `@endpoint`, as `live/2` does.
  """
  defmacro mount_live(conn, path) do
    quote do
      path = unquote(path)
      conn = unquote(conn)
      SlipdockWeb.LiveMount.retry_refused(path, fn -> Phoenix.LiveViewTest.live(conn, path) end)
    end
  end

  @doc """
  Calls `mount`, and once more if it answered with a redirect to `path`
  itself (query aside). Any other answer is returned as it came.
  """
  def retry_refused(path, mount) do
    case mount.() do
      {:error, {:redirect, %{to: to}}} = refused ->
        if same_path?(to, path), do: mount.(), else: refused

      mounted ->
        mounted
    end
  end

  defp same_path?(to, path), do: URI.parse(to).path == URI.parse(path).path
end
