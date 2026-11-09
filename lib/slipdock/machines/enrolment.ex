defmodule Slipdock.Machines.Enrolment do
  @moduledoc """
  A pending device-code enrolment (#2570): `slipdock-runner init` asks for
  one, naming the machine (hostname, OS, architecture, fingerprint), shows a
  person the short code, and polls with the device code until the person
  approves it on `/account/machines/approve`, choosing the boards.

  The same two codes as `Slipdock.Accounts.DeviceAuthorization`, with the
  same rules: the device code is 32 random bytes kept hashed, the user code
  is short, single use and expires in minutes.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Slipdock.Accounts.DeviceAuthorization

  @validity_minutes 10

  schema "machine_enrolments" do
    field :device_code, :binary, redact: true
    field :user_code, :string
    field :hostname, :string
    field :os, :string
    field :arch, :string
    field :fingerprint, :string
    field :client_ip, :string
    field :board_ids, {:array, :integer}, default: []
    field :expires_at, :utc_datetime
    field :approved_at, :utc_datetime
    field :denied_at, :utc_datetime
    belongs_to :user, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def validity_minutes, do: @validity_minutes

  @doc """
  Builds a pending enrolment for a machine described by `about` (already
  cleaned by `Slipdock.Machines`). Returns `{plaintext_device_code, struct}`.
  """
  def build(about) do
    device_code = :crypto.strong_rand_bytes(32)

    # The user code comes from the device flow's own generator: the same
    # alphabet, length and unbiased draw.
    {_, %{user_code: user_code}} = DeviceAuthorization.build()

    {Base.url_encode64(device_code, padding: false),
     struct!(
       __MODULE__,
       Map.merge(about, %{
         device_code: :crypto.hash(:sha256, device_code),
         user_code: user_code,
         expires_at: DateTime.utc_now(:second) |> DateTime.add(@validity_minutes, :minute)
       })
     )}
  end

  def hash_device_code(plaintext) when is_binary(plaintext) do
    case Base.url_decode64(plaintext, padding: false) do
      {:ok, decoded} -> {:ok, :crypto.hash(:sha256, decoded)}
      :error -> :error
    end
  end

  def hash_device_code(_), do: :error

  def expired?(%__MODULE__{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  @doc "Pending enrolments only: not approved, not denied, not expired."
  def pending(query \\ __MODULE__) do
    now = DateTime.utc_now()

    from(e in query,
      where: is_nil(e.approved_at) and is_nil(e.denied_at) and e.expires_at > ^now
    )
  end
end
