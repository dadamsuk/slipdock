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

  action_fallback SlipdockWeb.API.FallbackController

  @doc "`SlipdockWeb.Ops.Activity` with `view` settled `ledger` (#3188)."
  def index(conn, params),
    do:
      SlipdockWeb.Ops.REST.run(conn, SlipdockWeb.Ops.Activity, Map.put(params, "view", "ledger"))
end
