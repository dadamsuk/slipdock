defmodule Slipdock.Kinds do
  @moduledoc """
  What kind of thing something in a list is: a **card**, a **document** or a
  **wiki page**. What the filter bar's Kind section narrows by.

  There are only two rows behind the three names — a card and a page (see
  `Slipdock.Wiki.Page`) — because "Add a document…" is a shortcut to adding a
  card with a file attached, not a fourth kind of thing on the board. So a
  document is *recognised* rather than recorded: a card whose whole content
  is the file it carries — an attachment, no description, no checklist, no
  subcards. Write a description on it, tick something off or hang work
  beneath it, and it is a card about the work again, which is the right
  answer: it is no longer just the file. (Comments are allowed: "here's the
  spec" / "thanks" is what a document on a board is for.)

  `kind_of/1` therefore needs a card's `attachments`, `checklist_items` and
  `sub_board` loaded, which the board's own loader does
  (`Slipdock.Boards.get_board!/1`).
  A card loaded light — the rollup's, which the outline reads — carries the
  answer in its `document` virtual field instead, because asking its
  attachments would mean a query per card.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Wiki.Page

  @kinds [
    {"card", "Cards"},
    {"document", "Documents"},
    {"page", "Wiki pages"}
  ]
  @keys Enum.map(@kinds, &elem(&1, 0))
  # A page is not a card, so the two that a card list can offer.
  @card_kinds Enum.reject(@kinds, &(elem(&1, 0) == "page"))

  @doc "The kinds, as `{key, label}` in the order the filter offers them."
  def all, do: @kinds

  @doc "Just the keys: `[\"card\", \"document\", \"page\"]`."
  def keys, do: @keys

  @doc """
  The kinds a *card* can be, as `{key, label}`. A wiki page is the third
  kind and is not a card, so a card listing (the API's and the CLI's) offers
  these two and sends you to the pages for the rest.
  """
  def card_kinds, do: @card_kinds

  @doc "The label for a kind key, or the key itself if it isn't one."
  def label(key) do
    case List.keyfind(@kinds, to_string(key), 0) do
      {_, label} -> label
      nil -> to_string(key)
    end
  end

  @doc "Which kind `item` is: `\"page\"`, `\"document\"` or `\"card\"`."
  def kind_of(%Page{}), do: "page"
  def kind_of(item), do: if(document?(item), do: "document", else: "card")

  @doc """
  Whether `item` passes a kind filter. An empty list is no filter, the way
  every other list filter works.
  """
  def matches?(_item, []), do: true
  def matches?(item, kinds) when is_list(kinds), do: kind_of(item) in kinds
  def matches?(_item, _), do: true

  @doc """
  Whether a card is a document: a file, and nothing of its own besides.

  A card that was loaded without its attachments can't be asked, so it
  answers `false` unless it carries the `document` field (see the moduledoc).
  """
  def document?(%Page{}), do: false
  def document?(%Card{document: known}) when is_boolean(known), do: known

  def document?(%{attachments: attachments} = card) when is_list(attachments) do
    attachments != [] and blank?(Map.get(card, :description)) and
      checklist(card) == [] and subcards(card) == 0
  end

  def document?(_item), do: false

  defp checklist(%{checklist_items: items}) when is_list(items), do: items
  defp checklist(_), do: []

  defp subcards(card) do
    case Card.subcard_progress(card) do
      {_done, total} -> total
      nil -> 0
    end
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false
end
