defmodule Slipdock.Boards.Handoffs do
  @moduledoc """
  Handoffs: where whoever had a card last left it, the one next step and a
  note, with the ones before it.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Handoff
  alias Slipdock.Repo

  ## Handoffs

  @doc """
  Leaves a handoff on `card`: where it was left, for whoever picks it up
  next (W-1804). `attrs` takes `next_step` (one line, required), `body`,
  `via` (`ui`, `api`, `mcp`, `cli` or `runner`) and `job_id`. It is a new
  row, never an edit: the newest is the handoff and the rest its history.

  Who may write is the caller's to check: anyone who may comment on the card.
  """
  def leave_handoff(%Card{} = card, user, attrs) do
    %Handoff{card_id: card.id, user_id: user && user.id}
    |> Handoff.changeset(attrs)
    |> insert_handoff(card, "left a handoff on “#{card.title}”: ")
  end

  @doc """
  Clears `card`'s handoff by writing an empty row, so the history shows it
  was cleared and by whom. `attrs` takes `via` and `job_id`.
  """
  def clear_handoff(%Card{} = card, user, attrs) do
    %Handoff{card_id: card.id, user_id: user && user.id}
    |> Handoff.clear_changeset(attrs)
    |> insert_handoff(card, "cleared the handoff on “#{card.title}”")
  end

  @doc """
  Deletes `card`'s current handoff outright (#1214): the row goes, history
  and all, so the one before it is the handoff again (or none, if there was
  none or it was a clear). Unlike `clear_handoff/3` nothing is kept, only a
  line in the activity log. `{:error, :none}` when the card has no handoff.

  Who may delete is the caller's to check: `may_delete_handoff?/3`.
  """
  def delete_handoff(%Card{} = card) do
    case current_handoff(card) do
      nil ->
        {:error, :none}

      handoff ->
        {:ok, _} = Repo.delete(handoff)

        Boards.ActivityLog.log(
          Repo,
          card.board_id,
          card.id,
          "handoff",
          "deleted the handoff on “#{card.title}”: " <> handoff.next_step
        )

        Boards.PubSub.broadcast(card.board_id)
        {:ok, handoff}
    end
  end

  @doc """
  Whether `user` may delete `handoff`: whoever can edit the card, or its
  author if they can still comment on it, as with a comment.
  """
  def may_delete_handoff?(%Handoff{} = handoff, user, can_write?) do
    can_write? or (not is_nil(user) and handoff.user_id == user.id)
  end

  defp insert_handoff(changeset, card, message) do
    changeset
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn h ->
      Boards.ActivityLog.log(
        Repo,
        card.board_id,
        card.id,
        "handoff",
        message <> (h.next_step || "")
      )

      Boards.PubSub.broadcast(card.board_id)
    end)
    |> case do
      {:ok, h} -> {:ok, Repo.preload(h, :user)}
      error -> error
    end
  end

  @doc "The card's handoff, with its author: its newest row, or nil if none or cleared."
  def current_handoff(%Card{id: id}), do: current_handoff(id)

  def current_handoff(card_id) when is_integer(card_id) do
    Map.get(current_handoffs([card_id]), card_id)
  end

  @doc """
  The handoff of each of `card_ids` that has one, by card id: what a board
  needs to mark its fronts without a query per card.
  """
  def current_handoffs([]), do: %{}

  def current_handoffs(card_ids) when is_list(card_ids) do
    newest =
      from(h in Handoff,
        where: h.card_id in ^card_ids,
        group_by: h.card_id,
        select: max(h.id)
      )

    from(h in Handoff, where: h.id in subquery(newest), preload: :user)
    |> Repo.all()
    |> Enum.reject(&Handoff.cleared?/1)
    |> Map.new(&{&1.card_id, &1})
  end

  @doc "Every handoff written on the card, clears included, newest first."
  def handoff_history(%Card{id: id}) do
    from(h in Handoff,
      where: h.card_id == ^id,
      order_by: [desc: h.id],
      preload: :user
    )
    |> Repo.all()
  end

  @doc """
  Whether anything was written as the card's handoff since `since`: a runner
  only writes its summary as one when the agent didn't (#1063).
  """
  def handoff_written_since?(card_id, %DateTime{} = since) do
    Repo.exists?(from(h in Handoff, where: h.card_id == ^card_id and h.inserted_at >= ^since))
  end
end
