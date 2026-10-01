defmodule Slipdock.Coloring do
  @moduledoc """
  "Colour by": the palette colour a card takes on a timeline bar or cover
  strip when the view colours cards by an attribute rather than their own
  cover colour, and the legend that explains it.
  """

  alias Slipdock.Boards.Card
  alias Slipdock.Boards.StatusUpdate

  @priority %{"critical" => "rose", "high" => "orange", "medium" => "amber", "low" => "sky"}
  @priority_labels [
    {"critical", "Critical"},
    {"high", "High"},
    {"medium", "Medium"},
    {"low", "Low"}
  ]
  @health %{done: "emerald", blocked: "red", late: "amber", ok: "sky", dropped: "slate"}
  @health_labels [
    {:ok, "On track"},
    {:late, "At risk"},
    {:blocked, "Blocked"},
    {:done, "Done"},
    {:dropped, "Dropped"}
  ]
  @stated %{"on_track" => "emerald", "at_risk" => "amber", "off_track" => "red"}
  # Colours handed out in turn to lists and people that have none of their own.
  @cycle ~w(indigo teal fuchsia lime orange violet sky rose amber emerald)

  @doc "The palette colour (or nil) for `card` under `color_by`."
  def color(card, "cover", _board), do: card.color

  def color(card, "column", board) do
    case Enum.find_index(board.columns, &(&1.id == card.column_id)) do
      nil -> nil
      i -> Enum.at(board.columns, i).color || cycle(i)
    end
  end

  def color(card, "priority", _board), do: Map.get(@priority, card.priority)

  def color(card, "health", _board) do
    health = Card.health(card) || if(card.completed, do: :done, else: :ok)
    Map.get(@health, health)
  end

  def color(card, "stated", _board), do: Map.get(@stated, Card.stated_health(card))
  def color(%{assignee_id: nil}, "assignee", _board), do: nil
  def color(%{assignee_id: id}, "assignee", _board), do: cycle(id)
  def color(%{tags: [tag | _]}, "tag", _board), do: tag.color
  def color(_card, _color_by, _board), do: nil

  @doc "The legend for `color_by` on `board`, as `{palette_name, label}`."
  def legend(_board, "cover"), do: []

  def legend(board, "column") do
    board.columns
    |> Enum.with_index()
    |> Enum.map(fn {col, i} -> {col.color || cycle(i), col.name} end)
  end

  def legend(_board, "priority"),
    do: Enum.map(@priority_labels, fn {k, l} -> {@priority[k], l} end)

  def legend(_board, "health"), do: Enum.map(@health_labels, fn {k, l} -> {@health[k], l} end)

  def legend(_board, "stated"),
    do: Enum.map(StatusUpdate.healths(), fn {k, l} -> {@stated[k], l} end)

  def legend(board, "assignee") do
    board.columns
    |> Enum.flat_map(&(&1.cards || []))
    |> Enum.map(fn
      %{assignee: %Slipdock.Accounts.User{} = u} -> u
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&String.downcase(Slipdock.Accounts.User.display_name(&1)))
    |> Enum.map(&{cycle(&1.id), Slipdock.Accounts.User.display_name(&1)})
  end

  def legend(board, "tag"), do: Enum.map(board.tags, &{&1.color, &1.name})
  def legend(_board, _), do: []

  defp cycle(i) when is_integer(i), do: Enum.at(@cycle, rem(abs(i), length(@cycle)))
end
