defmodule Slipdock.Overseer.Check do
  @moduledoc """
  One of the overseer's watch checks (#2068): a function over what the
  server already holds, costing no tokens. It reads a root board's tree
  through the context `Slipdock.Overseer.Watch` builds and returns the
  conditions it sees now; it changes nothing. The watch keeps them: a
  condition seen for the first time fires (an alert, an email), one still
  seen stays quiet, and one no longer seen clears.

  A condition is a map:

    * `:subject` – what it is about, unique within the check (`card:12`);
    * `:card_id` – the card a person should open;
    * `:title` – one line, at most 200 characters;
    * `:why` – what was seen, with the evidence;
    * `:todo` – what to do about it;
    * `:severity` – `"warning"` unless given (`info`, `warning`, `urgent`).
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card}

  @type context :: %{
          root: Board.t(),
          board_ids: [integer],
          settings: Slipdock.Overseer.Settings.t(),
          now: DateTime.t()
        }

  @type condition :: %{
          required(:subject) => String.t(),
          required(:card_id) => integer | nil,
          required(:title) => String.t(),
          required(:why) => String.t(),
          required(:todo) => String.t(),
          optional(:severity) => String.t()
        }

  @doc "Its key: what the API, the CLI and a condition call it."
  @callback key() :: String.t()

  @doc "A short human name."
  @callback label() :: String.t()

  @doc "The conditions it sees in the tree now."
  @callback find(context) :: [condition]

  @doc "Cards on the tree's boards: open, not archived, not a stand-in."
  def live_cards(%{board_ids: ids}) do
    from(c in Card,
      as: :card,
      where: c.board_id in ^ids,
      where: is_nil(c.archived_at) and not c.completed and is_nil(c.stand_in_for_id)
    )
  end

  @doc "A card's id and title as a person reads it: `#12 “Title”`."
  def ref(%{id: id, title: title}), do: "##{id} “#{String.slice(title || "", 0, 80)}”"

  @doc "`seconds` as a short duration: `45m`, `3h 10m`, `2d 4h`."
  def duration(seconds) when seconds < 3600, do: "#{max(div(seconds, 60), 1)}m"

  def duration(seconds) when seconds < 86_400 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if m == 0, do: "#{h}h", else: "#{h}h #{m}m"
  end

  def duration(seconds) do
    d = div(seconds, 86_400)
    h = div(rem(seconds, 86_400), 3600)
    if h == 0, do: "#{d}d", else: "#{d}d #{h}h"
  end

  @doc "A list of card refs, the first `n` and how many more."
  def refs(cards, n \\ 5) do
    shown = cards |> Enum.take(n) |> Enum.map_join(", ", &ref/1)
    more = length(cards) - n
    if more > 0, do: shown <> " and #{more} more", else: shown
  end
end
