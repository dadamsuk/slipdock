defmodule SlipdockWeb.API.PortableController do
  @moduledoc """
  Board trees out as one JSON document and back in again — see
  `Slipdock.Portable` for the format and for what it deliberately leaves
  behind.

  Nothing here needs a scope of its own. The `:api` pipeline already refuses a
  non-GET from a read-only token, which is exactly the line that matters:
  reading your boards out is a read, and writing a document in is a write.

  An export only ever contains boards the caller **owns**, not every board they
  can see. A board shared with you is somebody else's to hand on, and an export
  that quietly included it would be a way to take a copy of their work off the
  server.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Boards, Importers, Portable}
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  @doc """
  `GET /api/export`.

  `boards` names the ones to take, comma-separated, by id, code or name; leave
  it out for every root board the caller owns. `archived=cards|pages|boards`
  (repeatable, comma-separated, or `all`) brings in what is otherwise left out.
  """
  def export(conn, params) do
    user = conn.assigns.current_user

    with {:ok, boards} <- requested_boards(conn, params["boards"]) do
      opts = archived_opts(params["archived"]) ++ if(boards, do: [boards: boards], else: [])

      json(conn, %{
        export: Portable.export(user, opts),
        leaving_behind: Portable.warnings(user, opts)
      })
    end
  end

  @doc """
  `POST /api/import`.

  The body is either the document itself — what `GET /api/export` returns under
  `export`, or a whole response with that key — or `{"export": {…}}`. It may
  also be another tool's export (a Trello board's JSON), which is recognised
  by its shape; `?from=trello` says so outright. The answer says what was
  built, which reader it went through, and what could not come.
  """
  def import(conn, params) do
    {from, params} = Map.pop(params, "from")

    case Importers.import(conn.assigns.current_user, document(params), from: from) do
      {:ok, report} ->
        json(conn, %{imported: report})

      {:error, :not_a_slipdock_export} ->
        {:error, :unprocessable_entity,
         "that is not a Slipdock export — it has no \"slipdock_portable\" version in it — " <>
           "nor a board export from #{sources()}"}

      {:error, {:unknown_source, from}} ->
        {:error, :unprocessable_entity,
         "this server can't import from “#{from}”; it reads #{Enum.join(Importers.keys(), ", ")}"}

      {:error, :not_a_trello_export} ->
        {:error, :unprocessable_entity,
         "that is not a Trello board export — it has no lists and cards in it"}

      {:error, {:unsupported_version, version}} ->
        {:error, :unprocessable_entity,
         "that document is format version #{version}; this server reads version " <>
           "#{Portable.format_version()}"}

      {:error, {:card_limit_reached, wanted, remaining}} ->
        {:error, :unprocessable_entity,
         "that document holds #{wanted} cards and pages and you have room for " <>
           "#{remaining}. Nothing was imported — a half-built board is worse than none."}

      {:error, {:board_limit_reached, wanted, remaining}} ->
        {:error, :unprocessable_entity,
         "that document holds #{wanted} boards and you have room for #{remaining}. " <>
           "Nothing was imported."}

      {:error, :trial_expired} ->
        {:error, :unprocessable_entity,
         "your free trial has ended, so nothing new can be added. Nothing was imported."}

      {:error, :not_json} ->
        {:error, :unprocessable_entity, "that is not JSON"}

      {:error, reason} ->
        {:error, :unprocessable_entity, "couldn't import that: #{inspect(reason)}"}
    end
  end

  ## Internals

  defp sources, do: Importers.sources() |> Enum.map(& &1.label()) |> Enum.join(" or ")

  # A document may arrive bare, or still wrapped in the response it came out
  # of — people pipe `GET /api/export` straight back in, and refusing that
  # would be pedantry.
  defp document(%{"export" => document}) when is_map(document), do: document
  defp document(params), do: Map.delete(params, "_json")

  defp requested_boards(_conn, nil), do: {:ok, nil}
  defp requested_boards(_conn, ""), do: {:ok, nil}

  defp requested_boards(conn, refs) when is_binary(refs) do
    refs
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      with {:ok, board} <- found(Boards.find_board(ref), ref),
           # Owner, not reader: see the moduledoc.
           :ok <- Authorize.board(conn, board, :owner) do
        {:cont, {:ok, acc ++ [board]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp requested_boards(_conn, _refs),
    do: {:error, :unprocessable_entity, "boards is a comma-separated list"}

  defp found({:ok, board}, _ref), do: {:ok, board}
  defp found({:error, :not_found}, ref), do: {:error, :not_found, "no board “#{ref}”"}

  defp archived_opts(nil), do: []

  defp archived_opts(value) when is_binary(value) do
    parts = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    all? = "all" in parts or "true" in parts

    [
      archived_cards: all? or "cards" in parts,
      archived_pages: all? or "pages" in parts,
      archived_boards: all? or "boards" in parts
    ]
  end

  defp archived_opts(_), do: []
end
