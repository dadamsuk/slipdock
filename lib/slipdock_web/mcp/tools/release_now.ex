defmodule SlipdockWeb.MCP.Tools.ReleaseNow do
  @moduledoc """
  *Release now* over MCP (#2835): asks for a release of a batched board's
  merged work, or with `check` only says where its releases stand. Asking
  is the board owner's.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Releases
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "release_now"

  @impl true
  def title, do: "Release a batched board's merged work"

  @impl true
  def description,
    do:
      "On a board with batched releases, asks for a release of its merged cards now: " <>
        "started, queued behind the one running, or joined. check = true only reads " <>
        "where its releases stand."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        check: %{
          type: "boolean",
          description: "Only read the release status; ask for nothing (default false)."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, check} <- Args.boolean(args, "check", false),
         need = if(check, do: :read, else: :owner),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, need)) do
      if check, do: {:ok, status(board)}, else: release(board, auth)
    end
  end

  defp status(board), do: %{release: V.release_status(Releases.status(board))}

  defp release(board, auth) do
    by = Slipdock.Verified.who(Slipdock.Actor.from_conn(auth))

    case Releases.release_now(board, by) do
      {:ok, how, request} ->
        {:ok,
         Map.merge(status(board), %{
           how: how,
           line: Releases.said(how),
           request: V.release_request(request)
         })}

      {:error, reason} ->
        {:error, Releases.refusal(reason)}
    end
  end
end
