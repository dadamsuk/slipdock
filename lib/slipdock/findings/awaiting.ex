defmodule Slipdock.Findings.Awaiting do
  @moduledoc """
  What a board's findings leave for a person (#2123, W-2310 §Findings).

  Findings are handled by triage and the server: they are merged, promoted,
  dismissed, or drafted into a rule when they recur (`Slipdock.Findings.Promote`).
  The one thing a person must decide is a garden proposal drafted from them.
  It is an open `proposal` suggestion on the tree's root board whose subject
  names findings (Promote's, or the triage card's `slipdock garden propose`
  with `findings`). So the Agentic Building tile, the Findings page,
  `GET /api/boards/:board/findings` and `slipdock findings` lead with these,
  and the open findings are the reference below them.

  A finding such a proposal names is *waiting* (#2767): deciding it would
  close the proposal (`Slipdock.Findings.Promote.settled/2`), which is the
  person's call. So `Slipdock.Findings.list/2` leaves it out of `open`, the
  list triage works from, and lists it under `waiting` instead.
  """
  import Ecto.Query

  alias Slipdock.Boards.Board
  alias Slipdock.Gardener.Suggestion
  alias Slipdock.Repo

  @doc "The open proposals drafted from `board`'s tree's findings, oldest first."
  def proposals(%Board{} = board) do
    root = Board.root_id(board)

    from(s in Suggestion,
      where: s.board_id == ^root and s.check == "proposal" and s.state == "open",
      order_by: s.id
    )
    |> Repo.all()
    |> Enum.filter(&(findings(&1) != []))
  end

  @doc "How many there are."
  def count(%Board{} = board), do: board |> proposals() |> length()

  @doc """
  The findings waiting on a person, as `%{finding_id => proposal_id}`: each
  one an open proposal names, with the oldest proposal that names it.
  """
  def waiting(%Board{} = board) do
    board
    |> proposals()
    |> Enum.reverse()
    |> Enum.flat_map(fn s -> Enum.map(findings(s), &{&1, s.id}) end)
    |> Map.new()
  end

  @doc "The findings a proposal was drafted from."
  def findings(%Suggestion{subject: subject}),
    do: subject |> Map.get("findings") |> List.wrap() |> Enum.filter(&is_integer/1)
end
