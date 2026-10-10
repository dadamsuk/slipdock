defmodule Slipdock.Repo.Migrations.SecondReadingOffByDefault do
  use Ecto.Migration

  # A second reading doubles the cost and, with a reading asked to be
  # selective, mostly adds disagreements to settle; it becomes the admin's
  # to turn on (#559). The setting arrived a day before this, so a server
  # still on "same" has the old default, not a choice: it goes to "off" too.
  def up do
    alter table(:settings) do
      modify :meetings_second_reading, :string, default: "off", null: false
    end

    execute "UPDATE settings SET meetings_second_reading = 'off' WHERE meetings_second_reading = 'same'"
  end

  def down do
    alter table(:settings) do
      modify :meetings_second_reading, :string, default: "same", null: false
    end
  end
end
