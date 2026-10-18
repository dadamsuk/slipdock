defmodule Slipdock.Gardener.Checks.DuplicateCards do
  @moduledoc """
  Pairs of open cards that read alike (W-1807): their stored title and
  description embeddings have a similarity of at least `similarity`
  (default 0.92). The fix links them as duplicates and archives the one the
  person picks.

  No model is called: it scores the vectors search already keeps, for the
  current embedding model only, exactly and pairwise. That is quadratic, so
  a run looks at no more than `max_cards` open cards (default 5000) — the
  most recently updated, when there are more. Pairs already linked in any
  way are left alone: somebody has already said how they relate.

  The fingerprint is the pair and nothing else, so "these aren't the same"
  stays dismissed however either card is edited later.
  """
  @behaviour Slipdock.Gardener.Check

  import Ecto.Query

  alias Slipdock.Boards.CardLink
  alias Slipdock.Gardener.Checks.Cards
  alias Slipdock.Repo
  alias Slipdock.Search.{Embedding, Vector}

  @impl true
  def key, do: "duplicate_cards"
  @impl true
  def label, do: "Possible duplicates"
  @impl true
  def defaults, do: %{"enabled" => true, "similarity" => 0.92, "max_cards" => 5000}

  @impl true
  def find(ctx, %{"similarity" => threshold, "max_cards" => cap}) do
    cards =
      ctx
      |> Cards.cards()
      |> Enum.reject(& &1.completed)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(cap)

    by_id = Map.new(cards, &{&1.id, &1})
    vectors = vectors(Map.keys(by_id))
    linked = linked_pairs(Map.keys(vectors))

    for {a, b, score} <- pairs(Enum.sort(vectors), threshold, []),
        not MapSet.member?(linked, {a, b}) do
      ca = by_id[a]
      cb = by_id[b]

      %{
        subject: %{"cards" => [a, b]},
        state: nil,
        proposal: [
          %{"op" => "link_duplicate", "card" => "pick", "other" => "keep", "from" => [a, b]},
          %{"op" => "archive", "card" => "pick", "from" => [a, b]}
        ],
        explanation:
          "“#{ca.title}” (##{a}) and “#{cb.title}” (##{b}) read alike " <>
            "(similarity #{:erlang.float_to_binary(score, decimals: 2)})"
      }
    end
  end

  # card id => vector, for the cards with one from the current model.
  defp vectors([]), do: %{}

  defp vectors(ids) do
    model = Slipdock.AI.Embeddings.model()

    from(e in Embedding,
      where: e.kind == "card" and e.card_id in ^ids and e.model == ^model,
      select: {e.card_id, e.vector}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Every pair already linked, smaller id first.
  defp linked_pairs([]), do: MapSet.new()

  defp linked_pairs(ids) do
    from(l in CardLink,
      where: l.from_id in ^ids and l.to_id in ^ids,
      select: {l.from_id, l.to_id}
    )
    |> Repo.all()
    |> MapSet.new(fn {a, b} -> {min(a, b), max(a, b)} end)
  end

  # Every pair (smaller id first) at or above the threshold, best first.
  defp pairs([], _threshold, acc), do: Enum.sort_by(acc, &elem(&1, 2), :desc)

  defp pairs([{a, va} | rest], threshold, acc) do
    acc =
      Enum.reduce(rest, acc, fn {b, vb}, acc ->
        score = Vector.similarity(va, vb)
        if score >= threshold, do: [{a, b, score} | acc], else: acc
      end)

    pairs(rest, threshold, acc)
  end
end
