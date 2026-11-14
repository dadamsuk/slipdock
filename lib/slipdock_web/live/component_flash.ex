defmodule SlipdockWeb.ComponentFlash do
  @moduledoc """
  A flash from a LiveComponent. A component's own `put_flash/3` only reaches
  the page when it also redirects, and the layout that draws a flash is the
  page's, so a component hands its flash to the LiveView it runs in:
  `{:put_flash, kind, message}`, which the page answers with `put_flash/3`.

  One helper and one message shape for every component (#2895): the board's
  (through `SlipdockWeb.BoardLive.Helpers.flash/3`) and the account's
  sections alike. A panel or a modal never uses it for what an action says:
  that is `BoardLive.Helpers.notice/3` (UX-29).
  """

  @doc "Sends the flash up to the LiveView this component runs in; returns the socket."
  def flash(socket, kind, message) do
    send(self(), {:put_flash, kind, message})
    socket
  end
end
