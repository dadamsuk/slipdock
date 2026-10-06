defmodule Slipdock.OAuth.Client do
  @moduledoc """
  A third-party app registered through dynamic client registration (RFC 7591):
  a claude.ai connector, Claude Code, or any other OAuth client.

  Clients are public — there is no client secret, because an app on somebody's
  laptop cannot keep one — so the `client_id` is an identifier, not a
  credential, and is stored as it is. What a registration fixes is where an
  authorization may be sent back to, and that is what is checked strictly here:

    * `https://` addresses, matched exactly;
    * `http://` only on the loopback interface (`localhost`, `127.0.0.1`,
      `[::1]`), where the port is ignored when matching, because a native app
      picks a free port each time it runs (RFC 8252 §7.3).

  Anything else would let an authorization code be delivered somewhere that is
  neither the app's own website nor the machine the person is sitting at.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @loopback_hosts ~w(localhost 127.0.0.1 ::1)
  @max_redirect_uris 10
  @max_uri_length 2000
  @max_name_length 100

  schema "oauth_clients" do
    field :client_id, :string
    field :client_name, :string
    field :redirect_uris, {:array, :string}, default: []
    field :registered_ip, :string
    timestamps(type: :utc_datetime)
  end

  @doc "A new registration. `client_id` is generated, never taken from the request."
  def registration_changeset(attrs) do
    %__MODULE__{client_id: generate_client_id()}
    |> cast(attrs, [:client_name, :redirect_uris, :registered_ip])
    |> update_change(:client_name, &clean_name/1)
    |> update_change(:registered_ip, &String.slice(&1, 0, 255))
    |> validate_required([:redirect_uris], message: "at least one redirect URI is required")
    |> validate_length(:redirect_uris,
      min: 1,
      max: @max_redirect_uris,
      message: "between 1 and #{@max_redirect_uris} redirect URIs"
    )
    |> validate_change(:redirect_uris, fn :redirect_uris, uris ->
      case Enum.reject(uris, &valid_redirect_uri?/1) do
        [] -> []
        [bad | _] -> [redirect_uris: "not an allowed redirect URI: #{String.slice(bad, 0, 200)}"]
      end
    end)
  end

  @doc """
  Whether `uri` may be registered: `https` with a host, or `http` on loopback.
  No fragment (RFC 6749 §3.1.2) and no user info.
  """
  def valid_redirect_uri?(uri) when is_binary(uri) and byte_size(uri) <= @max_uri_length do
    case URI.new(uri) do
      {:ok, %URI{fragment: nil, userinfo: nil, scheme: "https", host: host}}
      when is_binary(host) and host != "" ->
        true

      {:ok, %URI{fragment: nil, userinfo: nil, scheme: "http", host: host}} ->
        host in @loopback_hosts

      _ ->
        false
    end
  end

  def valid_redirect_uri?(_), do: false

  @doc """
  Whether `given` is one of the client's registered redirect URIs: exactly, or
  for a loopback `http` registration, exactly apart from the port.
  """
  def redirect_uri_registered?(%__MODULE__{redirect_uris: registered}, given)
      when is_binary(given) do
    Enum.any?(registered, &redirect_uri_matches?(&1, given))
  end

  def redirect_uri_registered?(_client, _given), do: false

  defp redirect_uri_matches?(same, same), do: true

  defp redirect_uri_matches?(registered, given) do
    with {:ok, %URI{scheme: "http", host: host} = r} when host in @loopback_hosts <-
           URI.new(registered),
         {:ok, %URI{} = g} <- URI.new(given) do
      %{r | port: nil, authority: nil} == %{g | port: nil, authority: nil}
    else
      _ -> false
    end
  end

  # The name is what the consent page and Account → API tokens show, and the
  # client chose it, so it is trimmed, clipped and stripped of control
  # characters before it is anybody's label.
  defp clean_name(nil), do: nil

  defp clean_name(name) do
    case name |> String.replace(~r/[[:cntrl:]]/u, " ") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, @max_name_length)
    end
  end

  defp generate_client_id do
    "sdc_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end
end
