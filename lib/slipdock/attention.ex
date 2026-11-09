defmodule Slipdock.Attention do
  @moduledoc """
  Whether a flag on a card needs a person, or will be cleared by the board's
  own processes (#2624). A glance at "Needs review" should say whether
  someone has to review it or a verifier agent already will.

  `of/2` gives, for one flag on one card, `{attention, why}`:

    * `"person"` — nothing on the board clears it by itself: somebody has to
      act. Drawn filled, with the hand;
    * `"auto"` — something already in motion clears it: drawn outline only;
    * `"none"` — a mark that asks nothing of anyone (`starred`).

  `why` is one line saying who clears it, for the chip's tooltip, the API
  and the CLI. The answer reads only what is on the card:

    * `waiting` — an open wait on a person's answer: a person;
    * `flagged` — put on by hand, and only a person takes it off;
    * `stuck` — the health monitor sets it only once its own fixes have run
      out (`Slipdock.Health`): a person;
    * `blocked` — while the card has a blocker card still open, the board
      takes the flag off when that card is done (`Boards`' unblock): auto.
      Blocked with no open blocker card is blocked on something outside the
      board: a person;
    * `review` — pending verification on a board with a verify pool
      (`state.verifier`, from `Slipdock.CardState`) is decided by a
      verifier agent, and one being merged by the merge runner: auto. A
      card held for a person's merge, pending with no verify pool, or
      flagged by hand: a person.
  """

  alias Slipdock.Boards.Card

  @doc "The attentions, in the order the help page explains them."
  def kinds, do: ~w(person auto none)

  @doc "`{attention, why}` for `flag` on `card`: see the moduledoc."
  def of(flag, card)

  def of("waiting", _card), do: {"person", "Waits on a person's answer."}

  def of("flagged", _card),
    do: {"person", "Flagged by hand: whoever is on it takes the flag off."}

  def of("stuck", _card),
    do: {"person", "The health monitor's fixes ran out: a person needs to look."}

  def of("starred", _card), do: {"none", "A bookmark: asks nothing of anyone."}

  def of("blocked", card) do
    case Card.open_blockers(card) do
      [] ->
        {"person", "Blocked on something outside the board: a person unblocks it."}

      blockers ->
        ids = Enum.map_join(blockers, ", ", &"##{&1.id}")
        {"auto", "Clears itself when #{ids} is done."}
    end
  end

  def of("review", card) do
    case {Map.get(card, :verify_state), verifier?(card)} do
      {"pending", true} ->
        {"auto", "A verifier agent checks it and decides."}

      {"merging", _} ->
        {"auto", "Accepted: the merge runner is merging it."}

      {"held", _} ->
        {"person", "Accepted, and held for a person to merge."}

      {"pending", false} ->
        {"person", "Awaiting verification: no verifier agent, so a person decides."}

      _ ->
        {"person", "Flagged for review by hand: a person reviews it."}
    end
  end

  def of(_flag, _card), do: {"person", "A person takes it off."}

  @doc "`of/2`'s attention alone."
  def attention(flag, card), do: flag |> of(card) |> elem(0)

  @doc "Whether `flag` on `card` needs a person."
  def person?(flag, card), do: attention(flag, card) == "person"

  @doc """
  Every flag on `card`, as `%{flag => %{"attention" => …, "why" => …}}`: the
  API's and MCP's `flag_attention`.
  """
  def map(%{flags: flags} = card) when is_list(flags) do
    Map.new(flags, fn flag ->
      {attention, why} = of(flag, card)
      {flag, %{"attention" => attention, "why" => why}}
    end)
  end

  def map(_card), do: %{}

  defp verifier?(%{state: %{verifier: true}}), do: true
  defp verifier?(_card), do: false
end
