defmodule Slipdock.Vaults.Mapping do
  @moduledoc """
  One mapping of a vault: a vault-relative `path` → a board's wiki, or one
  folder within it.

      ""            → KnowledgeBase wiki (root)
      "Jobs"        → Job Hunt wiki (root)
      "Projects/X"  → board X wiki, folder "Notes"

  `path` is stored without a leading or trailing slash, so the vault's root
  is `""`; it is shown as `/`, `/Jobs`. A mapping inside another is allowed
  (`Jobs` inside `""`): the longest matching prefix wins (see
  `Slipdock.Vaults.locate/2`).

  `inside`: a board mapped whole can be kept inside the vault (#757): for
  the vault's owner it is named on the vault's tile rather than listed
  among their boards. Only a whole board, never one folder of it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "vault_mappings" do
    field :path, :string, default: ""
    field :inside, :boolean, default: false

    belongs_to :vault, Slipdock.Vaults.Vault
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :folder, Slipdock.Wiki.Folder

    timestamps(type: :utc_datetime)
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [:path, :board_id, :folder_id, :inside])
    |> validate_required([:board_id])
    |> validate_inside()
    |> validate_length(:path, max: 500)
    |> unique_constraint(:path,
      name: :vault_mappings_vault_id_path_index,
      message: "is already mapped in this vault"
    )
    |> unique_constraint(:board_id,
      name: :vault_mappings_board_root_index,
      message: "is already mapped into a vault"
    )
    |> unique_constraint(:folder_id,
      name: :vault_mappings_folder_index,
      message: "is already mapped into a vault"
    )
  end

  defp validate_inside(changeset) do
    if get_field(changeset, :inside) && get_field(changeset, :folder_id),
      do: add_error(changeset, :inside, "is for a whole board, not one folder of it"),
      else: changeset
  end

  @doc "The path as people write it: `/`, `/Jobs`, `/Projects/X`."
  def display_path(%__MODULE__{path: path}), do: display_path(path)
  def display_path(path) when is_binary(path), do: "/" <> path
end
