defmodule Slipdock.Filters do
  @moduledoc """
  The board toolbar's filters — text, kind, tags, priority, flag, due, stuck,
  driver, origin (#2778), hide completed — and what they match. `stuck` and `driver` read
  the card's `state` (`Slipdock.CardState`), which a page never has.

  `matches?/2` reads the thing by shape rather than by struct, so it takes a
  card or a wiki page: a page carries the same facets under the same names
  (see `Slipdock.Wiki.Page`), which is the whole reason the wiki can offer the
  same filter bar the card views do.
  """

  @empty %{
    q: "",
    kinds: [],
    tags: [],
    priority: nil,
    flag: nil,
    due: nil,
    stuck: false,
    driver: nil,
    origin: nil,
    hide_completed: false
  }

  @doc "Filters with nothing set."
  def empty, do: @empty

  @doc "Whether any filter is set."
  def any?(filters), do: filters != @empty

  @doc "How many filters are set, for the badge on the button."
  def count(filters) do
    Enum.count(
      [
        filters.q != "",
        filters.kinds != [],
        filters.tags != [],
        not is_nil(filters.priority),
        not is_nil(filters.flag),
        not is_nil(filters.due),
        filters.stuck,
        not is_nil(filters.driver),
        not is_nil(Map.get(filters, :origin)),
        filters.hide_completed
      ],
      & &1
    )
  end

  @doc """
  Whether a card or a page passes the filters.

  `kinds` is the one filter that reads the item's *sort* rather than its
  facets: cards, documents, wiki pages, or any mix (see `Slipdock.Kinds`).
  """
  def matches?(item, filters, today \\ Date.utc_today()) do
    q = String.downcase(filters.q)
    tags = tags_of(item)

    Slipdock.Kinds.matches?(item, filters.kinds) and
      (q == "" or
         named?(item, q) or
         String.contains?(String.downcase(item.title), q) or
         String.contains?(String.downcase(text_of(item)), q) or
         Enum.any?(tags, &String.contains?(String.downcase(&1.name), q))) and
      (filters.tags == [] or Enum.any?(tags, &Enum.member?(filters.tags, &1.id))) and
      (is_nil(filters.priority) or item.priority == filters.priority) and
      (is_nil(filters.flag) or Enum.member?(item.flags, filters.flag)) and
      due_matches?(filters.due, item, today) and
      made_and_moved?(item, filters) and
      not (filters.hide_completed and item.completed)
  end

  # Its state (stuck, driver) and its origin (#2778): one helper, so
  # `matches?/3` takes no new branch.
  defp made_and_moved?(item, filters) do
    Slipdock.CardState.matches?(item, filters.stuck, filters.driver) and
      origin_matches?(item, Map.get(filters, :origin))
  end

  # Who or what made it (#2778): "none" for an item with no origin, which a
  # page always is.
  defp origin_matches?(_item, nil), do: true
  defp origin_matches?(item, "none"), do: is_nil(Map.get(item, :origin))
  defp origin_matches?(item, origin), do: Map.get(item, :origin) == origin

  # A card's description and a page's summary are the same line to a reader
  # searching for a word; `Page.for_board/1` fills `description` in from the
  # summary, and the raw page falls back to it here.
  defp text_of(%{description: text}) when is_binary(text), do: text
  defp text_of(%{summary: text}) when is_binary(text), do: text
  defp text_of(_), do: ""

  # A page answers to its code (`W-31`) as well as its words: typed whole, it
  # finds that page and no other.
  defp code_of(%{code: code}) when is_binary(code), do: String.downcase(code)
  defp code_of(_), do: nil

  # Typed whole, a page's code names that page and a card's id that card.
  defp named?(item, q), do: code_of(item) == String.trim(q) or names_card?(item, q)

  @doc """
  Whether `q` names `item` by its id (`123`, `#123`) or its link
  (`Slipdock.Boards.Links.card_ref/1`). A card answers to its id as well as its
  words, so the search box finds a card by the number it is known by (#2097).
  Only a card: a page is named by its code, and its id is nobody's to type.
  """
  def names_card?(%Slipdock.Boards.Card{id: id}, q) when is_integer(id),
    do: Slipdock.Boards.Links.card_ref(q) == id

  def names_card?(_item, _q), do: false

  defp tags_of(%{tags: tags}) when is_list(tags), do: tags
  defp tags_of(_), do: []

  defp due_matches?(nil, _item, _today), do: true
  defp due_matches?("none", item, _today), do: is_nil(item.due_date)

  defp due_matches?("overdue", %{due_date: %Date{} = d, completed: false}, today),
    do: Date.before?(d, today)

  defp due_matches?("overdue", _item, _today), do: false

  defp due_matches?("week", %{due_date: %Date{} = d, completed: false}, today),
    do: Date.diff(d, today) <= 7

  defp due_matches?("week", _item, _today), do: false
  defp due_matches?(_other, _item, _today), do: true
end
