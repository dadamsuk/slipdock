defmodule Slipdock.Vaults.Vault do
  @moduledoc """
  A vault: one logical Obsidian-style vault, owned by one person, made of
  board wikis.

  It holds no pages of its own. What it holds is its **mappings** (see
  `Slipdock.Vaults.Mapping`), which say which vault path lands in which
  board's wiki — and, by naming the boards that belong together, how a plain
  `[[link]]` on one of them is resolved (W-103, R1 and R4).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name_length 80

  schema "vaults" do
    field :name, :string

    belongs_to :user, Slipdock.Accounts.User
    has_many :mappings, Slipdock.Vaults.Mapping, preload_order: [asc: :path]
    has_many :mirrors, Slipdock.Vaults.Mirror, preload_order: [desc: :last_synced_at]

    timestamps(type: :utc_datetime)
  end

  def name_length, do: @name_length

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @name_length)
    |> validate_format(:name, ~r/^[^\/]+$/, message: "cannot contain a slash")
    |> unique_constraint(:name,
      name: :vaults_user_id_name_index,
      message: "you already have a vault with that name"
    )
  end
end
