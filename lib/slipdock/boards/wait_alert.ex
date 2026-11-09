defmodule Slipdock.Boards.WaitAlert do
  @moduledoc """
  The alert a person gets when a wait lands on them (#2095): in the header
  bar, beside the rules' alerts, and theirs alone (`Alert.user_id`). A card
  past its board's rejection limit asks its person through such a wait
  (`Slipdock.Verified`, purpose `verify_limit`), so it alerts the same way,
  titled for what it is.

  Who is told is `tell?/2`'s, which the wait's email shares
  (`Slipdock.Boards.WaitEmail`): the named person the wait is on, if they
  may read the card, unless they asked it themselves in person. An agent
  asking under their own token is still a question for them: that is how
  most questions reach a board's owner. Each person turns the alert off
  in account settings (`User.waiting_alerts`, on by default).

  The alert comes down by itself when the wait closes, by whatever route
  (`closed/1`, #2636): answered, skipped, withdrawn, its default standing,
  or its card completed or archived. A later wait on the card raises an
  alert of its own.
  """

  import Ecto.Query

  alias Slipdock.Access
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Alert, Dismissal}
  alias Slipdock.Boards.{Card, Wait}
  alias Slipdock.Repo

  @doc """
  Whether a wait's person is told about it: there is one, they may read
  the card, and they didn't open it themselves as a person.
  """
  def tell?(%Wait{on_user: %User{} = person} = wait, %Card{} = card) do
    not (person.id == wait.opened_by_id and wait.kind == "human") and
      person |> Access.card_permission(card) |> Access.can_read?()
  end

  def tell?(_wait, _card), do: false

  @doc "Raises the person's alert, when `tell?/2` and their switch say so."
  @spec opened(struct(), Card.t()) :: :ok
  def opened(%Wait{on_user: %User{waiting_alerts: true} = person} = wait, %Card{} = card) do
    if tell?(wait, card) do
      {:ok, _} =
        Slipdock.Automations.raise_alert(%{
          "title" => title(wait, card),
          "body" => wait.needs,
          "severity" => "warning",
          "board_id" => card.board_id,
          "card_id" => card.id,
          "user_id" => person.id
        })
    end

    :ok
  end

  def opened(_wait, _card), do: :ok

  @doc """
  Takes down the alerts a closed wait raised: each person's alert on its
  card (one addressed to them, not a rule's) is dismissed for them. A card
  has one open wait at most, so any such alert is this wait's, or one
  moved on from (`Boards.move_wait/3`).
  """
  @spec closed(struct()) :: :ok
  def closed(%Wait{card_id: card_id}) do
    from(a in Alert,
      left_join: d in Dismissal,
      on: d.alert_id == a.id and d.user_id == a.user_id,
      where: a.card_id == ^card_id and not is_nil(a.user_id) and is_nil(a.rule_id),
      where: is_nil(d.id),
      select: {a.id, a.user_id}
    )
    |> Repo.all()
    |> Enum.each(fn {id, user_id} ->
      Slipdock.Automations.dismiss_alert(%User{id: user_id}, id)
    end)
  end

  @doc "What the alert says: what kind of wait, and the card."
  def title(%Wait{purpose: "verify_limit"}, card),
    do: clip("Past the rejection limit: ##{card.id} “#{card.title}”")

  def title(_wait, card), do: clip("Waiting on you: ##{card.id} “#{card.title}”")

  defp clip(text) do
    if String.length(text) > 200, do: String.slice(text, 0, 199) <> "…", else: text
  end
end
