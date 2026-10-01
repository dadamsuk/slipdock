defmodule Slipdock.Accounts.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :name, :string
    belongs_to :owner, Slipdock.Accounts.User

    many_to_many :members, Slipdock.Accounts.User,
      join_through: "group_members",
      on_replace: :delete,
      preload_order: [asc: :email]

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :owner_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint([:owner_id, :name],
      error_key: :name,
      message: "you already have a group with that name"
    )
  end
end
