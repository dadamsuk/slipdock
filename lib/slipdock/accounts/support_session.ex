defmodule Slipdock.Accounts.SupportSession do
  @moduledoc """
  An admin given temporary read access to somebody's boards in order to help
  them.

  Running a service for other people means occasionally needing to see what
  they see. The problem with that is not the access — it is that whoever has
  the database can read everything anyway — it is that the access can be
  silent. So this is a record first and a permission second: it expires, it
  says why, and the person it is about can see every one of them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Long enough to look at a problem, short enough that forgetting to end one
  # is not the same as keeping it.
  @default_hours 4

  schema "support_sessions" do
    field :reason, :string
    field :expires_at, :utc_datetime
    field :ended_at, :utc_datetime
    belongs_to :subject, Slipdock.Accounts.User
    belongs_to :admin, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def default_hours, do: @default_hours

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:subject_id, :admin_id, :reason, :expires_at])
    |> update_change(:reason, &(&1 |> to_string() |> String.trim() |> String.slice(0, 300)))
    |> validate_required([:subject_id, :admin_id, :reason])
    |> validate_length(:reason, min: 3, message: "say what this is for")
    |> put_expiry()
    |> foreign_key_constraint(:subject_id)
    |> foreign_key_constraint(:admin_id)
  end

  defp put_expiry(changeset) do
    case get_field(changeset, :expires_at) do
      nil ->
        put_change(
          changeset,
          :expires_at,
          DateTime.utc_now() |> DateTime.add(@default_hours, :hour) |> DateTime.truncate(:second)
        )

      _ ->
        changeset
    end
  end
end
