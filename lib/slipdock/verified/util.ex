defmodule Slipdock.Verified.Util do
  @moduledoc """
  The small helpers the `Slipdock.Verified` modules share: a card's board,
  a key read from string- or atom-keyed attrs, blank and trimmed text, and
  whether a write completes a card.
  """

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo

  @doc false
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(value) when is_list(value) or is_map(value), do: value != [] and value != %{}
  def present?(value), do: not is_nil(value)

  @doc false
  def completes?(%Card{completed: false}, attrs),
    do: Enum.member?([true, "true"], fetch(attrs, :completed))

  def completes?(_card, _attrs), do: false

  # What `attrs` set `key` to, else what the card already has.
  @doc false
  def given(attrs, key, current) do
    case fetch(attrs, key) do
      :none -> current
      value -> value
    end
  end

  @doc false
  def stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  @doc false
  def blank_to_nil(""), do: nil
  def blank_to_nil(text), do: text

  @doc false
  def now, do: DateTime.utc_now(:second)

  ## Helpers ------------------------------------------------------------------

  # By its category, else by its name (#2676): a Simple sub-board's "Doing".
  @doc false
  def doing?(%Column{} = column), do: Slipdock.Flow.doing_list?(column)
  def doing?(_), do: false

  @doc false
  def board(%Card{board: %Board{} = board}), do: board
  def board(%Card{board_id: id}), do: Repo.get!(Board, id)

  # A key from string- or atom-keyed attrs; :none when it isn't there.
  @doc false
  def fetch(attrs, key) do
    cond do
      Map.has_key?(attrs, to_string(key)) -> attrs[to_string(key)]
      Map.has_key?(attrs, key) -> attrs[key]
      true -> :none
    end
  end

  @doc false
  def trim(nil), do: ""
  def trim(text) when is_binary(text), do: String.trim(text)
  def trim(other), do: to_string(other)

  @doc false
  def blank?(text), do: trim(text) == ""
end
