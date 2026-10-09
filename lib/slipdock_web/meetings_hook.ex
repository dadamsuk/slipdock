defmodule SlipdockWeb.MeetingsHook do
  @moduledoc """
  The gate in front of every meeting page and API route: while meeting mode
  is off (see `Slipdock.Meetings`) they are not there at all.

  As an `on_mount` hook it raises `SlipdockWeb.MeetingsOff`, a 404. As a plug
  (the `:meetings` API pipeline) it answers 404 with the same sentence the
  CLI and MCP print, so whoever asked learns why rather than guessing at a
  typo in the path.
  """
  import Plug.Conn

  alias Slipdock.Meetings

  def on_mount(:require_enabled, _params, _session, socket) do
    if Meetings.enabled?(), do: {:cont, socket}, else: raise(SlipdockWeb.MeetingsOff)
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    if Meetings.enabled?() do
      conn
    else
      conn
      |> put_status(:not_found)
      |> Phoenix.Controller.json(%{error: Meetings.off_message(), code: "meetings_off"})
      |> halt()
    end
  end
end
