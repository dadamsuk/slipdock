defmodule Slipdock.Repo.Migrations.AddMissingForeignKeyIndexes do
  use Ecto.Migration

  # Every foreign key the baseline left without an index that leads with it.
  # Postgres does not index the referencing side on its own, so each
  # on_delete (delete_all / nilify_all) on the parent scanned the child table
  # in full — deleting one card walked all of `activities` twice.
  @indexes [
    activities: :card_id,
    activities: :page_id,
    automation_fires: :card_id,
    automation_callbacks: :rule_id,
    automation_callbacks: :card_id,
    alerts: :rule_id,
    alert_dismissals: :user_id,
    milestones: :card_id,
    status_updates: :user_id,
    page_revisions: :author_id,
    pages: :created_by_id,
    pages: :updated_by_id,
    page_links: :target_board_id,
    page_links: :target_view_id,
    access_grants: :granted_by_id,
    automation_rules: :created_by_id,
    card_tags: :tag_id,
    page_tags: :tag_id,
    votes: :user_id,
    group_members: :user_id,
    device_authorizations: :user_id,
    favourites: :board_id,
    favourites: :column_id,
    favourites: :card_id,
    favourites: :page_id,
    favourites: :saved_view_id,
    board_orders: :board_id,
    boards: :template_id,
    users: :quick_add_board_id,
    users: :quick_add_column_id,
    signup_allowlist_entries: :added_by_id,
    signup_requests: :decided_by_id
  ]

  def change do
    for {table, column} <- @indexes do
      create index(table, [column])
    end
  end
end
