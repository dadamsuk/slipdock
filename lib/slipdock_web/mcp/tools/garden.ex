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

  alias Slipdock.Boards.Board
  alias Slipdock.Gardener
  alias Slipdock.Repo
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
      "The board gardener's open tidy-up suggestions (epics done but open, stuck or " <>
        "stale cards, likely duplicates, orphaned pages, broken [[links]]), each with " <>
        "why and its steps. run: true looks again first (a write). Show the person, then " <>
        "garden_decide."

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
         {:ok, board} <-
           Args.refusal(Authorize.fetch_board(auth, ref, if(run, do: :write, else: :read))) do
      if run,
        do:
          {:ok, _} =
            Gardener.run(board, trigger: "mcp", user: context.user, only: check && [check])

      suggestions = Gardener.list_open(board, check: check)

      {:ok,
       %{
         board_id: board.id,
         suggestions: G.suggestions(suggestions),
         last_run: G.run(Gardener.last_run(board)),
         checks: G.checks(Repo.get!(Board, board.id)),
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

  defp check(nil), do: {:ok, nil}

  defp check(key) do
    if Enum.member?(Gardener.suggestion_keys(), key),
      do: {:ok, key},
      else:
        {:error,
         "unknown check #{inspect(key)}: one of #{Enum.join(Gardener.suggestion_keys(), ", ")}"}
  end
end
