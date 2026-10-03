defmodule Slipdock.Repo.Migrations.InstanceLimits do
  use Ecto.Migration

  @moduledoc """
  The limits that apply on every install, free tier or not: how many boards a
  person may own, how many things those boards may hold, and how many bytes of
  uploads sit behind them.

  Each has a number and a switch, rather than nil meaning off, so that turning
  one off and back on again does not lose the number the admin chose.

  SQLite gives existing rows the defaults, so an install that upgrades into
  this gets the guardrails rather than nothing.
  """
  def change do
    alter table(:settings) do
      add :board_limit, :integer, default: 1_000
      add :board_limit_enabled, :boolean, default: true, null: false
      add :item_limit, :integer, default: 250_000
      add :item_limit_enabled, :boolean, default: true, null: false
      add :storage_limit_mb, :integer, default: 10_240
      add :storage_limit_enabled, :boolean, default: true, null: false
    end
  end
end
