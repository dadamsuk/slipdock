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
    # Where on its owner's Google Drive the vault's meeting recordings are
    # (W-1690): a path from My Drive's root. Only files under it are served.
    field :recordings_folder, :string
    # Where its owner has put it among their boards on the home page, in the
    # same numbering as their board orders (see `Slipdock.Boards.reorder_boards/2`);
    # nil until it has been placed.
    field :position, :integer
    # Filled in for the home page, so `Slipdock.Boards.sort_boards/2` can
    # sort vaults among the boards: the last thing that happened on the
    # boards it keeps inside it or the last sync, and those boards' cards.
    field :last_activity_at, :utc_datetime, virtual: true
    field :card_count, :integer, virtual: true, default: 0

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
