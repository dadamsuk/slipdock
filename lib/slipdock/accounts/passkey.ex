defmodule Slipdock.Accounts.Passkey do
  @moduledoc """
  A passkey: a WebAuthn credential that signs its owner in without an email.

  The authenticator (a phone, a laptop's keychain, a security key) keeps the
  private key; the server keeps only what it needs to check a signature —
  the credential's id, its public key as a COSE key, and the last signature
  count, which catches a cloned authenticator. See `Slipdock.Accounts.Passkeys`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name_max 60

  schema "user_passkeys" do
    belongs_to :user, Slipdock.Accounts.User
    field :credential_id, :binary
    # The COSE key map, as `:erlang.term_to_binary/1`; read back with `:safe`.
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :name, :string
    field :aaguid, :binary
    field :last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :name, :aaguid])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:user_id, :credential_id, :public_key, :name])
    |> validate_length(:name, max: @name_max)
    |> unique_constraint(:credential_id)
  end

  @doc "The longest name a passkey may have."
  def name_max, do: @name_max

  @doc "The stored public key, as the COSE key map Wax checks signatures with."
  def cose_key(%__MODULE__{public_key: bin}), do: :erlang.binary_to_term(bin, [:safe])
end
