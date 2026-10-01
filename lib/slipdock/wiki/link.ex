defmodule Slipdock.Wiki.Link do
  @moduledoc """
  One reference written somewhere, as a row.

  The **source** is a page, a comment or a status update — writing people do
  on cards *and on other pages* is writing too, so a comment pointing at a
  runbook belongs in that runbook's backlinks. Exactly one source is set, and
  the database enforces it. `source_card_id` and `source_page_id` are carried
  alongside a comment or status source so a backlink can name what it was
  written on without a join.

  These are **derived**: `Slipdock.Wiki.Links.reconcile/1` rebuilds them from
  the text on every save, so nothing should ever be the only copy of itself
  here. The exception is `pinned` — "this page is *the* spec for that card"
  is a person's judgement, not something the prose says, so it is carried
  across a rebuild.

  A row with `resolved: false` is a `[[wanted page]]`: something written
  before anyone wrote the page. Those are the wiki's own backlog, and the
  classic way a wiki grows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(page card board view external)

  schema "page_links" do
    field :kind, :string
    field :raw, :string
    field :label, :string
    field :resolved, :boolean, default: false
    field :pinned, :boolean, default: false
    field :count, :integer, default: 1

    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :source_comment, Slipdock.Boards.Comment
    belongs_to :source_status, Slipdock.Boards.StatusUpdate
    belongs_to :source_card, Slipdock.Boards.Card
    belongs_to :source_page, Slipdock.Wiki.Page
    belongs_to :target_page, Slipdock.Wiki.Page
    belongs_to :target_card, Slipdock.Boards.Card
    belongs_to :target_board, Slipdock.Boards.Board
    belongs_to :target_view, Slipdock.Boards.SavedView

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :kind,
      :raw,
      :label,
      :resolved,
      :pinned,
      :count,
      :page_id,
      :source_comment_id,
      :source_status_id,
      :source_card_id,
      :source_page_id,
      :target_page_id,
      :target_card_id,
      :target_board_id,
      :target_view_id
    ])
    |> validate_required([:kind, :raw])
    |> validate_inclusion(:kind, @kinds)
    |> validate_one_source()
  end

  defp validate_one_source(changeset) do
    fields = [:page_id, :source_comment_id, :source_status_id]
    set = Enum.count(fields, &(not is_nil(get_field(changeset, &1))))

    if set == 1,
      do: changeset,
      else: add_error(changeset, :page_id, "exactly one source must be set")
  end

  @doc """
  The page this link was written on: its body, or a comment or status update
  left on it. Nil when it was written on a card instead.
  """
  def written_on(%__MODULE__{page: %Slipdock.Wiki.Page{} = page}), do: page
  def written_on(%__MODULE__{source_page: %Slipdock.Wiki.Page{} = page}), do: page
  def written_on(%__MODULE__{}), do: nil

  @doc "Where this link was written."
  def source(%__MODULE__{page_id: id}) when not is_nil(id), do: :page
  def source(%__MODULE__{source_comment_id: id}) when not is_nil(id), do: :comment
  def source(%__MODULE__{}), do: :status

  @doc "The id this link points at, whatever kind it is, or nil when unresolved."
  def target_id(%__MODULE__{kind: "page", target_page_id: id}), do: id
  def target_id(%__MODULE__{kind: "card", target_card_id: id}), do: id
  def target_id(%__MODULE__{kind: "board", target_board_id: id}), do: id
  def target_id(%__MODULE__{kind: "view", target_view_id: id}), do: id
  def target_id(%__MODULE__{}), do: nil
end
