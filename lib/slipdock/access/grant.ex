defmodule Slipdock.Access.Grant do
  @moduledoc """
  One access grant: a subject (a user or a group) gets `level` ("read" or
  "write") on a resource (a board, a card, a saved view or a wiki page).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @levels ~w(read write)

  schema "access_grants" do
    field :level, :string, default: "read"
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :group, Slipdock.Accounts.Group
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :saved_view, Slipdock.Boards.SavedView
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :granted_by, Slipdock.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def levels, do: @levels

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :level,
      :user_id,
      :group_id,
      :board_id,
      :card_id,
      :saved_view_id,
      :page_id,
      :granted_by_id
    ])
    |> validate_required([:level])
    |> validate_inclusion(:level, @levels)
    |> validate_one_of([:user_id, :group_id], "subject")
    |> validate_one_of([:board_id, :card_id, :saved_view_id, :page_id], "resource")
  end

  defp validate_one_of(changeset, fields, what) do
    set = Enum.count(fields, &(not is_nil(get_field(changeset, &1))))

    if set == 1,
      do: changeset,
      else: add_error(changeset, hd(fields), "exactly one #{what} must be set")
  end

  def subject_type(%__MODULE__{user_id: id}) when not is_nil(id), do: :user
  def subject_type(%__MODULE__{}), do: :group

  def resource_type(%__MODULE__{board_id: id}) when not is_nil(id), do: :board
  def resource_type(%__MODULE__{card_id: id}) when not is_nil(id), do: :card
  def resource_type(%__MODULE__{page_id: id}) when not is_nil(id), do: :page
  def resource_type(%__MODULE__{}), do: :view
end
