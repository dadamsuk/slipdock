defmodule Slipdock.Wiki.Revision do
  @moduledoc """
  One saved state of a page: a full snapshot of its title and body, not a
  diff. Bodies are kilobytes, and a diff is cheap to compute from two
  snapshots but expensive to get wrong in storage.

  `summary` is the edit's own message — why it was made, not what changed,
  which the diff already says. `via` and `agent` say who made it: `"web"`
  for the editor, `"api"` or `"cli"` for a token (with the token's name in
  `agent`), `"assistant"` for the in-app model, `"automation"` for a rule.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @vias ~w(web api cli assistant automation)

  schema "page_revisions" do
    field :title, :string
    field :body, :string, default: ""
    field :summary, :string
    field :via, :string
    field :agent, :string
    field :byte_size, :integer, default: 0

    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :author, Slipdock.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def vias, do: @vias

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:title, :body, :summary, :via, :agent, :page_id, :author_id])
    |> validate_required([:title, :page_id])
    |> validate_inclusion(:via, @vias)
    |> validate_length(:summary, max: 300)
    |> put_byte_size()
  end

  defp put_byte_size(changeset) do
    body = get_field(changeset, :body) || ""
    put_change(changeset, :byte_size, byte_size(body))
  end
end
