defmodule Slipdock.Repo.Migrations.FreeTrial do
  use Ecto.Migration

  @moduledoc """
  A free account that lasts a month rather than for ever.

  `trial_days` is how long a free account may add things for, counted from the
  day it was made; `trial_enabled` is its switch, and it is **off** by default
  because a self-hosted install has nobody to bill and must not expire.

  `users.paid_until` is what makes an account not free: an operator sets it
  when somebody pays, and until there is a billing system that is the whole of
  subscriptions. A free account is one with no date here in the future, and
  only free accounts have either a trial or the free tier's card allowance.
  """
  def change do
    alter table(:settings) do
      add :trial_days, :integer, default: 30
      add :trial_enabled, :boolean, default: false, null: false
    end

    alter table(:users) do
      add :paid_until, :utc_datetime
    end
  end
end
