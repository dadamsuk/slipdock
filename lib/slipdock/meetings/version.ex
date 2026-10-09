defmodule Slipdock.Meetings.Version do
  @moduledoc """
  What a card or a page looked like when a capture read it, as one short
  string (G7). A proposed change carries the version of its target; the
  commit compares it with the target as it is now and refuses, naming the
  target, when they differ — so a commit never writes over a change somebody
  made after the review was put together.

  A card's version covers what a capture could change or depend on: title,
  description, list, assignees, dates, priority, completion, archiving and
  its comments' count. A page's is its `content_hash` (and title).
  """
  import Ecto.Query, warn: false

  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Repo
  alias Slipdock.Wiki.Page

  @doc "The current version of a card or a page."
  def of(%Card{} = card) do
    card = Repo.preload(card, :assignees)
    comments = Repo.aggregate(from(c in Comment, where: c.card_id == ^card.id), :count)

    [
      card.title,
      card.description,
      card.column_id,
      card.board_id,
      card.assignees |> Enum.map(& &1.id) |> Enum.sort(),
      card.start_date,
      card.due_date,
      card.priority,
      card.completed,
      card.archived_at,
      card.percent_complete,
      Enum.sort(card.flags || []),
      comments
    ]
    |> digest()
  end

  def of(%Page{} = page), do: digest([page.title, page.content_hash, page.archived_at])

  @doc "The version of the card or page with this id now, or nil when it is gone."
  def current("card", id) do
    case Repo.get(Card, id) do
      nil -> nil
      card -> of(card)
    end
  end

  def current("page", id) do
    case Repo.get(Page, id) do
      nil -> nil
      page -> of(page)
    end
  end

  defp digest(parts) do
    :crypto.hash(:sha256, :erlang.term_to_binary(parts))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
