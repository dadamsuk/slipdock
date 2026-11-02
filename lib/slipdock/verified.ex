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
    * **Evidence** (`Board.evidence_required`, #1632): an agent completing a
      card says what it checked (`evidence`) and, if there is one, the commit
      it checked at (`evidence_commit`), in the same write or beforehand. The
      evidence is posted as a comment when the card completes, and cleared
      when it is reopened, so the next completion carries its own.

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
    [bar: board.bar_required, evidence: board.evidence_required]
    |> Enum.filter(fn {_, on} -> on == true end)
    |> Keyword.keys()
  end

  ## The bar ------------------------------------------------------------------

  @doc """
  `{:ok, attrs}` — `attrs` as they are to be saved — or
  `{:error, field, message}` when `actor` may not make the change they
  describe to `card`: an agent changing a locked bar, or completing a card
  with no evidence on a board that asks for it.
  """
  def check_update(%Card{} = card, attrs, actor) do
    with :ok <- check_bar_edit(card, attrs, actor),
         :ok <- check_evidence(card, attrs, actor) do
      {:ok, clear_evidence(card, attrs)}
    end
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
  an agent starting work on a card with no bar on a board that asks for one,
  or completing one by a move with no evidence on a board that asks for it.
  """
  def check_move(%Card{} = card, %Column{} = to, actor) do
    cond do
      doing?(to) and blank?(card.bar) and gated?(actor) and board(card).bar_required ->
        {:error,
         "this board asks for each card's bar before work starts: write what done means " <>
           "for card ##{card.id} (its `bar`), then move it"}

      message = check_done_move(card, to, actor) ->
        {:error, message}

      true ->
        :ok
    end
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

  ## Evidence -----------------------------------------------------------------

  @evidence_message "is required: this board asks an agent completing a card for what it " <>
                      "checked (evidence, and the commit it checked at if there is one)"

  defp check_evidence(%Card{} = card, attrs, actor) do
    if completes?(card, attrs) and gated?(actor) and
         blank?(given(attrs, :evidence, card.evidence)) and board(card).evidence_required,
       do: {:error, :evidence, @evidence_message},
       else: :ok
  end

  # Reopened on a board that asks for evidence: what it carried was for the
  # completion that is being undone (and was kept as a comment then).
  defp clear_evidence(%Card{completed: true} = card, attrs) do
    if fetch(attrs, :completed) in [false, "false"] and
         not (blank?(card.evidence) and blank?(card.evidence_commit)) and
         board(card).evidence_required,
       do: attrs |> stringify() |> Map.merge(%{"evidence" => nil, "evidence_commit" => nil}),
       else: attrs
  end

  defp clear_evidence(_card, attrs), do: attrs

  @doc """
  The message an agent gets moving a card into a done list with no evidence
  on a board that asks for it, or nil when it may.
  """
  def check_done_move(%Card{completed: false} = card, %Column{} = to, actor) do
    if Column.done?(to) and gated?(actor) and blank?(card.evidence) and
         board(card).evidence_required,
       do:
         "this board asks for evidence when an agent completes a card: complete card ##{card.id} " <>
           "with what you checked (`evidence`, and `evidence_commit`) rather than moving it"
  end

  def check_done_move(_card, _to, _actor), do: nil

  @doc """
  After `before` has been saved as `updated`: a card completed with evidence
  on a board that asks for it gets the evidence as a comment, by `user`.
  """
  def saved(%Card{completed: false}, %Card{completed: true} = updated, user) do
    if not blank?(updated.evidence) and board(updated).evidence_required do
      commit =
        if updated.evidence_commit, do: "\n\nCommit: `#{updated.evidence_commit}`", else: ""

      Slipdock.Boards.add_comment(updated, "**Evidence.**\n\n#{updated.evidence}#{commit}",
        by: user
      )
    end

    :ok
  end

  def saved(_before, _updated, _user), do: :ok

  defp completes?(%Card{completed: false}, attrs), do: fetch(attrs, :completed) in [true, "true"]
  defp completes?(_card, _attrs), do: false

  # What `attrs` set `key` to, else what the card already has.
  defp given(attrs, key, current) do
    case fetch(attrs, key) do
      :none -> current
      value -> value
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

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
