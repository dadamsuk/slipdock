defmodule Slipdock.Verified.Outcome do
  @moduledoc """
  What every decision on a card leaves behind: its comment with the verdict
  in parts, the board's done list, and a card sent back to the top of the
  ready list for rework.
  """

  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Actors, Util}

  # Back to the top of the ready list for rework (#1659), after a rejection
  # or a failed merge (#1657): the handoff points at the reason, the
  # builder's own assignment comes off and the board's feed runs.
  @doc false
  def send_back(card, next_step, actor, user) do
    # The reason is on the comment and the verification block (and in a
    # claimed job's prompt and get_card): the handoff only points there.
    Slipdock.Boards.Handoffs.leave_handoff(card, user, %{
      next_step: next_step,
      via: Actors.handoff_via(actor)
    })

    # The builder's own assignment comes off (a person's stays), so a rule
    # that sends only unassigned cards sends it again.
    card = unassign_agents(Repo.get!(Card, card.id), actor, user)

    # Back to the top of the ready list, to be taken up again.
    columns = card |> Util.board() |> Repo.preload(:columns) |> Map.get(:columns)

    case Slipdock.Flow.ready_list(columns) do
      %Column{id: id} = ready when id != card.column_id ->
        Slipdock.Boards.Cards.move_card_to_index(card, ready, :top, actor: actor)

      _ ->
        :ok
    end

    # A rejection is new information: the card isn't cooling, so the
    # board's feed can send it next.
    Slipdock.Automations.feed_board(card.board_id)

    {:ok, Repo.get!(Card, card.id)}
  end

  defp unassign_agents(%Card{agent_assignee_ids: [_ | _] = ids} = card, actor, user) do
    on = Slipdock.Boards.Cards.assignee_ids(card)

    case Enum.filter(ids, &Enum.member?(on, &1)) do
      [] ->
        card

      gone ->
        case Slipdock.Boards.Cards.update_card(card, %{"remove_assignee_ids" => gone},
               actor: actor,
               by: user
             ) do
          {:ok, card} -> card
          _ -> card
        end
    end
  end

  defp unassign_agents(card, _actor, _user), do: card

  @doc false
  def api_error({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}
  def api_error(other), do: other

  # The decision's comment keeps its verdict in parts (#1778), so a later
  # decision replacing `verify_checks` loses nothing.
  @doc false
  def with_parts(note, nil), do: note
  def with_parts(note, %{"from_reason" => true}), do: note

  def with_parts(note, checks) do
    parts = Slipdock.Verified.Checks.markdown(checks)

    [note, "Checks:\n\n" <> parts]
    |> Enum.reject(&Enum.member?([nil, ""], &1))
    |> Enum.join("\n\n")
  end

  @doc false
  def comment(card, line, note, user) do
    body = if Enum.member?([nil, ""], note), do: line, else: "#{line}\n\n#{note}"
    Slipdock.Boards.Comments.add_comment(card, body, by: user)
  end

  @doc false
  def done_list(columns) do
    columns |> Enum.sort_by(& &1.position) |> Enum.find(&Column.done?/1)
  end
end
