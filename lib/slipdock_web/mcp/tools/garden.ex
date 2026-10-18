defmodule SlipdockWeb.MCP.Tools.Garden do
  @moduledoc """
  The board gardener's open suggestions, as `GET /api/boards/:board/garden`
  gives them; `run: true` looks the board over first, as `POST` does, which
  needs write access (W-1807).
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
      "The board gardener's open tidy-up suggestions: epics done but still open, cards in Done " <>
        "never completed (or completed outside Done), cards stuck in progress, epics with no " <>
        "next step, long-overdue cards, abandoned backlog, likely duplicates, orphaned pages and " <>
        "mistyped [[links]]. Each has an explanation and the steps applying it would take. " <>
        "run: true looks the board over again first (needs write access). Nothing changes until " <>
        "a person approves a suggestion: show them, then garden_decide what they chose."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        run: %{type: "boolean", description: "Look the board over now, before listing."},
        check: %{
          type: "string",
          enum: Gardener.check_keys(),
          description: "Only this check's suggestions (and only this check, with run)."
        }
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

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
    if Gardener.check(key),
      do: {:ok, key},
      else:
        {:error,
         "unknown check #{inspect(key)}: one of #{Enum.join(Gardener.check_keys(), ", ")}"}
  end
end
