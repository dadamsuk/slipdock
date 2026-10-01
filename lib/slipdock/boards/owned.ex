defmodule Slipdock.Boards.Owned do
  @moduledoc """
  The rule shared by everything that hangs off *either* a card or a wiki
  page: comments, status updates, checklist items, votes, web links, custom
  field values and attachments.

  Each of those tables carries a nullable `card_id` and a nullable `page_id`
  with a database `CHECK` that exactly one is set. Saying the same thing in
  the changeset turns a constraint error into a readable message, and gives
  every one of them the same message.
  """
  import Ecto.Changeset

  @doc "Refuses a row belonging to both a card and a page, or to neither."
  def validate_owner(changeset) do
    case {get_field(changeset, :card_id), get_field(changeset, :page_id)} do
      {nil, nil} ->
        add_error(changeset, :card_id, "must belong to a card or a page")

      {card, page} when is_integer(card) and is_integer(page) ->
        add_error(changeset, :card_id, "cannot belong to both a card and a page")

      _ ->
        changeset
    end
  end

  @doc "What a row hangs off: `:card` or `:page`."
  def owner(%{card_id: id}) when is_integer(id), do: :card
  def owner(%{page_id: id}) when is_integer(id), do: :page

  @doc """
  The owner as a ref, the same `{:card, id}` / `{:page, id}` shape the board
  uses for the things in a list (see `Slipdock.Boards.item_ref/1`).
  """
  def owner_ref(%{card_id: id}) when is_integer(id), do: {:card, id}
  def owner_ref(%{page_id: id}) when is_integer(id), do: {:page, id}

  @doc """
  The foreign key for an owner, as a keyword list ready to merge into attrs
  or into a struct: `owner_key(card)` is `[card_id: card.id]`.
  """
  def owner_key(%Slipdock.Wiki.Page{id: id}), do: [page_id: id, card_id: nil]
  def owner_key(%{id: id}), do: [card_id: id, page_id: nil]

  @doc "Whether `owner` is a wiki page rather than a card."
  def page?(%Slipdock.Wiki.Page{}), do: true
  def page?(_), do: false
end
