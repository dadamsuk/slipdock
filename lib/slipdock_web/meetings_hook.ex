defmodule SlipdockWeb.MeetingsHook do
  @moduledoc """
  The gate in front of every meeting page and API route: while meeting mode
  is off (see `Slipdock.Meetings`) they are not there at all.

  As an `on_mount` hook it raises `SlipdockWeb.MeetingsOff`, a 404. As a plug
  (the `:meetings` API pipeline) it answers 404 with the same sentence the
  CLI and MCP print, so whoever asked learns why rather than guessing at a
  typo in the path.

  Chat capture (#1075) has a switch of its own. The pages a capture is
  reviewed on (`:require_capture`) and the API are there while *either* is
  on; a capture whose own kind is off is a 404 all the same. Sending a
  meeting and the board's Meetings list stay meeting mode's
  (`:require_enabled`).

  Meeting mode is also per person (#1206): somebody an admin has not let use
  meetings meets these gates as though it were off, and the API tells them
  so (`Slipdock.Meetings.off_message/1`).
  """
  import Plug.Conn

  alias Slipdock.Meetings

  def on_mount(:require_enabled, _params, _session, socket) do
    if Meetings.enabled_for?(socket.assigns[:current_user]),
      do: {:cont, socket},
      else: raise(SlipdockWeb.MeetingsOff)
  end

  def on_mount(:require_capture, params, _session, socket) do
    user = socket.assigns[:current_user]

    with true <- Meetings.capture_enabled_for?(user),
         true <- kind_on?(params["capture_id"], user) do
      {:cont, socket}
    else
      _ -> raise(SlipdockWeb.MeetingsOff)
    end
  end

  # The capture in the route, when there is one, must be of a kind that is on.
  defp kind_on?(nil, _user), do: true

  defp kind_on?(id, user) do
    case SlipdockWeb.Params.id(id) && Meetings.get_capture(SlipdockWeb.Params.id(id)) do
      %Meetings.Capture{} = capture -> Meetings.kind_enabled_for?(capture, user)
      # Not there: the page says so itself.
      _ -> true
    end
  end

  def init(opts), do: opts

  # `:meetings_only` (voiceprints) needs meeting mode itself; anything else,
  # either switch.
  def call(conn, opts) do
    user = conn.assigns[:current_user]

    on? =
      if opts == :meetings_only,
        do: Meetings.enabled_for?(user),
        else: Meetings.capture_enabled_for?(user)

    if on? do
      conn
    else
      conn
      |> put_status(:not_found)
      |> Phoenix.Controller.json(%{
        error: Meetings.off_message(user),
        code: Meetings.off_code(user)
      })
      |> halt()
    end
  end
end
