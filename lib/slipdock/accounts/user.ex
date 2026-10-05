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
    # What makes an account not free: a date in the future here means somebody
    # has paid, which lifts both the free tier's allowance and the trial clock
    # (see `Slipdock.Quota`). Until there is a billing system, an admin sets it.
    field :paid_until, :utc_datetime
    # Off the free tier with no date attached: for somebody named by an admin
    # rather than somebody who paid. The guardrails still apply.
    field :unlimited, :boolean, default: false
    # Set when this account exists because somebody shared something with the
    # address, rather than because its owner asked for one.
    field :invited_at, :utc_datetime
    field :terms_accepted_at, :utc_datetime
    field :terms_version, :string
    belongs_to :invited_by, Slipdock.Accounts.User
    has_many :groups_owned, Slipdock.Accounts.Group, foreign_key: :owner_id
    many_to_many :groups, Slipdock.Accounts.Group, join_through: "group_members"
    timestamps(type: :utc_datetime)
  end

  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> update_change(:email, &Slipdock.Email.normalize/1)
    |> validate_required([:email])
    |> Slipdock.Email.validate(:email)
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
  The admin's view of somebody: whether they may administer this server, what
  their own card limit is, how long they have paid up to, and whether they are
  off the free tier altogether. Separate from
  `profile_changeset/2` because nobody may promote themselves by posting their
  own profile form.
  """
  def standing_changeset(user, attrs) do
    user
    |> cast(normalise_paid_until(attrs), [:admin, :card_limit_override, :paid_until, :unlimited])
    |> validate_number(:card_limit_override, greater_than: 0)
  end

  # A bare date is what anybody types for "paid up to the end of November", and
  # an admin form, the CLI and a PATCH all send strings. Read it as the start of
  # that day in UTC rather than refusing it as a bad datetime.
  defp normalise_paid_until(attrs) do
    with value when is_binary(value) <- attrs["paid_until"],
         {:ok, date} <- Date.from_iso8601(value) do
      Map.put(attrs, "paid_until", DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))
    else
      _ -> attrs
    end
  end

  @doc "A short label for showing who someone is."
  # nil is somebody whose account has been deleted since — a support session's
  # admin, say, kept on the record with the person nulled.
  def display_name(nil), do: "a deleted account"
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
