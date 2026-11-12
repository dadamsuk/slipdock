defmodule SlipdockWeb.MCP.Tools.Garden do
  @moduledoc """
  The board gardener's open suggestions, as `GET /api/boards/:board/garden`
  gives them; `run: true` looks the board over first, as `POST` does, which
  needs write access (W-1807).

  So the tool as a whole is not read-only, and `tools/list` says so: a client
  that trusted a `readOnlyHint` would run the gardener, which records a run
  and files suggestions, without asking (#1868). A listing changes nothing,
  though, so a read-only token may still make one (`writes?/1`).
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias Slipdock.Gardener
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.GardenJSON, as: G
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "garden"

  @impl true
  def title, do: "Tidy-up suggestions for a board"

  @impl true
  def description,
    do:
      "The gardener's open tidy-up suggestions (done epics, stale cards, duplicates, " <>
        "orphaned pages, broken [[links]]) with why and steps. findings: true is what the " <>
        "findings leave a person. run: true looks again first (a write). Then garden_decide."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        run: %{
          type: "boolean",
          description: "Look the board over now, before listing (needs write access)."
        },
        check: %{
          type: "string",
          enum: Gardener.suggestion_keys(),
          description: "Only this check's suggestions (and only this check, with run)."
        },
        findings: %{
          type: "boolean",
          description:
            "Only the open proposals drafted from findings, read from the tree's root " <>
              "board: what the Findings page, its tile and slipdock findings lead with (#2123)."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def writes?(args), do: Args.boolean(args, "run", false) == {:ok, true}

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, run} <- Args.boolean(args, "run", false),
         {:ok, check} <- check(args["check"]),
         {:ok, findings?} <- Args.boolean(args, "findings", false),
         {:ok, board} <-
           Args.refusal(Authorize.fetch_board(auth, ref, if(run, do: :write, else: :read))),
         :ok <- maybe_run(run, board, context.user, check),
         {:ok, suggestions} <- listed(auth, board, findings?, check) do
      {:ok,
       %{
         board_id: board.id,
         suggestions: G.suggestions(suggestions),
         last_run: G.run(Gardener.last_run(board)),
         checks: G.checks(Boards.get_board_record!(board.id)),
         note:
           if(suggestions == [],
             do: "Nothing to tidy.",
             else:
               "Show these to the person and apply only what they approve, with garden_decide. " <>
                 "A suggestion with needs_keep wants keep: the card that stays."
           )
       }}
    end
  end

  defp maybe_run(false, _board, _user, _check), do: :ok

  defp maybe_run(true, board, user, check) do
    {:ok, _} = Gardener.run(board, trigger: "mcp", user: user, only: check && [check])
    :ok
  end

  # What it lists: the board's open suggestions (of one check), or with
  # `findings` the proposals drafted from findings on the tree's root, as
  # `GET /api/boards/:board/findings` gives them in `awaiting`.
  defp listed(_auth, board, false, check), do: {:ok, Gardener.list_open(board, check: check)}

  defp listed(auth, board, true, _check) do
    root = Boards.root_board(board)

    with {:ok, _} <- Args.refusal(Authorize.board(auth, root, :read) |> ok_board(root)),
         do: {:ok, Slipdock.Findings.Awaiting.proposals(root)}
  end

  defp ok_board(:ok, board), do: {:ok, board}
  defp ok_board(refused, _board), do: refused

  defp check(nil), do: {:ok, nil}

  defp check(key) do
    if Enum.member?(Gardener.suggestion_keys(), key),
      do: {:ok, key},
      else:
        {:error,
         "unknown check #{inspect(key)}: one of #{Enum.join(Gardener.suggestion_keys(), ", ")}"}
  end
end
