defmodule Slipdock.Boards.CardEvents do
  @moduledoc """
  What a change to a card offers `Slipdock.Automations`: one event per field
  that changed, and the ones worth a trigger of their own (completing,
  reopening, assigning, flagging, a tag added). Rules change cards in turn, so
  this is re-entrant by design; the guard against rules chasing each other
  round in circles lives in `Slipdock.Automations`. A stand-in is not work, so
  nothing it does is an event.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Card
  alias Slipdock.Repo

  # Card fields a "card_updated" automation trigger can name.
  @automatable_fields ~w(title description priority start_date due_date percent_complete flags completed color
                         bar paths profile verify_state)a

  ## Automations

  # Every change this context makes is offered to `Slipdock.Automations`, which
  # runs the rules whose trigger matches. Rules change cards in turn, so this
  # is re-entrant by design; the guard against rules chasing each other round
  # in circles lives there.
  # A stand-in is not work, so nothing it does is an event a rule should see.
  @doc false
  def automate(%{card: %Card{stand_in_for_id: id}}) when not is_nil(id), do: :ok
  def automate(event), do: Slipdock.Automations.dispatch(event)

  # One update can be several events: the fields that changed, plus the ones
  # worth a trigger of their own (completing, reopening, assigning, flagging).
  @doc false
  def automate_card_changes(before, card, changeset, {was_assigned, now_assigned}) do
    changes = changeset.changes
    newly_assigned = now_assigned -- was_assigned
    fields = changed_fields(changes)

    fields =
      if Enum.sort(was_assigned) != Enum.sort(now_assigned) and
           not Enum.member?(fields, "assignee"),
         do: fields ++ ["assignee"],
         else: fields

    automate(%{type: "card_updated", card: card, fields: fields})

    case changes[:completed] do
      true ->
        # A card that got finished starts afresh with the runners.
        Slipdock.Runners.Recovery.forget(card)
        automate(%{type: "card_completed", card: card})

      false ->
        automate(%{type: "card_reopened", card: card})

      _ ->
        :ok
    end

    # Once for each person newly on the card, so a rule waiting for "assigned
    # to Sam" fires when Sam joins, whoever else is already there.
    for id <- newly_assigned, user = Repo.get(User, id) do
      automate(%{type: "card_assigned", card: card, assignee: user})
    end

    for flag <- List.wrap(changes[:flags]) -- before.flags do
      automate(%{type: "flag_added", card: card, flag: flag})
    end
  end

  # The names a rule's "card_updated" trigger uses for the fields.
  defp changed_fields(changes) do
    Enum.flat_map(changes, fn
      {:assignee_id, _} -> ["assignee"]
      {:column_id, _} -> ["column"]
      {field, _} when field in @automatable_fields -> [Atom.to_string(field)]
      _ -> []
    end)
  end

  @doc false
  def automate_tags_added(card, before, now) do
    previous = MapSet.new(before, & &1.id)

    for tag <- now, not MapSet.member?(previous, tag.id) do
      automate(%{type: "tag_added", card: card, tag: tag.name})
    end
  end
end
