defmodule Slipdock.Repo.Migrations.CreateSlipdock do
  @moduledoc """
  The whole schema, in one migration.

  Slipdock was built against SQLite and the 45 migrations that got it here
  carried a lot of SQLite in them — above all the create-copy-drop-rename
  dance that stood in for `ALTER TABLE … DROP NOT NULL`. None of that is worth
  translating, so this replaces the lot: on Postgres there is one baseline and
  no history to honour.

  Keep the ordinary rule from here on — one migration per change, never edited
  once run. This file is a starting point, not a pattern.

  Two things shape the order below. **The references are circular**: a board
  can be a card's sub-board (`boards.parent_card_id`) while every card belongs
  to a board, and a person's quick-add target is a board and a list. So the
  tables are created first and those three columns added afterwards.

  **Several tables belong to a card *or* a page, never both** — comments,
  attachments, votes, checklist items, status updates, URLs, field values,
  embeddings. Each carries both columns, nullable, with a check constraint
  that exactly one is set. `(card_id IS NOT NULL)::int + (page_id IS NOT
  NULL)::int = 1` is the Postgres spelling; the cast is required, as booleans
  do not add up on their own here.
  """
  use Ecto.Migration

  # Exactly one of the listed columns is set. Postgres will not add booleans,
  # hence the casts.
  defp one_of(cols) do
    cols
    |> Enum.map_join(" + ", fn col -> "(#{col} IS NOT NULL)::int" end)
    |> Kernel.<>(" = 1")
  end

  def change do
    # ── templates, people and the board tree ────────────────────────────────

    create table(:board_templates) do
      add :name, :string, null: false
      add :description, :text
      add :columns, {:array, :map}, null: false, default: []
      add :pages, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_templates, [:name])

    # quick_add_board_id and quick_add_column_id are added at the end: the
    # tables they point at do not exist yet. invited_by_id is self-referential
    # and so can be declared here.
    create table(:users) do
      add :email, :string, null: false
      add :name, :string
      add :confirmed_at, :utc_datetime
      add :quick_add_ai, :boolean, null: false, default: true
      add :board_layout, :string, null: false, default: "grid"
      add :board_sort, :string, null: false, default: "manual"
      add :admin, :boolean, null: false, default: false
      add :last_signed_in_at, :utc_datetime
      add :disabled_at, :utc_datetime
      add :card_limit_override, :integer
      add :paid_until, :utc_datetime
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :invited_at, :utc_datetime
      add :terms_accepted_at, :utc_datetime
      add :terms_version, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:admin])
    create index(:users, [:invited_by_id])

    # parent_card_id is added at the end, once cards exist.
    create table(:boards) do
      add :name, :string, null: false
      add :code, :string
      add :shortcut, :string
      add :description, :text
      add :color, :string, null: false, default: "indigo"
      add :vote_budget, :integer, null: false, default: 10
      add :vote_max, :integer, null: false, default: 5
      add :page_seq, :integer, null: false, default: 0
      add :add_card, :boolean, null: false, default: true
      add :add_page, :boolean, null: false, default: true
      add :add_document, :boolean, null: false, default: true
      add :archived_at, :utc_datetime
      add :root_id, references(:boards, on_delete: :delete_all)
      add :template_id, references(:board_templates, on_delete: :nilify_all)
      add :owner_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boards, [:code])
    create unique_index(:boards, [:shortcut])
    create index(:boards, [:root_id])
    create index(:boards, [:owner_id])

    create table(:columns) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      add :wip_limit, :integer
      add :color, :string
      add :category, :string
      add :horizon_from, :date
      add :horizon_to, :date
      add :horizon_unit, :string

      timestamps(type: :utc_datetime)
    end

    create index(:columns, [:board_id, :position])

    create table(:cards) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :column_id, references(:columns, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text
      add :position, :integer, null: false, default: 0
      add :priority, :string, null: false, default: "none"
      add :flags, {:array, :string}, null: false, default: []
      add :start_date, :date
      add :due_date, :date
      add :date_precision, :string, null: false, default: "day"
      add :completed, :boolean, null: false, default: false
      add :percent_complete, :integer
      add :color, :string
      add :archived_at, :utc_datetime
      add :assignee_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:cards, [:column_id, :position])
    create index(:cards, [:board_id])
    create index(:cards, [:assignee_id])

    # The circular three, now that every table they point at exists.
    alter table(:boards) do
      add :parent_card_id, references(:cards, on_delete: :delete_all)
    end

    create unique_index(:boards, [:parent_card_id])

    alter table(:users) do
      add :quick_add_board_id, references(:boards, on_delete: :nilify_all)
      add :quick_add_column_id, references(:columns, on_delete: :nilify_all)
    end

    # ── the wiki ────────────────────────────────────────────────────────────

    create table(:page_folders) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :parent_id, references(:page_folders, on_delete: :nilify_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:page_folders, [:board_id])
    create index(:page_folders, [:parent_id])
    create unique_index(:page_folders, [:board_id, :slug])

    create table(:pages) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :parent_id, references(:pages, on_delete: :nilify_all)
      add :folder_id, references(:page_folders, on_delete: :nilify_all)
      add :title, :string, null: false
      add :slug, :string, null: false
      add :code, :string, null: false
      add :number, :integer, null: false
      add :body, :text, null: false, default: ""
      add :summary, :text
      add :position, :integer, null: false, default: 0
      add :status, :string, null: false, default: "published"
      add :template, :boolean, null: false, default: false
      add :public_token, :string
      add :content_hash, :string, null: false
      add :frozen, :map
      add :published_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :updated_by_id, references(:users, on_delete: :nilify_all)
      add :archived_at, :utc_datetime

      # A page can also sit on the board, with everything a card has.
      add :column_id, references(:columns, on_delete: :nilify_all)
      add :board_position, :integer, null: false, default: 0
      add :priority, :string, null: false, default: "none"
      add :flags, {:array, :string}, null: false, default: []
      add :start_date, :date
      add :due_date, :date
      add :date_precision, :string, null: false, default: "day"
      add :completed, :boolean, null: false, default: false
      add :percent_complete, :integer
      add :color, :string
      add :assignee_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:pages, [:board_id])
    create index(:pages, [:parent_id])
    create index(:pages, [:folder_id])
    create index(:pages, [:column_id])
    create index(:pages, [:assignee_id])
    create index(:pages, [:due_date])
    create unique_index(:pages, [:board_id, :slug])
    create unique_index(:pages, [:code])
    create unique_index(:pages, [:public_token])

    create table(:page_revisions) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :body, :text, null: false, default: ""
      add :summary, :text
      add :author_id, references(:users, on_delete: :nilify_all)
      add :via, :string
      add :agent, :string
      add :byte_size, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:page_revisions, [:page_id])

    # ── tags, views, milestones and custom fields ───────────────────────────

    create table(:tags) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string, null: false, default: "slate"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tags, [:board_id, :name])

    create table(:card_tags, primary_key: false) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:card_tags, [:card_id, :tag_id])

    create table(:page_tags, primary_key: false) do
      add :page_id, references(:pages, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:page_tags, [:page_id, :tag_id])

    create table(:saved_views) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}
      add :public_token, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:saved_views, [:board_id, :name])
    create unique_index(:saved_views, [:public_token])

    create table(:milestones) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :date, :date, null: false
      add :color, :string
      add :card_id, references(:cards, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:milestones, [:board_id, :date])

    create table(:field_definitions) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :key, :string, null: false
      add :kind, :string, null: false
      add :position, :integer, null: false, default: 0
      add :options, {:array, :map}, null: false, default: []
      add :config, :map, null: false, default: %{}
      add :sum, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:field_definitions, [:board_id, :key])
    create index(:field_definitions, [:board_id, :position])

    # ── what hangs off a card or a page ─────────────────────────────────────

    create table(:comments) do
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:card_id])
    create index(:comments, [:page_id])
    create constraint(:comments, :comments_card_xor_page, check: one_of(~w(card_id page_id)))

    create table(:status_updates) do
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      add :health, :string, null: false
      add :body, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # No separate index on page_id alone: a btree on (page_id, inserted_at)
    # already serves a lookup by page_id. SQLite carried both because the two
    # arrived in different migrations.
    create index(:status_updates, [:card_id, :inserted_at])
    create index(:status_updates, [:page_id, :inserted_at])

    create constraint(:status_updates, :status_updates_card_xor_page,
             check: one_of(~w(card_id page_id))
           )

    create table(:checklist_items) do
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :text, :string, null: false
      add :done, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # As with status_updates, (page_id, position) covers page_id on its own.
    create index(:checklist_items, [:card_id, :position])
    create index(:checklist_items, [:page_id, :position])

    create constraint(:checklist_items, :checklist_items_card_xor_page,
             check: one_of(~w(card_id page_id))
           )

    # A vote is one row per person per card, so the unique indexes do the
    # enforcing. NULLs are distinct in a Postgres unique index just as they
    # were in SQLite, so a page's votes do not collide with a card's.
    create table(:votes) do
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :count, :integer, null: false, default: 1
      add :comment, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:votes, [:card_id, :user_id])
    create unique_index(:votes, [:page_id, :user_id])
    create index(:votes, [:page_id])
    create constraint(:votes, :votes_card_xor_page, check: one_of(~w(card_id page_id)))

    create table(:card_urls) do
      add :url, :text, null: false
      add :title, :string
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:card_urls, [:card_id])
    create index(:card_urls, [:page_id])
    create constraint(:card_urls, :card_urls_card_xor_page, check: one_of(~w(card_id page_id)))

    create table(:card_field_values) do
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :field_id, references(:field_definitions, on_delete: :delete_all), null: false
      add :number, :float
      add :text, :text
      add :date, :date
      add :option, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:card_field_values, [:card_id, :field_id])
    create unique_index(:card_field_values, [:page_id, :field_id])
    create index(:card_field_values, [:field_id])
    create index(:card_field_values, [:page_id])

    create constraint(:card_field_values, :card_field_values_card_xor_page,
             check: one_of(~w(card_id page_id))
           )

    create table(:attachments) do
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :integer, null: false
      add :key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:attachments, [:card_id])
    create index(:attachments, [:page_id])
    create unique_index(:attachments, [:key])

    create constraint(:attachments, :attachments_card_xor_page,
             check: one_of(~w(card_id page_id))
           )

    # ── how things point at each other ──────────────────────────────────────

    create table(:card_dependencies, primary_key: false) do
      add :blocker_id, references(:cards, on_delete: :delete_all), null: false
      add :blocked_id, references(:cards, on_delete: :delete_all), null: false
    end

    create unique_index(:card_dependencies, [:blocked_id, :blocker_id])
    create index(:card_dependencies, [:blocker_id])

    create table(:card_links) do
      add :from_id, references(:cards, on_delete: :delete_all), null: false
      add :to_id, references(:cards, on_delete: :delete_all), null: false
      add :kind, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:card_links, [:from_id, :to_id, :kind])
    create index(:card_links, [:to_id])

    # A wiki link's *source* is a page, a comment, a status update or a card;
    # its *target* is whatever it resolved to, or nothing if it dangles.
    create table(:page_links) do
      add :page_id, references(:pages, on_delete: :delete_all)
      add :source_page_id, references(:pages, on_delete: :delete_all)
      add :source_comment_id, references(:comments, on_delete: :delete_all)
      add :source_status_id, references(:status_updates, on_delete: :delete_all)
      add :source_card_id, references(:cards, on_delete: :delete_all)
      add :kind, :string, null: false
      add :target_page_id, references(:pages, on_delete: :nilify_all)
      add :target_card_id, references(:cards, on_delete: :nilify_all)
      add :target_board_id, references(:boards, on_delete: :nilify_all)
      add :target_view_id, references(:saved_views, on_delete: :nilify_all)
      add :raw, :text, null: false
      add :label, :string
      add :resolved, :boolean, null: false, default: false
      add :pinned, :boolean, null: false, default: false
      add :count, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:page_links, [:page_id])
    create index(:page_links, [:source_page_id])
    create index(:page_links, [:source_comment_id])
    create index(:page_links, [:source_status_id])
    create index(:page_links, [:source_card_id])
    create index(:page_links, [:target_page_id])
    create index(:page_links, [:target_card_id])
    create index(:page_links, [:resolved])

    # ── semantic search ─────────────────────────────────────────────────────

    create table(:search_embeddings) do
      add :kind, :string, null: false
      add :source_id, :integer, null: false
      add :section, :string, null: false, default: ""
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :content_hash, :string, null: false
      add :model, :string, null: false
      add :dimensions, :integer, null: false
      add :vector, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:search_embeddings, [:kind, :source_id, :section])
    create index(:search_embeddings, [:board_id])
    create index(:search_embeddings, [:card_id])
    create index(:search_embeddings, [:page_id])

    create constraint(:search_embeddings, :search_embeddings_card_xor_page,
             check: one_of(~w(card_id page_id))
           )

    # ── activity, automations and alerts ────────────────────────────────────

    create table(:activities) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :nilify_all)
      add :page_id, references(:pages, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :message, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:activities, [:board_id, :inserted_at])

    create table(:automation_rules) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :source, :text
      add :spec, :map, null: false
      add :scope, :string, null: false, default: "board"
      add :enabled, :boolean, null: false, default: true
      add :run_count, :integer, null: false, default: 0
      add :last_run_at, :utc_datetime
      add :last_error, :text
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:automation_rules, [:board_id])

    # One row per rule per thing it has already acted on, so a rule that fires
    # on a condition does not fire again while the condition holds.
    create table(:automation_fires) do
      add :rule_id, references(:automation_rules, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :key, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:automation_fires, [:rule_id, :key])

    create table(:alerts) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :card_id, references(:cards, on_delete: :delete_all)
      add :rule_id, references(:automation_rules, on_delete: :nilify_all)
      add :title, :string, null: false
      add :body, :text
      add :severity, :string, null: false, default: "info"

      timestamps(type: :utc_datetime)
    end

    create index(:alerts, [:board_id])
    create index(:alerts, [:card_id])

    create table(:alert_dismissals) do
      add :alert_id, references(:alerts, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:alert_dismissals, [:alert_id, :user_id])

    # ── people: groups, sharing, tokens and devices ─────────────────────────

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

    # A grant hands one subject (a person or a group) one thing (a board, a
    # card, a page or a saved view) at one level.
    create table(:access_grants) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :group_id, references(:groups, on_delete: :delete_all)
      add :board_id, references(:boards, on_delete: :delete_all)
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :saved_view_id, references(:saved_views, on_delete: :delete_all)
      add :level, :string, null: false, default: "read"
      add :granted_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:access_grants, [:user_id])
    create index(:access_grants, [:group_id])
    create index(:access_grants, [:board_id])
    create index(:access_grants, [:card_id])
    create index(:access_grants, [:page_id])
    create index(:access_grants, [:saved_view_id])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :label, :string
      add :scope, :string, null: false, default: "write"
      add :scope_boards, {:array, :integer}, null: false, default: []
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string
      add :code, :string
      add :code_attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
    create index(:users_tokens, [:expires_at])
    create index(:users_tokens, [:code])

    create table(:device_authorizations) do
      add :device_code, :binary, null: false
      add :user_code, :string, null: false
      add :scope, :string, null: false, default: "write"
      add :scope_boards, {:array, :integer}, null: false, default: []
      add :client_label, :string
      add :client_ip, :string
      add :client_agent, :string
      add :expires_at, :utc_datetime, null: false
      add :approved_at, :utc_datetime
      add :denied_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_authorizations, [:device_code])
    create unique_index(:device_authorizations, [:user_code])
    create index(:device_authorizations, [:expires_at])

    create table(:support_sessions) do
      add :subject_id, references(:users, on_delete: :delete_all), null: false
      add :admin_id, references(:users, on_delete: :nilify_all), null: false
      add :reason, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:support_sessions, [:subject_id])
    create index(:support_sessions, [:admin_id])
    create index(:support_sessions, [:expires_at])

    # ── each person's own arrangement of things ─────────────────────────────

    create table(:favourites) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all)
      add :column_id, references(:columns, on_delete: :delete_all)
      add :card_id, references(:cards, on_delete: :delete_all)
      add :page_id, references(:pages, on_delete: :delete_all)
      add :saved_view_id, references(:saved_views, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:favourites, [:user_id])
    create unique_index(:favourites, [:user_id, :board_id])
    create unique_index(:favourites, [:user_id, :column_id])
    create unique_index(:favourites, [:user_id, :card_id])
    create unique_index(:favourites, [:user_id, :page_id])
    create unique_index(:favourites, [:user_id, :saved_view_id])

    create table(:board_orders) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_orders, [:user_id, :board_id])

    create table(:saved_queries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :mode, :string, null: false
      add :text, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:saved_queries, [:user_id, :mode])
    create unique_index(:saved_queries, [:user_id, :mode, :text])

    # ── the instance itself ─────────────────────────────────────────────────

    # One row, id 1. `Slipdock.Settings` keeps the singleton honest.
    create table(:settings) do
      add :signup_mode, :string, null: false, default: "closed"
      add :free_card_limit, :integer
      add :board_limit, :integer, default: 1000
      add :board_limit_enabled, :boolean, null: false, default: true
      add :item_limit, :integer, default: 250_000
      add :item_limit_enabled, :boolean, null: false, default: true
      add :storage_limit_mb, :integer, default: 10_240
      add :storage_limit_enabled, :boolean, null: false, default: true
      add :trial_days, :integer, default: 30
      add :trial_enabled, :boolean, null: false, default: false
      add :user_directory, :string, null: false, default: "instance"
      add :invites_create_accounts, :boolean, null: false, default: true
      add :admin_email, :string
      add :setup_completed_at, :utc_datetime
      add :setup_token, :string
      add :smtp_host, :string
      add :smtp_port, :integer
      add :smtp_username, :string
      add :smtp_password, :string
      add :smtp_from_name, :string
      add :smtp_from_email, :string
      add :smtp_tls, :string, null: false, default: "if_available"
      add :smtp_verified_at, :utc_datetime
      add :login_fallback_enabled, :boolean
      add :terms_url, :string
      add :privacy_url, :string
      add :terms_version, :string

      timestamps(type: :utc_datetime)
    end

    create table(:signup_allowlist_entries) do
      add :entry, :string, null: false
      add :last_used_at, :utc_datetime
      add :added_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:signup_allowlist_entries, [:entry])

    create table(:signup_requests) do
      add :email, :string, null: false
      add :note, :text
      add :status, :string, null: false, default: "pending"
      add :decided_at, :utc_datetime
      add :decided_by_id, references(:users, on_delete: :nilify_all)
      add :requested_ip, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:signup_requests, [:email])
    create index(:signup_requests, [:status])

    seed_templates()
  end

  # The stock board templates. These were seeded by migrations rather than by
  # `priv/repo/seeds.exs`, and so are part of what a migrated database is
  # expected to contain — `Slipdock.AI.Actions` reaches for "Simple" by name,
  # and the test suite with it. "Task breakdown" is deliberately absent:
  # `Slipdock.Onboarding` creates that one on demand.
  #
  # `category: "done"` marks only the lists actually named "Done", which is
  # what the migration that introduced categories matched on — Bug triage's
  # "Closed" was left alone, and still is.
  defp seed_templates do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    templates = [
      {"Slipdock", "The classic four-list flow.",
       [
         %{name: "Backlog"},
         %{name: "To Do"},
         %{name: "In Progress", wip_limit: 3, color: "amber"},
         %{name: "Done", color: "emerald", category: "done"}
       ]},
      {"Simple", "Three lists, no ceremony.",
       [
         %{name: "To Do"},
         %{name: "Doing", color: "sky"},
         %{name: "Done", color: "emerald", category: "done"}
       ]},
      {"Checklist", "Open or done, nothing in between.",
       [%{name: "Open"}, %{name: "Done", color: "emerald", category: "done"}]},
      {"Bug triage", "From report to verified fix.",
       [
         %{name: "New", color: "rose"},
         %{name: "Confirmed", color: "orange"},
         %{name: "Fixing", wip_limit: 2, color: "amber"},
         %{name: "Verify", color: "sky"},
         %{name: "Closed", color: "emerald"}
       ]},
      {"Research", "Questions, in progress, findings.",
       [
         %{name: "Questions"},
         %{name: "Investigating", color: "violet"},
         %{name: "Findings", color: "teal"}
       ]},
      {"Roadmap",
       "Horizons for a roadmap: now, next, later. Give each card subcards for the work beneath.",
       [
         %{name: "Now", color: "amber"},
         %{name: "Next", color: "sky"},
         %{name: "Later"},
         %{name: "Done", color: "emerald", category: "done"}
       ]}
    ]

    flush()

    for {name, description, columns} <- templates do
      repo().query!(
        """
        INSERT INTO board_templates (name, description, columns, pages, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [name, description, columns, [], now, now]
      )
    end
  end
end
