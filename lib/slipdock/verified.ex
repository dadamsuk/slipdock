defmodule Slipdock.Verified do
  @moduledoc """
  Verified work (#1620): optional, per-board checks on what an agent says it
  finished. Every switch is off by default, and with them all off nothing
  here changes anything.

    * **The bar** (`Board.bar_required`, #1631): what done means for a card,
      written before work starts. An agent can't move a card into a doing
      list without one, and the bar locks the first time the card enters a
      doing list with one written. After that an agent can't change it; a
      person still can.

  The checks apply to agents (`Slipdock.Actor` kind `"agent"`), not to the
  in-app assistant, which acts on a person's say in the web app, nor to
  people or automations: a person is who the checks report to.
  """

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo

  @doc "Whether the checks apply to a change made by `actor`."
  def gated?(%{kind: "agent", via: via}) when via != "assistant", do: true
  def gated?(_actor), do: false

  @doc "Whether `board` has any of the switches on, and which."
  def switches(%Board{} = board) do
    [bar: board.bar_required]
    |> Enum.filter(fn {_, on} -> on == true end)
    |> Keyword.keys()
  end

  ## The bar ------------------------------------------------------------------

  @doc """
  `:ok`, or `{:error, message}` when `actor` may not make the change `attrs`
  describe to `card`: an agent changing a locked bar.
  """
  def check_update(%Card{} = card, attrs, actor) do
    with :ok <- check_bar_edit(card, attrs, actor), do: :ok
  end

  defp check_bar_edit(%Card{bar_locked_at: nil}, _attrs, _actor), do: :ok

  defp check_bar_edit(%Card{} = card, attrs, actor) do
    new = fetch(attrs, :bar)

    cond do
      new == :none or not gated?(actor) ->
        :ok

      trim(new) == trim(card.bar) ->
        :ok

      not board(card).bar_required ->
        :ok

      true ->
        {:error, :bar,
         "is locked: it was set before work started and only a person can change it now"}
    end
  end

  @doc """
  `:ok`, or `{:error, message}` when `actor` may not move `card` into `to`:
  an agent starting work on a card with no bar on a board that asks for one.
  """
  def check_move(%Card{} = card, %Column{} = to, actor) do
    if doing?(to) and blank?(card.bar) and gated?(actor) and board(card).bar_required,
      do:
        {:error,
         "this board asks for each card's bar before work starts: write what done means " <>
           "for card ##{card.id} (its `bar`), then move it"},
      else: :ok
  end

  @doc """
  After `card` has moved into `to`: the bar locks when work starts, if it is
  written and the board asks for one.
  """
  def moved(%Card{bar_locked_at: nil} = card, %Column{} = to) do
    if doing?(to) and not blank?(card.bar) and board(card).bar_required do
      card
      |> Ecto.Changeset.change(bar_locked_at: DateTime.utc_now(:second))
      |> Repo.update()
    else
      {:ok, card}
    end
  end

  def moved(%Card{} = card, _to), do: {:ok, card}

  ## Helpers ------------------------------------------------------------------

  defp doing?(%Column{category: "doing"}), do: true
  defp doing?(_), do: false

  defp board(%Card{board: %Board{} = board}), do: board
  defp board(%Card{board_id: id}), do: Repo.get!(Board, id)

  # A key from string- or atom-keyed attrs; :none when it isn't there.
  defp fetch(attrs, key) do
    cond do
      Map.has_key?(attrs, to_string(key)) -> attrs[to_string(key)]
      Map.has_key?(attrs, key) -> attrs[key]
      true -> :none
    end
  end

  defp trim(nil), do: ""
  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(other), do: to_string(other)

  defp blank?(text), do: trim(text) == ""
end
