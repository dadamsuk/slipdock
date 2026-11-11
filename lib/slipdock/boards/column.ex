defmodule Slipdock.Boards.Column do
  use Ecto.Schema
  import Ecto.Changeset

  alias Slipdock.Dates

  # What being in a list means for a card. Nil is "no particular meaning".
  @categories [
    {"", "No category"},
    {"todo", "To do"},
    {"doing", "In progress"},
    {"done", "Done"},
    {"dropped", "Dropped"},
    # Filed for a person to look at (#1793): no ready list, feed or rule's
    # runner action takes work from it.
    {"triage", "Triage"},
    # Where recurring agent work lands (#2100): worked by feed rules, never
    # the ready list a person or an agent asked "what next" takes from.
    {"scheduled", "Scheduled"},
    # Where generated fixes and investigations wait (#2777): worked by
    # backfill feeds only while the ready list and Scheduled have nothing
    # their pool could start.
    {"housekeeping", "Housekeeping"}
  ]

  schema "columns" do
    field :name, :string
    field :position, :integer, default: 0
    field :wip_limit, :integer
    field :color, :string
    field :category, :string
    # A horizon: the date range the list stands for, and the precision a
    # card dropped into it is scheduled at.
    field :horizon_from, :date
    field :horizon_to, :date
    field :horizon_unit, :string
    # How the list draws its cards (see `Slipdock.ListOrder`): nil sort is
    # the order they were dragged into, nil group is one run of cards.
    field :sort_by, :string
    field :sort_dir, :string, default: "asc"
    field :group_by, :string
    # Whether its cards show their time in the list (the age chip).
    field :show_age, :boolean, default: true
    # Whether its cards show their image on the front (#1664).
    field :show_images, :boolean, default: true

    belongs_to :board, Slipdock.Boards.Board
    has_many :cards, Slipdock.Boards.Card, preload_order: [asc: :position]

    # Wiki pages placed in this list (see `Slipdock.Wiki.place/3`), set when the
    # board is loaded through `Slipdock.Boards.get_board!/1`. They share the
    # cards' position sequence, so the two interleave.
    field :pages, {:array, :map}, virtual: true, default: []
    # Its snoozed cards (W-1803), kept out of `cards` by
    # `Slipdock.Boards.get_board!/1` and set here, in list order, for the
    # list's "N snoozed" footer to reveal.
    field :snoozed, {:array, :map}, virtual: true, default: []

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories
  def category_keys, do: @categories |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))

  def done?(%__MODULE__{category: "done"}), do: true
  def done?(_), do: false

  def dropped?(%__MODULE__{category: "dropped"}), do: true
  def dropped?(_), do: false

  def triage?(%__MODULE__{category: "triage"}), do: true
  def triage?(_), do: false

  def scheduled?(%__MODULE__{category: "scheduled"}), do: true
  def scheduled?(_), do: false

  def housekeeping?(%__MODULE__{category: "housekeeping"}), do: true
  def housekeeping?(_), do: false

  @doc """
  The category a new list called `name` takes when it is given none: a list
  called *Housekeeping* is the Housekeeping list (#2777), as the sweep's
  *Triage* is its Triage list.
  """
  def default_category(name) when is_binary(name) do
    if String.downcase(String.trim(name)) == "housekeeping", do: "housekeeping"
  end

  def default_category(_), do: nil

  @doc "Whether the list stands for a date range."
  def horizon?(%__MODULE__{horizon_from: from, horizon_to: to}),
    do: not (is_nil(from) and is_nil(to))

  @doc "A short name for the list's horizon, or nil."
  def horizon_label(%__MODULE__{horizon_from: from, horizon_to: to, horizon_unit: unit}) do
    cond do
      from && to -> Dates.range_label(from, to, unit || "day")
      from -> "from #{Calendar.strftime(from, "%-d %b %Y")}"
      to -> "until #{Calendar.strftime(to, "%-d %b %Y")}"
      true -> nil
    end
  end

  @doc "Whether a card's (effective) due date falls outside the list's horizon."
  def drifted?(%__MODULE__{} = column, %Date{} = due),
    do: horizon?(column) and not Dates.within?(due, column.horizon_from, column.horizon_to)

  def drifted?(_, _), do: false

  def changeset(column, attrs) do
    column
    |> cast(attrs, [
      :name,
      :position,
      :wip_limit,
      :color,
      :board_id,
      :category,
      :horizon_from,
      :horizon_to,
      :horizon_unit,
      :sort_by,
      :sort_dir,
      :group_by,
      :show_age,
      :show_images
    ])
    |> validate_required([:name, :board_id])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_number(:wip_limit, greater_than: 0)
    |> validate_inclusion(:color, [nil | Slipdock.Palette.names()])
    |> update_change(:category, &blank_to_nil/1)
    |> update_change(:horizon_unit, &blank_to_nil/1)
    |> validate_inclusion(:category, [nil | category_keys()])
    |> validate_inclusion(:horizon_unit, [nil | Dates.precision_keys()])
    |> validate_horizon()
    |> update_change(:sort_by, &manual_to_nil/1)
    |> update_change(:group_by, &none_to_nil/1)
    |> update_change(:sort_dir, &(blank_to_nil(&1) || "asc"))
    |> validate_inclusion(:sort_by, [nil | Slipdock.ListOrder.sort_keys()])
    |> validate_inclusion(:sort_dir, Slipdock.ListOrder.dir_keys())
    |> validate_inclusion(:group_by, [nil | Slipdock.ListOrder.group_keys()])
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # "position" is what the views call board order; both it and blank mean
  # the order the cards were dragged into.
  defp manual_to_nil("position"), do: nil
  defp manual_to_nil(v), do: blank_to_nil(v)

  defp none_to_nil("none"), do: nil
  defp none_to_nil(v), do: blank_to_nil(v)

  defp validate_horizon(changeset) do
    from = get_field(changeset, :horizon_from)
    to = get_field(changeset, :horizon_to)

    if from && to && Date.compare(from, to) == :gt,
      do: add_error(changeset, :horizon_from, "must be on or before the horizon end"),
      else: changeset
  end
end
