defmodule Slipdock.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :confirmed_at, :utc_datetime
    # Where the header's quick add (see Slipdock.QuickAdd) puts a card by
    # default, and whether the line is also read by the model.
    field :quick_add_ai, :boolean, default: true
    belongs_to :quick_add_board, Slipdock.Boards.Board
    belongs_to :quick_add_column, Slipdock.Boards.Column
    # How this person likes the board index: "grid" (cards) or "compact" (a
    # table), and the order the boards are listed in. Both are theirs alone.
    field :board_layout, :string, default: "grid"
    field :board_sort, :string, default: "manual"
    # Standing on this server. `admin` is the only role there is; `disabled_at`
    # is the reversible alternative to deleting somebody, which would orphan
    # their cards and comments; `card_limit_override` beats the instance's free
    # card limit for one person (see `Slipdock.Quota`).
    field :admin, :boolean, default: false
    field :last_signed_in_at, :utc_datetime
    field :disabled_at, :utc_datetime
    field :card_limit_override, :integer
    has_many :groups_owned, Slipdock.Accounts.Group, foreign_key: :owner_id
    many_to_many :groups, Slipdock.Accounts.Group, join_through: "group_members"
    timestamps(type: :utc_datetime)
  end

  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, max: 80)
  end

  @doc """
  The quick add defaults: the board and list a card lands in when the line
  names none, and whether the model reads the line at all. A board without
  a list of its own clears the list.
  """
  def quick_add_changeset(user, attrs) do
    user
    |> cast(attrs, [:quick_add_board_id, :quick_add_column_id, :quick_add_ai])
    |> foreign_key_constraint(:quick_add_board_id)
    |> foreign_key_constraint(:quick_add_column_id)
  end

  @layouts ~w(grid compact)
  @sorts ~w(manual name newest oldest active cards)

  @doc "The layouts the board index offers."
  def board_layouts, do: @layouts

  @doc "The orders the board index can list boards in."
  def board_sorts, do: @sorts

  @doc """
  How this person sees the board index: cards or a compact table, and the
  order the boards come in. Anything unknown is ignored rather than saved,
  so a stale link cannot leave the index in a shape that has no meaning.
  """
  def board_view_changeset(user, attrs) do
    user
    |> cast(attrs, [:board_layout, :board_sort])
    |> validate_inclusion(:board_layout, @layouts)
    |> validate_inclusion(:board_sort, @sorts)
  end

  @doc """
  The admin's view of somebody: whether they may administer this server, and
  what their own card limit is. Separate from `profile_changeset/2` because
  nobody may promote themselves by posting their own profile form.
  """
  def standing_changeset(user, attrs) do
    user
    |> cast(attrs, [:admin, :card_limit_override])
    |> validate_number(:card_limit_override, greater_than: 0)
  end

  @doc "A short label for showing who someone is."
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}), do: email

  def initials(%__MODULE__{} = user) do
    user
    |> display_name()
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1)))
  end
end
