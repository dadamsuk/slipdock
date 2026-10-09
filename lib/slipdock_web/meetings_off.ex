defmodule SlipdockWeb.MeetingsOff do
  @moduledoc """
  Raised by a meeting page while meeting mode is off (see
  `Slipdock.Meetings`). A 404, the same as a page that does not exist: with
  the mode off there is nothing of meeting capture on this server to find.
  """
  defexception message: "meeting mode is off on this server", plug_status: 404
end
