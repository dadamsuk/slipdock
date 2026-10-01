defmodule Slipdock.Wiki.Page do
  @moduledoc """
  One wiki page: a Markdown document belonging to a board, sitting in a tree
  of pages independent of the board's cards.

  Three ways to name a page, and they are not interchangeable:

    * `id` — the row. What the API returns.
    * `code` — "W-31", a per-board sequence made globally unique. Stable
      across renames and re-slugs, so it is what belongs in a commit message
      or a chat.
    * `slug` — taken from the title and editable. What the URL reads as, and
      what changes when the page is renamed.

  `content_hash` is the sha256 of the body as last saved. A write that sends
  the hash it was based on gets a conflict rather than a silent overwrite
  when someone else has written in between (see `Slipdock.Wiki.update_page/3`).

  A page can also be **placed on the board**: `column_id` puts it in a list
  and `board_position` orders it among that list's cards, so a spec can sit
  in "In Progress" beside the work it describes and be dragged about like a
  card. It is a second, optional axis — the page keeps its place in the wiki
  tree either way, and most pages are never placed.

  ## Card facets

  A page carries the card's **facets** — priority, flags, dates, assignee,
  completion, percent, cover colour — because those are what the board views
  group, filter, sort and colour by, and a document being written has all of
  them: a spec can be blocked, a retro can be due Friday, a runbook can be
  somebody's.

  ## Card contents

  It carries most of the card's **contents** too: comments, status updates, a
  checklist, votes, web links and custom field values. Each of those tables
  hangs off exactly one of a card or a page (see `Slipdock.Boards.Owned`), so
  there is one comment table and one way to write a comment, not two.

  What stays card-only is the work-shaped pair: blocking **dependencies** and
  typed **card links**, both of which are card-to-card joins carrying
  scheduling meaning, and **subcards**. A page already has a richer way of
  pointing at things — `[[wikilinks]]`, backlinks and pins, which say what a
  document is *about* — and child pages, which is what a page's subtree is
  for. The virtual fields below stand in for those as empties, so the view
  code that reads a card can read a page without knowing the difference.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.Boards.Board

  @statuses ~w(draft published)
  @title_length 200
  @slug_length 120

  schema "pages" do
    field :title, :string
    field :slug, :string
    field :code, :string
    field :number, :integer
    field :body, :string, default: ""
    field :summary, :string
    # Where it sits among its siblings in the wiki tree.
    field :position, :integer, default: 0
    # Where it sits among the cards of `column_id`, when it is on the board.
    field :board_position, :integer, default: 0
    field :status, :string, default: "published"
    field :template, :boolean, default: false

    # The card facets. Same names and same vocabularies as `Slipdock.Boards.Card`
    # on purpose: the board views read them without caring which they have.
    field :priority, :string, default: "none"
    field :flags, {:array, :string}, default: []
    field :start_date, :date
    field :due_date, :date
    field :date_precision, :string, default: "day"
    field :completed, :boolean, default: false
    field :percent_complete, :integer
    field :color, :string
    field :public_token, :string
    # The answers this page's live queries gave when it was published. An
    # anonymous reader gets those rather than fresh ones (see
    # `Slipdock.Wiki.publish/2`).
    field :frozen, :map
    field :published_at, :utc_datetime
    field :content_hash, :string
    field :archived_at, :utc_datetime

    belongs_to :board, Board
    belongs_to :column, Slipdock.Boards.Column
    belongs_to :assignee, Slipdock.Accounts.User
    belongs_to :parent, __MODULE__
    # Where the page is filed, as opposed to what it is part of (see
    # `Slipdock.Wiki.Folder`). Both are optional and neither implies the other.
    belongs_to :folder, Slipdock.Wiki.Folder
    belongs_to :created_by, Slipdock.Accounts.User
    belongs_to :updated_by, Slipdock.Accounts.User

    # Tags are the board's own (shared across its tree), so a page and a card
    # can carry the same one and mean the same thing by it.
    many_to_many :tags, Slipdock.Boards.Tag,
      join_through: "page_tags",
      on_replace: :delete,
      preload_order: [asc: :name]

    has_many :attachments, Slipdock.Boards.Attachment,
      preload_order: [asc: :inserted_at, asc: :id]

    has_many :links, Slipdock.Wiki.Link, preload_order: [desc: :count]
    has_many :children, __MODULE__, foreign_key: :parent_id, preload_order: [asc: :position]
    has_many :revisions, Slipdock.Wiki.Revision, preload_order: [desc: :inserted_at]

    # The card contents a page carries. Same tables, same names, same
    # preload order as `Slipdock.Boards.Card` — which is what lets one
    # component draw either.
    has_many :checklist_items, Slipdock.Boards.ChecklistItem, preload_order: [asc: :position]
    has_many :comments, Slipdock.Boards.Comment, preload_order: [desc: :inserted_at]
    has_many :urls, Slipdock.Boards.CardUrl, preload_order: [asc: :inserted_at, asc: :id]

    has_many :status_updates, Slipdock.Boards.StatusUpdate,
      preload_order: [desc: :inserted_at, desc: :id]

    has_many :field_values, Slipdock.Boards.FieldValue
    has_many :votes, Slipdock.Boards.Vote

    # What a page does not have, as a card would: the card-to-card joins and
    # the subcard board. These are always empty, and exist so the board's
    # views and components can read a page the way they read a card instead
    # of asking which it is at every turn.
    # A card's one-line description is a page's summary. The views read
    # `description`, so `for_board/1` fills it in from the summary rather
    # than making every view ask which it is holding.
    field :description, :string, virtual: true
    field :rollup, :map, virtual: true
    field :computed, :map, virtual: true, default: %{}
    field :scores, :map, virtual: true, default: %{}
    field :blocked_by, {:array, :map}, virtual: true, default: []
    field :blocks, {:array, :map}, virtual: true, default: []
    field :links_out, {:array, :map}, virtual: true, default: []
    field :links_in, {:array, :map}, virtual: true, default: []
    field :sub_board, :map, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc "The priorities a page may take — the card's, so the views agree."
  defdelegate priorities, to: Slipdock.Boards.Card

  @doc "The flags a page may raise — the card's, so the views agree."
  defdelegate flags, to: Slipdock.Boards.Card

  @doc """
  A page dressed for the board's views: its summary standing in as the
  description the views read.

  Everything else already lines up — the facets share the card's names and
  vocabularies, and what a page has not got is a virtual empty.
  """
  def for_board(%__MODULE__{} = page), do: %{page | description: page.summary}

  @doc "The card facets a page carries, as attribute names."
  def facet_fields,
    do:
      ~w(priority flags start_date due_date date_precision completed percent_complete color assignee_id)a

  def statuses, do: @statuses
  def title_length, do: @title_length
  def slug_length, do: @slug_length

  @doc "Whether the page has been put away."
  def archived?(%__MODULE__{archived_at: at}), do: not is_nil(at)

  @doc "Whether the page is on the board as well as in the wiki."
  def placed?(%__MODULE__{column_id: id}), do: not is_nil(id)

  @doc "Whether anyone with the link can read this page."
  def published?(%__MODULE__{public_token: token}), do: not is_nil(token)

  @doc "Whether the page is still a draft (visible to writers only)."
  def draft?(%__MODULE__{status: status}), do: status == "draft"

  @doc "The sha256 of a body, hex encoded — the concurrency token."
  def hash(body) do
    :sha256 |> :crypto.hash(body || "") |> Base.encode16(case: :lower)
  end

  @doc """
  The code a page with this number gets: `W-` and the number.

  The prefix mirrors how `#412` names a card — short enough to say out loud,
  and the letter keeps the two apart when both appear in the same sentence.
  """
  def code_for(number) when is_integer(number), do: "W-#{number}"

  @doc "Whether `ref` looks like a page code (`W-31`, case-insensitive)."
  def code?(ref) when is_binary(ref), do: Regex.match?(~r/^w-\d+$/i, String.trim(ref))
  def code?(_), do: false

  @doc "Puts a code into its canonical shape, so `w-31` finds `W-31`."
  def normalize_code(ref), do: ref |> to_string() |> String.trim() |> String.upcase()

  @doc """
  A slug for a page titled `title`: lower case, words joined by hyphens, cut
  to #{@slug_length} characters — "Retry policy" becomes "retry-policy".

  `taken` says which slugs are already used on the board, either as an
  enumerable or as a function taking a slug and returning true when it is
  taken; a clash gets a number appended.
  """
  def slug_from_title(title, taken \\ []) do
    taken? = if is_function(taken, 1), do: taken, else: &MapSet.member?(MapSet.new(taken), &1)

    base =
      case title |> sanitize_slug() |> String.slice(0, @slug_length) |> String.trim("-") do
        "" -> "page"
        slug -> slug
      end

    if taken?.(base) do
      Enum.find_value(2..9999, fn n ->
        candidate = "#{base}-#{n}"
        if taken?.(candidate), do: nil, else: candidate
      end)
    else
      base
    end
  end

  @doc """
  Turns anything into the shape a slug has to take. The same transformation
  a board code gets — lower case, runs of anything else collapsed to one
  hyphen, accents dropped — but without the ten-character limit, because a
  page title is a sentence where a board name is a label.
  """
  def sanitize_slug(value), do: Board.sanitize_code(value)

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :title,
      :slug,
      :body,
      :summary,
      :status,
      :template,
      :position,
      :parent_id,
      :folder_id,
      :priority,
      :flags,
      :start_date,
      :due_date,
      :date_precision,
      :completed,
      :percent_complete,
      :color,
      :assignee_id
    ])
    |> update_change(:title, &String.trim/1)
    |> update_change(:slug, &sanitize_slug/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: @title_length)
    |> validate_length(:slug, min: 1, max: @slug_length)
    |> validate_length(:summary, max: 300)
    |> validate_inclusion(:status, @statuses)
    |> validate_facets()
    |> put_hash()
    |> unique_constraint([:board_id, :slug],
      error_key: :slug,
      message: "is already used by another page on this board"
    )
    |> unique_constraint(:code)
  end

  # The facets are the card's, so they are checked the card's way — the same
  # vocabularies, the same date rules, the same snapping to whole buckets at a
  # coarse precision. A page and a card scheduled to the same quarter have to
  # land in the same bucket, or a timeline shows them in different columns.
  defp validate_facets(changeset) do
    changeset
    |> validate_inclusion(:priority, Slipdock.Boards.Card.priorities())
    |> validate_subset(:flags, Slipdock.Boards.Card.flags())
    |> update_change(:date_precision, fn
      "" -> "day"
      p -> p
    end)
    |> validate_inclusion(:date_precision, Slipdock.Dates.precision_keys())
    |> validate_dates()
    |> snap_dates()
    |> update_change(:color, fn
      "" -> nil
      c -> c
    end)
    |> validate_inclusion(:color, [nil | Slipdock.Palette.names()])
    |> validate_number(:percent_complete,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
  end

  defp validate_dates(changeset) do
    start = get_field(changeset, :start_date)
    due = get_field(changeset, :due_date)

    if start && due && Date.compare(start, due) == :gt,
      do: add_error(changeset, :start_date, "must be on or before the due date"),
      else: changeset
  end

  defp snap_dates(%{valid?: false} = changeset), do: changeset

  defp snap_dates(changeset) do
    precision = get_field(changeset, :date_precision) || "day"

    if precision == "day" do
      changeset
    else
      changeset
      |> snap(:start_date, &Slipdock.Dates.bucket_start(&1, precision))
      |> snap(:due_date, &Slipdock.Dates.bucket_end(&1, precision))
    end
  end

  defp snap(changeset, field, fun) do
    case get_field(changeset, field) do
      %Date{} = d ->
        snapped = fun.(d)
        if snapped == d, do: changeset, else: put_change(changeset, field, snapped)

      _ ->
        changeset
    end
  end

  # The hash travels with the body so a row and its token can never disagree.
  defp put_hash(changeset) do
    case fetch_change(changeset, :body) do
      {:ok, body} -> put_change(changeset, :content_hash, hash(body))
      :error -> changeset
    end
  end
end
