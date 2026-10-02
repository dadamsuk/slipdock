defmodule Slipdock.Settings.AllowlistEntry do
  @moduledoc """
  One line of the registration allowlist: an email address, or a bare domain
  meaning anybody there.

  This is what `SLIPDOCK_SIGNUP_ALLOW` used to be — a comma-separated string
  parsed on every check. As rows it can be edited from the admin UI, and each
  line can record when it last let somebody in, which is the only way to tell a
  line that is working from one that was a typo.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "signup_allowlist_entries" do
    field :entry, :string
    field :last_used_at, :utc_datetime
    belongs_to :added_by, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Normalises an entry or an address the same way, so the matching query can be
  a plain equality test: trimmed, downcased, and with a leading `@` dropped so
  that `@example.com` and `example.com` are one entry rather than two.
  """
  def normalise(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> String.trim_leading("@")
  end

  def normalise(value), do: value

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:entry, :added_by_id])
    |> update_change(:entry, &normalise/1)
    |> validate_required([:entry])
    |> validate_format(:entry, ~r/^[^\s@]+(@[^\s@]+)?\.[^\s@]+$/,
      message: "must be an email address or a domain"
    )
    |> validate_length(:entry, max: 160)
    |> unique_constraint(:entry)
    |> foreign_key_constraint(:added_by_id)
  end
end
