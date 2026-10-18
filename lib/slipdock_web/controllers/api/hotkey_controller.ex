defmodule SlipdockWeb.API.HotkeyController do
  @moduledoc """
  The signed-in user's board hotkeys (#1101): which board Ctrl+Shift+a digit
  opens (see `Slipdock.Hotkeys`).

  Hotkeys are personal, like favourites, so everything here is about the
  token's owner: setting one on a board shared with you takes nothing from
  its owner, and needs only to be able to read the board.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Hotkeys
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Every hotkey the user has, 1–9 then 0."
  def index(conn, _params) do
    json(conn, %{hotkeys: entries(conn.assigns.current_user)})
  end

  @doc """
  Gives a board a digit (`digit`: 0–9), or takes its digit away (`digit`:
  null, "" or "none"). The digit leaves whichever other board had it.
  """
  def update(conn, %{"board" => ref} = params) do
    user = conn.assigns.current_user

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, digit} <- put(user, board, params) do
      json(conn, %{board_id: board.id, digit: digit, hotkeys: entries(user)})
    end
  end

  defp put(user, board, %{"digit" => digit}) do
    case Hotkeys.put(user, board, digit) do
      {:ok, digit} -> {:ok, digit}
      {:error, message} -> {:error, :unprocessable_entity, "digit #{message}"}
    end
  end

  defp put(_user, _board, _params), do: {:error, :bad_request, "digit is required (0–9 or none)"}

  defp entries(user) do
    for {digit, board} <- Hotkeys.list(user) do
      %{digit: digit, board: %{id: board.id, name: board.name, code: board.code}}
    end
  end
end
