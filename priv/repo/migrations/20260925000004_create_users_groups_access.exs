defmodule Slipdock.Repo.Migrations.CreateUsersGroupsAccess do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :confirmed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :label, :string
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    create table(:groups) do
      add :name, :string, null: false
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:owner_id, :name])

    create table(:group_members, primary_key: false) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
    end

    create unique_index(:group_members, [:group_id, :user_id])

    # One row per (subject, resource): the subject is a user or a group, the
    # resource a board, a card or a saved view. `level` is read or write.
    create table(:access_grants) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :group_id, references(:groups, on_delete: :delete_all)
      add :board_id, references(:boards, on_delete: :delete_all)
      add :card_id, references(:cards, on_delete: :delete_all)
      add :saved_view_id, references(:saved_views, on_delete: :delete_all)
      add :level, :string, null: false, default: "read"
      add :granted_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:access_grants, [:user_id])
    create index(:access_grants, [:group_id])
    create index(:access_grants, [:board_id])
    create index(:access_grants, [:card_id])
    create index(:access_grants, [:saved_view_id])

    alter table(:boards) do
      add :owner_id, references(:users, on_delete: :delete_all)
    end

    create index(:boards, [:owner_id])
  end
end
