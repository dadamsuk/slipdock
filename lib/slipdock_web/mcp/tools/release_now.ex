defmodule SlipdockWeb.MCP.Tools.ReleaseNow do
  @moduledoc """
  *Release now* over MCP (#2835): asks for a release of a batched board's
  merged work, with `check` only says where its releases stand, and with
  `lift_hold` lifts the hold a red release left (#2838), asking for no
  release. Asking and lifting are the board owner's.
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
      "Batched board: release its merged cards now (started, queued or joined; " <>
        "refused while a red release holds releases). check: only read the status. " <>
        "lift_hold: lift the hold, releasing nothing."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        check: %{
          type: "boolean",
          description: "Only read the release status; ask for nothing (default false)."
        },
        lift_hold: %{
          type: "boolean",
          description: "Lift the hold a red release left; asks for no release (default false)."
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
         {:ok, lift} <- Args.boolean(args, "lift_hold", false),
         need = if(check and not lift, do: :read, else: :owner),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, need)),
         {:ok, _root} <- Args.refusal(SlipdockWeb.API.ReleaseController.root(auth, board)) do
      cond do
        lift -> lift(board, auth)
        check -> {:ok, status(board)}
        true -> release(board, auth)
      end
    end
  end

  defp lift(board, auth) do
    by = Slipdock.Verified.who(Slipdock.Actor.from_conn(auth))

    case Releases.lift_hold(board, by) do
      {:ok, hold} ->
        {:ok,
         Map.merge(status(board), %{
           lifted: V.release_hold(hold),
           line: "Release hold lifted. Nothing was released."
         })}

      {:error, reason} ->
        {:error, Releases.refusal(reason)}
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
