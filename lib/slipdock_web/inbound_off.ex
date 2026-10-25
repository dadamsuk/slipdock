defmodule SlipdockWeb.InboundOff do
  @moduledoc """
  Raised by the account's Email Log tab while inbound mail is off (see
  `Slipdock.Inbound.enabled?/0`). A 404, the same as a page that does not
  exist: with no mail coming in there is no log to show.
  """
  defexception message: "inbound email is off on this server", plug_status: 404
end
