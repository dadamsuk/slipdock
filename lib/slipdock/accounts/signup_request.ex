defmodule Slipdock.Accounts.SignupRequest do
  @moduledoc """
  Somebody asking for an account on a server whose registration mode is
  `approval`.

  Deliberately not a `users` row. `Slipdock.Accounts.signup_allowed?/1` says yes
  to anybody who already has an account, so creating the user when they ask
  would approve the request by asking it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved rejected)

  schema "signup_requests" do
    field :email, :string
    field :note, :string
    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime
    field :requested_ip, :string
    belongs_to :decided_by, Slipdock.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:email, :note, :requested_ip])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:note, &(&1 |> String.trim() |> String.slice(0, 500)))
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end

  def decision_changeset(request, status, decided_by) when status in ["approved", "rejected"] do
    change(request,
      status: status,
      decided_at: DateTime.utc_now() |> DateTime.truncate(:second),
      decided_by_id: decided_by && decided_by.id
    )
  end
end
