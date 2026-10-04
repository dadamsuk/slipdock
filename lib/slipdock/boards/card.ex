defmodule Slipdock.Boards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  @priorities ~w(none low medium high critical)
  @flags ~w(flagged blocked review waiting starred)

  # The readers below match on *shape* rather than on `%Card{}`, because a
  # wiki page placed on the board carries the same facets under the same names
  # (see `Slipdock.Wiki.Page`) and the views should not have to ask which they
  # are holding. Everything that *writes* still takes a card and nothing else.

  schema "cards" do
    field :title, :string
    field :description, :string
    field :position, :integer, default: 0
    field :priority, :string, default: "none"
    field :flags, {:array, :string}, default: []
    field :start_date, :date
    field :due_date, :date
    # How precisely the card is scheduled (see Slipdock.Dates); dates are
    # snapped to whole buckets at any precision but "day".
    field :date_precision, :string, default: "day"
    field :completed, :boolean, default: false
    # When it was last completed; nil while it is open. Set by `changeset/2`
    # whenever `completed` changes, and what a sprint's burndown reads.
    field :completed_at, :utc_datetime
    # How far through the work is, 0–100, as stated by whoever is doing it;
    # nil when nobody has said. Independent of `completed`.
    field :percent_complete, :integer
    # Time tracking (see Slipdock.TimeTracking): spent and estimate in whole
    # minutes, shown in `time_unit`; a running timer is when it started.
    field :time_spent, :integer
    field :time_estimate, :integer
    field :time_unit, :string, default: "hours"
    field :timer_started_at, :utc_datetime
    field :color, :string
    field :archived_at, :utc_datetime

    # Set by Slipdock.Rollup when the card is loaded through Slipdock.Boards:
    # progress, effective dates and health rolled up from its subcards.
    field :rollup, :map, virtual: true
    # Formula field results, set by Slipdock.Fields.decorate/2: `computed` is
    # keyed by field id, `scores` by field key.
    field :computed, :map, virtual: true, default: %{}
    field :scores, :map, virtual: true, default: %{}
    # Whether the card is a document — a file and nothing else (see
    # Slipdock.Kinds). nil means nobody has said, and a card loaded with its
    # attachments is asked directly; the rollup's light cards set it because
    # they have none.
    field :document, :boolean, virtual: true

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :column, Slipdock.Boards.Column
    # A card can be assigned to several people: `assignees` is all of them,
    # `assignee` the lead — the first — kept in step by Slipdock.Boards so the
    # views that colour or sort by one person still have one.
    belongs_to :assignee, Slipdock.Accounts.User

    many_to_many :assignees, Slipdock.Accounts.User,
      join_through: "card_assignees",
      join_keys: [card_id: :id, user_id: :id],
      on_replace: :delete,
      preload_order: [asc: :name, asc: :email]

    many_to_many :tags, Slipdock.Boards.Tag,
      join_through: "card_tags",
      on_replace: :delete,
      preload_order: [asc: :name]

    # Dependencies: a card is blocked by the cards in `blocked_by` and blocks
    # the cards in `blocks`. Both sides are rows in card_dependencies.
    many_to_many :blocked_by, Slipdock.Boards.Card,
      join_through: "card_dependencies",
      join_keys: [blocked_id: :id, blocker_id: :id],
      preload_order: [asc: :title]

    many_to_many :blocks, Slipdock.Boards.Card,
      join_through: "card_dependencies",
      join_keys: [blocker_id: :id, blocked_id: :id],
      preload_order: [asc: :title]

    # A stand-in: the card sprint planning leaves in the slot a card it pulled
    # in used to hold (see Slipdock.Sprints.add_cards/2). It has no state of
    # its own — what it shows is read live from the card it points at — and
    # nil when the real card has since been deleted, which is why there is no
    # foreign key behind it.
    belongs_to :stand_in_for, __MODULE__

    # Subcards live on a board owned by this card.
    has_one :sub_board, Slipdock.Boards.Board, foreign_key: :parent_card_id

    has_many :checklist_items, Slipdock.Boards.ChecklistItem, preload_order: [asc: :position]
    has_many :comments, Slipdock.Boards.Comment, preload_order: [desc: :inserted_at]

    has_many :attachments, Slipdock.Boards.Attachment,
      preload_order: [asc: :inserted_at, asc: :id]

    # Links out of the system: web pages, shared drives, files elsewhere.
    has_many :urls, Slipdock.Boards.CardUrl, preload_order: [asc: :inserted_at, asc: :id]

    has_many :status_updates, Slipdock.Boards.StatusUpdate,
      preload_order: [desc: :inserted_at, desc: :id]

    has_many :field_values, Slipdock.Boards.FieldValue
    has_many :votes, Slipdock.Boards.Vote
    # Typed links (see Slipdock.Boards.CardLink), both directions.
    has_many :links_out, Slipdock.Boards.CardLink, foreign_key: :from_id
    has_many :links_in, Slipdock.Boards.CardLink, foreign_key: :to_id

    timestamps(type: :utc_datetime)
  end

  def priorities, do: @priorities

  @doc "Whether the card is a stand-in for a card sprint planning took away."
  def stand_in?(%{stand_in_for_id: id}) when not is_nil(id), do: true
  def stand_in?(_), do: false

  @doc """
  Everybody the card is assigned to, lead first. Falls back to the lead alone
  when the set isn't loaded, and to nobody when neither is.
  """
  def assignees(%{assignees: people} = item) when is_list(people) do
    case Map.get(item, :assignee_id) do
      nil -> people
      id -> Enum.sort_by(people, &(&1.id != id))
    end
  end

  def assignees(%{assignee: %Slipdock.Accounts.User{} = user}), do: [user]
  def assignees(_), do: []

  @doc "Whether `user_id` is one of the people the card is assigned to."
  def assigned_to?(item, user_id) do
    Map.get(item, :assignee_id) == user_id or Enum.any?(assignees(item), &(&1.id == user_id))
  end

  def flags, do: @flags

  @doc "The latest stated health (\"on_track\", \"at_risk\", \"off_track\") or nil."
  def stated_health(%{status_updates: [%{health: h} | _]}), do: h
  def stated_health(%{rollup: %{stated: h}}), do: h
  def stated_health(_), do: nil

  @doc "The goal cards this card contributes to (link stubs), when links are loaded."
  def goals(%{links_out: links}) when is_list(links),
    do: for(%{kind: "contributes", to: %__MODULE__{} = goal} <- links, do: goal)

  def goals(_), do: []

  @doc "The cards contributing to this one, when links are loaded."
  def contributions(%{links_in: links}) when is_list(links),
    do: for(%{kind: "contributes", from: %__MODULE__{} = card} <- links, do: card)

  def contributions(_), do: []

  @doc "Votes on the card, all people together (0 when votes aren't loaded)."
  def vote_total(%{votes: votes}) when is_list(votes),
    do: votes |> Enum.map(& &1.count) |> Enum.sum()

  def vote_total(_), do: 0

  @doc "Whether the card is scheduled more coarsely than to the day."
  def fuzzy?(%{date_precision: p}), do: p not in [nil, "day"]
  def fuzzy?(_), do: false

  @doc "Whether an unfinished, unarchived card still blocks this one."
  def blocked?(%{blocked_by: blockers}) when is_list(blockers) do
    Enum.any?(blockers, &(not &1.completed and is_nil(&1.archived_at)))
  end

  def blocked?(_), do: false

  @doc "Progress of the subcards as `{done, total}` (active cards only), or nil without a sub-board."
  def subcard_progress(%{sub_board: %{cards: cards}}) when is_list(cards) do
    active = Enum.reject(cards, &(not is_nil(&1.archived_at)))
    {Enum.count(active, & &1.completed), length(active)}
  end

  def subcard_progress(_), do: nil

  @doc """
  Progress as `{done, total}` counting every leaf beneath the card (from the
  rollup), else the direct subcards, else nil.
  """
  def progress(%{rollup: %{total: total, done: done, children: n}}) when n > 0,
    do: {done, total}

  def progress(item), do: subcard_progress(item)

  @doc "The rolled-up health: `:done`, `:blocked`, `:late` or `:ok` (nil without a rollup)."
  def health(%{rollup: %{health: health}}), do: health
  def health(_), do: nil

  @doc "The card's own start date, else the one rolled up from its subcards."
  def effective_start(%{rollup: %{start: %Date{} = d}}), do: d
  def effective_start(%{start_date: d}), do: d
  def effective_start(_), do: nil

  @doc "The card's own due date, else the one rolled up from its subcards."
  def effective_due(%{rollup: %{due: %Date{} = d}}), do: d
  def effective_due(%{due_date: d}), do: d
  def effective_due(_), do: nil

  def start_derived?(%{rollup: %{start_derived?: v}}), do: v
  def start_derived?(_), do: false
  def due_derived?(%{rollup: %{due_derived?: v}}), do: v
  def due_derived?(_), do: false

  @doc "Days the subcards begin after this card's own start date (0 if none)."
  def start_slip(%{rollup: %{start_slip: n}}), do: n
  def start_slip(_), do: 0

  @doc "Days the subcards end after this card's own due date (0 if none)."
  def due_slip(%{rollup: %{due_slip: n}}), do: n
  def due_slip(_), do: 0

  @doc """
  Days this card is itself past its own due date, today. Nothing to do with
  the subcards — a card can be past its due date with every subcard still
  ahead of schedule, and the two numbers are reported separately for exactly
  that reason.
  """
  def days_past_due(card, today \\ Date.utc_today())

  def days_past_due(%{due_date: %Date{} = due, completed: false}, today) do
    if Date.compare(today, due) == :gt, do: Date.diff(today, due), else: 0
  end

  def days_past_due(_, _), do: 0

  @doc "The blockers that are still open."
  def open_blockers(%{blocked_by: blockers}) when is_list(blockers) do
    Enum.filter(blockers, &(not &1.completed and is_nil(&1.archived_at)))
  end

  def open_blockers(_), do: []

  @doc """
  Open blockers scheduled to finish after this card is due to start: the
  plan contradicts the dependency. Uses the blockers' own dates.
  """
  def violated_blockers(card) do
    case effective_start(card) || effective_due(card) do
      nil ->
        []

      starts ->
        Enum.filter(open_blockers(card), fn b ->
          case Map.get(b, :due_date) || Map.get(b, :start_date) do
            %Date{} = ends -> Date.compare(ends, starts) == :gt
            _ -> false
          end
        end)
    end
  end

  @doc "The first day a card occupies: its start date, else its due date."
  def starts_on(%{start_date: %Date{} = d}), do: d
  def starts_on(%{due_date: d}), do: d
  def starts_on(_), do: nil

  @doc "The last day a card occupies: its due date, else its start date."
  def ends_on(%{due_date: %Date{} = d}), do: d
  def ends_on(%{start_date: d}), do: d
  def ends_on(_), do: nil

  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :title,
      :description,
      :position,
      :priority,
      :flags,
      :start_date,
      :due_date,
      :date_precision,
      :completed,
      :percent_complete,
      :time_spent,
      :time_estimate,
      :time_unit,
      :color,
      :board_id,
      :column_id,
      :assignee_id
    ])
    |> validate_required([:title, :board_id, :column_id])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_inclusion(:priority, @priorities)
    |> validate_subset(:flags, @flags)
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
    |> update_change(:time_unit, fn
      "" -> "hours"
      u -> u
    end)
    |> validate_inclusion(:time_unit, Slipdock.TimeTracking.unit_keys())
    |> validate_number(:time_spent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Slipdock.TimeTracking.max_minutes()
    )
    |> validate_number(:time_estimate,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: Slipdock.TimeTracking.max_minutes()
    )
    |> stamp_completed()
  end

  defp stamp_completed(changeset) do
    case fetch_change(changeset, :completed) do
      {:ok, true} -> put_change(changeset, :completed_at, DateTime.utc_now(:second))
      {:ok, false} -> put_change(changeset, :completed_at, nil)
      :error -> changeset
    end
  end

  defp validate_dates(changeset) do
    start = get_field(changeset, :start_date)
    due = get_field(changeset, :due_date)

    if start && due && Date.compare(start, due) == :gt,
      do: add_error(changeset, :start_date, "must be on or before the due date"),
      else: changeset
  end

  # At a precision coarser than a day the card fills whole buckets: the start
  # snaps to the beginning of its bucket, the due date to the end of its.
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
end
