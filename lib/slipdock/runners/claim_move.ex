defmodule Slipdock.Runners.ClaimMove do
  @moduledoc """
  A claimed card goes to its board's doing list on claim (#2633), not when
  the agent remembers to move it.

  When a runner claims a job a `list_top` rule queued, the server moves the
  card to the doing list of the board it sits on, the one the guide names
  (`Slipdock.Flow.doing_list?/1`: by category, else by name), as the runner
  (`Slipdock.Actor.runner/3`), so the board's own gates still apply: a board
  that asks for a bar before work starts, and lanes. It assigns nobody (the
  runner shows as the card's loop, #2027) and says so in the activity. A
  board with no doing list, a card already in it, and a move the board
  refuses all leave the card where it is, and the activity says why.

  The claimed prompt then names the list the card is in (`prompt_line/1`),
  so an agent that moves cards by hand uses the board's own name for it.
  """

  import Ecto.Query

  alias Slipdock.{Actor, Boards, Repo}
  alias Slipdock.Automations.{Rule, Spec}
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Runners.{Job, Runner}

  # Jobs that check or finish a card, or do no card's work: never moved.
  @not_building ~w(verify merge overseer probe)

  @doc """
  The doing list of the board `board_id`, the first in list order the
  guide reads as one, or nil when it has none.
  """
  def doing_list(board_id) do
    from(col in Column, where: col.board_id == ^board_id, order_by: [asc: col.position])
    |> Repo.all()
    |> Enum.find(&Slipdock.Flow.doing_list?/1)
  end

  @doc """
  Moves the card of `job`, just claimed by `runner`, to its board's doing
  list when the job is a `list_top` rule's build. Returns what happened:

    * `{:moved, list}` — moved to the top of `list`;
    * `{:already, list}` — already in its board's doing list;
    * `:no_doing_list` — its board has none, so it stays where it is;
    * `{:refused, message}` — the board refused the move (a bar it asks for,
      a lane), so it stays where it is;
    * `:skip` — not a `list_top` rule's build job, or the card is gone,
      archived or completed.
  """
  def move(%Job{} = job, %Runner{} = runner) do
    with true <- list_top_build?(job),
         %Card{archived_at: nil, completed: false} = card <-
           Repo.get(Card, job.card_id) |> Repo.preload(:column) do
      to_doing(
        card,
        doing_list(card.board_id),
        Actor.runner(runner.created_by_id, job.id, runner.name)
      )
    else
      _ -> :skip
    end
  end

  defp to_doing(_card, nil, _actor), do: :no_doing_list

  defp to_doing(%Card{column_id: id}, %Column{id: id} = list, _actor), do: {:already, list}

  defp to_doing(%Card{} = card, %Column{} = list, actor) do
    case Boards.Cards.move_card_to_index(card, list, :top, actor: actor) do
      :ok -> {:moved, list}
      {:error, _status, message} -> {:refused, message}
      {:error, reason} -> {:refused, to_string(reason)}
    end
  end

  @doc """
  The words the claim's activity line ends with, for what `move/2`
  answered: `" and moved the card to In Progress"`, or why it stayed.
  """
  def activity_suffix({:moved, %Column{name: name}}), do: " and moved the card to #{name}"
  def activity_suffix(:no_doing_list), do: "; its board has no doing list, so the card stays put"

  def activity_suffix({:refused, message}),
    do: "; the card stays put, since moving it to the doing list was refused: #{message}"

  def activity_suffix(_), do: ""

  @doc """
  The line the claimed prompt adds about where the card is: the list it is
  in, and the board's doing list when it isn't that one. Nil when the card
  or its list is gone.
  """
  def prompt_line(card_id) when is_integer(card_id) do
    case Repo.get(Card, card_id) |> Repo.preload(:column) do
      %Card{column: %Column{} = col} = card -> line(col, doing_list(card.board_id))
      _ -> nil
    end
  end

  def prompt_line(_card_id), do: nil

  defp line(%Column{id: id, name: name}, %Column{id: id}),
    do:
      "The card is in #{name}, its board's doing list, so there is no need to move it " <>
        "there. If you move it by hand, the list is called \"#{name}\"."

  defp line(%Column{name: name}, %Column{name: doing}),
    do:
      "The card is in #{name}. Its board's doing list is called \"#{doing}\": use that name " <>
        "if you move it there by hand."

  defp line(%Column{name: name}, nil),
    do: "The card is in #{name}. Its board has no doing list, so leave it where it is."

  # A job a `list_top` rule queued, of a kind that builds.
  defp list_top_build?(%Job{rule_id: rule_id, card_id: card_id, kind: kind})
       when is_integer(rule_id) and is_integer(card_id) and kind not in @not_building do
    case Repo.get(Rule, rule_id) do
      %Rule{spec: spec} -> Spec.trigger_type(spec) == "list_top"
      nil -> false
    end
  end

  defp list_top_build?(_job), do: false
end
