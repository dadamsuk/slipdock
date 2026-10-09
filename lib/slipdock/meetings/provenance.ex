defmodule Slipdock.Meetings.Provenance do
  @moduledoc """
  A card's *From a meeting* block (G11): which meeting, when in it, the words
  that justified the card or the change to it, who said them, how they were
  read (quoted word for word, both readings agreed, the audio was unclear…)
  and who committed it.

  Stored on the card rather than only on the capture, so the trail survives
  the capture being deleted and the recording expiring. Its quote is
  indexed with the card (`Slipdock.Search.Chunk`), so a card can be found by
  what was said in the meeting that made it.
  """
  use Ecto.Schema

  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Boards.Card

  schema "card_provenance" do
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :capture, Slipdock.Meetings.Capture
    field :kind, :string, default: "created"
    field :meeting, :string
    field :met_at, :utc_datetime
    field :quote, :string
    field :speaker, :string
    field :at_ms, :integer
    field :line, :string
    field :read, :string
    field :committed_by, :string
    field :committed_at, :utc_datetime
  end

  @doc """
  Writes a card's provenance from a change set entry's `provenance` map.
  `kind` is `created` or `changed`.
  """
  def record(%Card{id: card_id}, prov, kind \\ "created") do
    Repo.insert!(%__MODULE__{
      card_id: card_id,
      capture_id: prov["capture_id"],
      kind: kind,
      meeting: prov["meeting"] || "a meeting",
      met_at: parse(prov["met_at"]),
      quote: prov["quote"],
      speaker: prov["speaker"],
      at_ms: prov["at_ms"],
      line: prov["line"],
      read: prov["read"],
      committed_by: prov["committed_by"],
      committed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "A card's provenance, oldest first."
  def for_card(card_id) do
    Repo.all(from(p in __MODULE__, where: p.card_id == ^card_id, order_by: [asc: p.id]))
  end

  @doc "Takes back what one capture wrote on a card (when the capture is undone)."
  def forget(card_id, capture_id) do
    Repo.delete_all(
      from(p in __MODULE__, where: p.card_id == ^card_id and p.capture_id == ^capture_id)
    )
  end

  defp parse(nil), do: nil

  defp parse(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end
end
