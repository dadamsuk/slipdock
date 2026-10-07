defmodule Slipdock.Repo.Migrations.AddPosthogToSettings do
  use Ecto.Migration

  # Product analytics, off until an admin fills in a PostHog project key. The
  # host is where the events go: PostHog's US or EU cloud, or a proxy of your
  # own; blank means the US cloud.
  def change do
    alter table(:settings) do
      add :posthog_key, :string
      add :posthog_host, :string
    end
  end
end
