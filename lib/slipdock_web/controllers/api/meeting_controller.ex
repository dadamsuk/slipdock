defmodule SlipdockWeb.API.MeetingController do
  @moduledoc """
  Meeting capture over the JSON API (see `Slipdock.Meetings`). Every route is
  behind the `:meetings` pipeline, so none of them exists while meeting mode
  is off.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Meetings

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Whether meeting mode is on, and how it shows: what a client asks first."
  def mode(conn, _params) do
    json(conn, %{meetings: Meetings.mode(conn.assigns.current_user)})
  end
end
