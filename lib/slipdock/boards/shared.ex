defmodule Slipdock.Boards.Shared do
  @moduledoc """
  Helpers the board contexts share: rows that hang off a card or a wiki page
  (`Slipdock.Boards.Owned`), list positions and ids from a client.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.Activity
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Owned
  alias Slipdock.Repo
  alias Slipdock.Search.Indexer

  @doc false
  def to_id(%Board{id: id}), do: id
  def to_id(id) when is_integer(id), do: id

  def to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def to_id(_), do: nil

  ## Cards and pages, together -----------------------------------------------
  #
  # Comments, status updates, checklist items and web links hang off a card
  # *or* off a wiki page — one table each, one row belonging to exactly one
  # of the two, with the database saying so (see `Slipdock.Boards.Owned`). The
  # writers in the other contexts take whichever; these route the side effects.

  # The owner's foreign key, ready to `struct!` onto a new row.
  @doc false
  def owned_by(owner), do: Owned.owner_key(owner)

  # An activity line about a card or a page.
  @doc false
  def log_owned(owner, kind, message) do
    %Activity{board_id: owner.board_id, kind: kind, message: message}
    |> struct!(owned_by(owner))
    |> Activity.stamp()
    |> Repo.insert()
  end

  # Tell the board, and re-index. A page is indexed by its own chunker, so
  # the Page clause has to come first: `Indexer.enqueue/1` matches any struct.
  @doc false
  def notify_owned(%Slipdock.Wiki.Page{} = page) do
    Boards.PubSub.broadcast(page.board_id)
    Indexer.enqueue_page(page)
  end

  def notify_owned(%Card{} = card) do
    Boards.PubSub.broadcast(card.board_id)
    Indexer.enqueue(card)
  end

  # The card or page a row hangs off, loaded.
  @doc false
  def owner_of(%{card_id: id}) when is_integer(id), do: Repo.get!(Card, id)
  def owner_of(%{page_id: id}) when is_integer(id), do: Repo.get!(Slipdock.Wiki.Page, id)

  ## Helpers

  # `where` for "the rows belonging to this card or this page".
  @doc false
  def owned_clause(%Slipdock.Wiki.Page{id: id}), do: dynamic([r], r.page_id == ^id)
  def owned_clause(%{id: id}), do: dynamic([r], r.card_id == ^id)

  # A row of `schema` by a client's id, only if it hangs off `owner`.
  @doc false
  def get_owned(_schema, nil, _id), do: nil

  def get_owned(schema, owner, id) do
    case to_id(id) do
      nil -> nil
      id -> Repo.one(from(r in schema, where: r.id == ^id, where: ^owned_clause(owner)))
    end
  end

  @doc false
  def next_position(query) do
    case Repo.one(from(q in query, select: max(q.position))) do
      nil -> 0
      max -> max + 1
    end
  end

  @doc false
  def tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  def tap_ok(other, _fun), do: other

  ## Lookups (#2791): plain reads the web layer makes through this context

  @doc """
  The checklist item or comment `id` (`schema` says which), or nil: for
  routes that find the card or page it hangs off from the row itself.
  """
  def get_owned_row(schema, id) when schema in [Boards.ChecklistItem, Boards.Comment],
    do: Repo.get(schema, id)
end
