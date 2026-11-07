defmodule SlipdockWeb.API.LedgerController do
  @moduledoc """
  The ledger over HTTP (#1948, see `Slipdock.Ledger`): what shipped on a
  board and the boards beneath it since a time.

    * `GET /api/boards/:board/ledger?since=` – `since` a number of days, a
      date (`2026-11-01`) or an ISO 8601 time; without it, since 07:00
      yesterday in the board's timezone. Read access. A `since` it can't
      read is a 422.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Ledger
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.LedgerJSON

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, ledger} <- read(board, params["since"]) do
      json(conn, LedgerJSON.ledger(board, ledger))
    end
  end

  defp read(board, since) do
    case Ledger.since(board, since: since) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end
end
