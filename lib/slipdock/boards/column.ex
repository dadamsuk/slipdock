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
    {"dropped", "Dropped"}
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

    belongs_to :board, Slipdock.Boards.Board
    has_many :cards, Slipdock.Boards.Card, preload_order: [asc: :position]

    # Wiki pages placed in this list (see `Slipdock.Wiki.place/3`), set when the
    # board is loaded through `Slipdock.Boards.get_board!/1`. They share the
    # cards' position sequence, so the two interleave.
    field :pages, {:array, :map}, virtual: true, default: []

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories
  def category_keys, do: @categories |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))

  def done?(%__MODULE__{category: "done"}), do: true
  def done?(_), do: false

  def dropped?(%__MODULE__{category: "dropped"}), do: true
  def dropped?(_), do: false

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
      :horizon_unit
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
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp validate_horizon(changeset) do
    from = get_field(changeset, :horizon_from)
    to = get_field(changeset, :horizon_to)

    if from && to && Date.compare(from, to) == :gt,
      do: add_error(changeset, :horizon_from, "must be on or before the horizon end"),
      else: changeset
  end
end
