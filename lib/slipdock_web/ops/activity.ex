defmodule SlipdockWeb.Ops.Activity do
  @moduledoc """
  A board's activity log, defined once (#3188): newest first, `card` for
  one card's entries; or, with `view: "ledger"`, its ledger (#1948): what
  shipped on the board tree since a time (`Slipdock.Ledger`). REST has two
  routes for it, `GET /api/boards/:board/activity` and `GET
  /api/boards/:board/ledger`: the second is this definition with `view`
  settled `ledger` (`LedgerController.index/2`). The ledger is a view
  rather than an operation of its own: it is the board's history, read
  the same way, and a tool of its own would add to every count the docs
  quote (SPEC-3).

  Before it, REST's log answered `{activity}` and MCP's `{board,
  activity}`: now both answer `{board, activity}`. REST took any `limit`
  (a word was a crash), MCP at most 200: now both take 1 to 200, more is
  200, and a word or 0 is a 400. REST read a `card` that wasn't a number
  as no card (the whole board's log): now it is a 400 on both.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.{Boards, Ledger}
  alias SlipdockWeb.API.{Authorize, LedgerJSON}
  alias SlipdockWeb.API.JSON, as: V

  @impl true
  def definition do
    %{
      name: "activity",
      title: "Board activity",
      summary:
        "A board's activity log, newest first; card = only that card's. " <>
          "view=ledger: what shipped since (days, a date or a time; 07:00 yesterday by default), " <>
          "with who accepted it and its evidence.",
      verb: :get,
      path: "/api/boards/:board/activity",
      permission: {:board, :read},
      writes?: false,
      params: [
        %{
          name: "board",
          type: :string,
          required: true,
          in_path: "board",
          doc: "Board id, code or name."
        },
        %{name: "card", type: :integer, doc: "Only the entries about this card."},
        %{
          name: "limit",
          type: :integer,
          default: 30,
          max: 200,
          doc: "At most this many (default 30, max 200)."
        },
        %{
          name: "view",
          type: {:enum, ["log", "ledger"]},
          default: "log",
          doc: "log (default), or ledger: what shipped on the board tree since `since`."
        },
        %{
          name: "since",
          type: :string,
          doc:
            "For view=ledger: days, a date or an ISO time (default 07:00 yesterday, board time)."
        }
      ],
      cli: %{
        command: "activity",
        positional: ["board"],
        flags: %{
          "limit" => %{param: "limit"},
          "card" => %{param: "card"},
          "view" => %{param: "view"},
          "since" => %{param: "since"}
        }
      }
    }
  end

  @impl true
  def run(%{"board" => ref, "view" => "ledger"} = params, auth) do
    with {:ok, board} <- Authorize.fetch_board(auth, ref, :read),
         {:ok, ledger} <- ledger(board, params["since"]) do
      {:ok, LedgerJSON.ledger(board, ledger)}
    end
  end

  def run(%{"board" => ref, "limit" => limit} = params, auth) do
    with {:ok, board} <- Authorize.fetch_board(auth, ref, :read) do
      {:ok,
       %{
         board: %{id: board.id, code: board.code, name: board.name},
         activity:
           board.id
           |> Boards.ActivityLog.list_activities(limit, params["card"])
           |> Enum.map(&V.activity/1)
       }}
    end
  end

  defp ledger(board, since) do
    case Ledger.since(board, since: since) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end
end
