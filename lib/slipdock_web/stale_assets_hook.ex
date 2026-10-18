defmodule SlipdockWeb.StaleAssetsHook do
  @moduledoc """
  Tells a tab that was opened before a deploy that it is out of date.

  A tab keeps the stylesheet and script it first loaded. After a deploy the
  socket reconnects to the new server, which sends new HTML to the old CSS
  and JS: a card's Markdown description came out as unstyled lines, and the
  editor lost its live preview, until a reload. The layout marks its assets
  `phx-track-static`, so the browser reports which digests it is running on
  every connect; when they are not the server's, this puts a `:stale_assets`
  flash up, which `SlipdockWeb.Layouts.flash_group/1` shows as a bar with a
  Reload link.

  The bar is a flash rather than a push to the browser because the tab that
  needs it is running the old JavaScript, which knows nothing of new events.
  For the same reason it is styled with classes the app already had.

  Without a static manifest (dev, test) nothing is ever stale.
  """

  import Phoenix.LiveView

  @message "Slipdock has been updated. Reload to get the new version."

  @doc "What the bar says."
  def message, do: @message

  def on_mount(:default, _params, _session, socket) do
    # `static_changed?/1` is only for the root LiveView, and only once it
    # is connected: the dead render is the new HTML with the new assets.
    if connected?(socket) and is_nil(socket.parent_pid) and static_changed?(socket),
      do: {:cont, put_flash(socket, :stale_assets, @message)},
      else: {:cont, socket}
  end
end
