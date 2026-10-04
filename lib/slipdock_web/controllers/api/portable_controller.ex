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

  require Logger

  alias Slipdock.{Access, Importers, Portable}
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
      opts = Portable.archived_opts(params["archived"]) ++ if(boards, do: [boards: boards], else: [])

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

    case Importers.import(conn.assigns.current_user, document(params), from: from, via: "api") do
      {:ok, report} ->
        json(conn, %{imported: report})

      # Over a limit: a 402 with the limit's own code, as everywhere else.
      {:error, {code, _, _} = reason} when code in [:card_limit_reached, :board_limit_reached] ->
        {:error, :payment_required, Atom.to_string(code), Importers.error_message(reason)}

      {:error, :trial_expired} ->
        {:error, :payment_required, "trial_expired", Importers.error_message(:trial_expired)}

      {:error, reason} ->
        case Importers.error_message(reason) do
          # Whatever this is, it is the server's own term, and not the client's
          # business: the log has it, the answer does not.
          nil ->
            Logger.warning("Import refused: #{inspect(reason)}")
            {:error, :unprocessable_entity, "couldn't import that"}

          message ->
            {:error, :unprocessable_entity, message}
        end
    end
  end

  ## Internals

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
      # Owner, not reader: see the moduledoc. And owner of the root, since
      # that is what gets exported: a sub-board can have an owner of its own.
      with {:ok, board} <- found(Access.find_board(conn.assigns.current_user, ref), ref),
           root = Portable.root_of(board),
           :ok <- Authorize.board(conn, root, :owner) do
        {:cont, {:ok, acc ++ [root]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp requested_boards(_conn, _refs),
    do: {:error, :unprocessable_entity, "boards is a comma-separated list"}

  defp found({:ok, board}, _ref), do: {:ok, board}
  defp found({:error, :not_found}, ref), do: {:error, :not_found, "no board “#{ref}”"}
end
