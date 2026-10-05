defmodule Slipdock.Search.Embedding do
  @moduledoc """
  One embedded chunk of what people have written: a card, a comment, a status
  update or a section of a wiki page, as a unit-length vector plus the text it
  came from.

  A chunk is identified by `{kind, source_id, section}`. `section` is empty
  for everything that is one chunk of its own, and carries the heading path
  for a page, which is written in several pieces so that editing one section
  re-embeds one section.

  `card_id` / `page_id` (exactly one) and `board_id` are denormalised so
  results roll up without a join and permission filtering is one `in`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(card comment status_update page page_section)

  schema "search_embeddings" do
    field :kind, :string
    field :source_id, :integer
    field :section, :string, default: ""
    field :body, :string
    field :content_hash, :string
    field :model, :string
    field :dimensions, :integer
    field :vector, :binary

    # Set when a search returns this row: the dot product against the query.
    field :score, :float, virtual: true

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc "How a chunk of this kind is described in results and to the model."
  def label("card"), do: "card"
  def label("comment"), do: "comment"
  def label("status_update"), do: "status update"
  def label("page"), do: "page"
  def label("page_section"), do: "page section"
  def label(other), do: other

  @doc "Whether a chunk of this kind came from a wiki page."
  def page?(kind), do: kind in ~w(page page_section)

  def changeset(embedding, attrs) do
    embedding
    |> cast(attrs, [
      :kind,
      :source_id,
      :section,
      :card_id,
      :page_id,
      :board_id,
      :body,
      :content_hash,
      :model,
      :dimensions,
      :vector
    ])
    |> validate_required([
      :kind,
      :source_id,
      :board_id,
      :body,
      :content_hash,
      :model,
      :dimensions,
      :vector
    ])
    |> validate_inclusion(:kind, @kinds)
    |> check_constraint(:card_id,
      name: :search_embeddings_card_xor_page,
      message: "must belong to exactly one of a card or a page"
    )
    |> unique_constraint([:kind, :source_id, :section])
  end
end
