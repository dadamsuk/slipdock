defmodule Slipdock.Incidents do
  @moduledoc """
  Incidents (#1946): what broke after it shipped, and which check should have
  caught it. A card names the card whose shipping caused it (`caused_by`, any
  card the person can read) and the layer that missed it (`missed_by`, one of
  `Slipdock.Boards.Card.layers/0`). Both are set by a person, or an agent told
  to: nothing here is automatic, and there is no dashboard. At a small team's
  scale incidents are a list.

  The causing card shows the incidents it caused (`caused/1`), and while an
  incident names both, the causing card carries one `process` finding with
  source `incident` (`Slipdock.Findings.Signals.incident/2`) saying which
  layer missed it: the Findings page, `slipdock findings --source incident`
  and the card's chat read it there.
  """
  import Ecto.Query

  alias Slipdock.{Access, Repo}
  alias Slipdock.Boards.Card

  @doc """
  Reads `caused_by` (or `caused_by_id`) out of a card write's `attrs` as the
  card id the changeset casts: a number, `"123"` or `"#123"`; blank or nil
  clears it. `{:ok, attrs}`, or `{:error, :caused_by, message}` when it isn't
  a card id, is the card itself, or names no card `user` can read (a card
  that isn't there reads the same, so a refusal says nothing about a board
  the person can't see). With no `user` (the system's own writes) the card
  only has to exist. An API `token` only narrows what `user` reaches (ARCH-8):
  a card outside its scope is refused, saying the token's scope is why.
  """
  def check(card, attrs, user, token \\ nil)

  def check(%Card{} = card, attrs, user, token) when is_map(attrs) do
    case caused_by_value(attrs) do
      :none ->
        {:ok, attrs}

      {:ok, key, value} ->
        attrs = Map.delete(attrs, key)

        with {:ok, id} <- parse(value),
             :ok <- not_itself(card, id),
             :ok <- readable(id, user, token) do
          {:ok, put(attrs, id)}
        end
    end
  end

  defp caused_by_value(attrs) do
    Enum.find_value(["caused_by", :caused_by, "caused_by_id", :caused_by_id], :none, fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> {:ok, key, value}
        :error -> nil
      end
    end)
  end

  # Kept in the same key style as the rest of the write, which Ecto's cast needs.
  defp put(attrs, id) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, :caused_by_id, id),
      else: Map.put(attrs, "caused_by_id", id)
  end

  defp parse(nil), do: {:ok, nil}
  defp parse(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse(text) when is_binary(text) do
    case text |> String.trim() |> String.trim_leading("#") do
      "" ->
        {:ok, nil}

      digits ->
        case Integer.parse(digits) do
          {id, ""} when id > 0 -> {:ok, id}
          _ -> bad_id(text)
        end
    end
  end

  defp parse(other), do: bad_id(other)

  defp bad_id(value),
    do:
      {:error, :caused_by,
       "#{inspect(value)} isn't a card id: give the causing card's number, like 123 or #123."}

  defp not_itself(%Card{id: id}, id) when not is_nil(id),
    do: {:error, :caused_by, "A card can't be its own cause: name the card that shipped it."}

  defp not_itself(_card, _id), do: :ok

  defp readable(nil, _user, _token), do: :ok

  defp readable(id, user, token) do
    case Repo.get(Card, id) do
      nil ->
        unreadable(id)

      _cause when is_nil(user) ->
        :ok

      cause ->
        level = Access.card_permission(user, cause)

        cond do
          readable?(cause, user, token) -> :ok
          Access.can_read?(level) -> out_of_scope(id)
          true -> unreadable(id)
        end
    end
  end

  @doc """
  Whether `user`, through `token` when there is one, may read `card`: the
  token only narrows (`Slipdock.Access.narrow/3`).
  """
  def readable?(%Card{} = card, user, token \\ nil) do
    {level, _why} = Access.narrow(Access.card_permission(user, card), token, card.board_id)
    Access.can_read?(level)
  end

  @doc "The incidents in `caused/1` that `user` (through `token`) may read."
  def caused_readable(%Card{} = card, user, token \\ nil) do
    user
    |> Access.filter_readable_cards(caused(card))
    |> Enum.filter(&readable?(&1, user, token))
  end

  defp out_of_scope(id),
    do:
      {:error, :caused_by,
       "This API token's scope doesn't reach card ##{id}, so it can't be named as the cause."}

  defp unreadable(id),
    do: {:error, :caused_by, "There is no card ##{id} you can read to name as the cause."}

  @doc "Whether a saved write changed what the incident says, so its finding needs keeping."
  def changed?(%Card{} = before, %Card{} = updated) do
    before.caused_by_id != updated.caused_by_id or before.missed_by != updated.missed_by
  end

  @doc "The card `card` names as its cause, or nil."
  def cause(%Card{caused_by_id: nil}), do: nil
  def cause(%Card{caused_by_id: id}), do: Card |> Repo.get(id) |> Repo.preload(:board)

  @doc """
  The incidents `card` caused: the cards naming it as their cause, oldest
  first, with their boards. Filter them for a reader with
  `Slipdock.Access.filter_readable_cards/2`.
  """
  def caused(%Card{id: id}) do
    Repo.all(
      from c in Card,
        where: c.caused_by_id == ^id and is_nil(c.archived_at),
        order_by: [asc: c.id],
        preload: :board
    )
  end

  @doc """
  The finding's text for an incident that names `layer`:
  "#12 (incident) was missed by ci".
  """
  def finding_text(%Card{id: id}, "none"),
    do: "##{id} (incident) was missed by none: no check could have caught it"

  def finding_text(%Card{id: id}, layer), do: "##{id} (incident) was missed by #{layer}"

  @doc "What a finding about incident `card` is matched on, so a change updates the same one."
  def finding_cause(%Card{id: id}), do: "incident ##{id}"
end
