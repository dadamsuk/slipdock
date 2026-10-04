defmodule Slipdock.Accounts.DeviceAuthorization do
  @moduledoc """
  One pending device-authorization request (RFC 8628): an agent that cannot
  host a browser asks for access, a person approves it in one they already
  have signed in, and the agent polls until a token comes back.

  Two codes, with different jobs. The **device code** is the secret the client
  polls with: 32 random bytes, stored hashed, never shown to anybody. The
  **user code** is the short string a person reads off a terminal and types
  into a browser — low entropy by necessity, so it is single use, expires in
  minutes, and the polling that depends on it is rate limited.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Slipdock.Accounts.User

  @rand_size 32
  @hash_algorithm :sha256
  @validity_minutes 10

  # No vowels, so a code can never spell a word; no 0/O and no 1/I/L, so it can
  # never be misread off a screen or misheard down a phone.
  @alphabet ~c"BCDFGHJKMNPQRSTVWXZ23456789"
  @code_length 8

  schema "device_authorizations" do
    field :device_code, :binary
    field :user_code, :string
    field :scope, :string, default: "write"
    field :scope_boards, {:array, :integer}, default: []
    field :client_label, :string
    field :client_ip, :string
    field :client_agent, :string
    field :expires_at, :utc_datetime
    field :approved_at, :utc_datetime
    field :denied_at, :utc_datetime
    belongs_to :user, User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def validity_minutes, do: @validity_minutes

  @doc "Formats a stored code for display: XXXX-XXXX."
  def display_code(code) when is_binary(code) do
    {a, b} = String.split_at(code, 4)
    a <> "-" <> b
  end

  @doc "Accepts a code as typed — spaces, dashes and lower case all forgiven."
  def normalise_code(input) when is_binary(input) do
    input |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
  end

  def normalise_code(_), do: ""

  @doc """
  Builds a pending request. Returns `{plaintext_device_code, struct}` — the
  plaintext is handed to the client once and never stored.
  """
  def build(attrs \\ %{}) do
    device_code = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(device_code, padding: false),
     %__MODULE__{
       device_code: :crypto.hash(@hash_algorithm, device_code),
       user_code: generate_user_code(),
       scope: attrs[:scope] || "write",
       scope_boards: attrs[:scope_boards] || [],
       client_label: attrs[:client_label],
       client_ip: clip(attrs[:client_ip]),
       client_agent: clip(attrs[:client_agent]),
       expires_at: DateTime.utc_now(:second) |> DateTime.add(@validity_minutes, :minute)
     }}
  end

  def hash_device_code(plaintext) do
    case Base.url_decode64(plaintext, padding: false) do
      {:ok, decoded} -> {:ok, :crypto.hash(@hash_algorithm, decoded)}
      :error -> :error
    end
  end

  # Both arrive in request headers, so their length is the client's choice;
  # the columns hold 255.
  defp clip(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp clip(_), do: nil

  # From the CSPRNG, not `:rand`: the code is the half of the pair a person
  # carries, and a predictable one could be guessed before they typed it.
  # Bytes at or above the largest multiple of the alphabet's size are thrown
  # away, so that no character comes up more often than another.
  defp generate_user_code do
    size = length(@alphabet)
    limit = div(256, size) * size

    Stream.repeatedly(fn -> :crypto.strong_rand_bytes(@code_length * 2) end)
    |> Stream.flat_map(&:binary.bin_to_list/1)
    |> Stream.filter(&(&1 < limit))
    |> Enum.take(@code_length)
    |> Enum.map(&Enum.at(@alphabet, rem(&1, size)))
    |> List.to_string()
  end

  def expired?(%__MODULE__{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  @doc "Pending requests only: not approved, not denied, not expired."
  def pending(query \\ __MODULE__) do
    now = DateTime.utc_now()

    from(d in query,
      where: is_nil(d.approved_at) and is_nil(d.denied_at) and d.expires_at > ^now
    )
  end
end
