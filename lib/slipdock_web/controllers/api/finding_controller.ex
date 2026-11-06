defmodule SlipdockWeb.API.FindingController do
  @moduledoc """
  Findings over HTTP (W-2310 §Findings, see `Slipdock.Findings`). They are
  kept on the root board of a tree, so both actions check the root.

    * `GET /api/boards/:board/findings?status=&kind=&source=&card=&since=&scope=` –
      the tree's findings, open by default (`status=all` for every one;
      `since` a date, an ISO 8601 time or a number of days; `scope` board by
      default, `runner` or `all`), each with the `cards` it was said on. Read
      access.
    * `PATCH /api/findings/:id {action: dismiss|promote|merge|reopen, note?, into?}`
      – triage one. Write access.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Boards.Board
  alias Slipdock.{Findings, Repo}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.FindingJSON, as: F

  action_fallback SlipdockWeb.API.FallbackController

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         root = root(board),
         :ok <- Authorize.board(conn, root, :read),
         {:ok, findings} <- refused(Findings.list(root, params)) do
      json(conn, %{board_id: root.id, findings: Enum.map(findings, &F.finding/1)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, finding} <- fetch(conn, id),
         :ok <- Authorize.board(conn, Repo.get!(Board, finding.board_id), :write),
         {:ok, _} <- refused(Findings.triage(finding, params["action"], params)) do
      json(conn, %{finding: F.finding(Findings.get(finding.id))})
    end
  end

  # A finding on a board the user can't read is a 404, like one that isn't there.
  defp fetch(conn, id) do
    with {n, ""} <- Integer.parse(to_string(id)),
         %{} = finding <- Findings.get(n),
         :ok <- Authorize.board(conn, Repo.get!(Board, finding.board_id), :read) do
      {:ok, finding}
    else
      {:error, :forbidden, _} -> {:error, :not_found, "finding"}
      _ -> {:error, :not_found, "finding"}
    end
  end

  defp root(%Board{root_id: nil} = board), do: board
  defp root(%Board{root_id: id}), do: Repo.get!(Board, id)

  defp refused({:ok, _} = ok), do: ok
  defp refused({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}
  defp refused({:error, message}), do: {:error, :unprocessable_entity, message}
end
