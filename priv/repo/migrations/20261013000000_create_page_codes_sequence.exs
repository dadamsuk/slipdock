defmodule Slipdock.Repo.Migrations.CreatePageCodesSequence do
  use Ecto.Migration

  # Page codes (`W-31`) came from max(code) + 1, which cannot see a page
  # another transaction has written and not yet committed: two pages written
  # at once took the same code and the second waited on the first's unique
  # key (#656). A sequence hands each caller its own number whatever is still
  # uncommitted. It starts after the highest code already given out.
  def up do
    execute "CREATE SEQUENCE page_codes"

    execute """
    SELECT setval('page_codes',
      COALESCE((SELECT max(CAST(substr(code, 3) AS INTEGER)) FROM pages), 0) + 1,
      false)
    """
  end

  def down do
    execute "DROP SEQUENCE page_codes"
  end
end
