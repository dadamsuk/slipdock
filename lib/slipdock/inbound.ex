defmodule Slipdock.Inbound do
  @moduledoc """
  Mail sent *to* Slipdock. Cloudflare Email Routing receives it and hands each
  message to an Email Worker (`cloudflare/inbound-email/`), which signs the
  raw MIME and posts it to `POST /api/inbound/email`. The app parses it,
  decides whether to trust the sender and records the outcome in
  `inbound_emails`. The design, and why it is Cloudflare: W-1933.

  The feature is off unless both `SLIPDOCK_INBOUND_DOMAIN` and
  `SLIPDOCK_INBOUND_SECRET` are set: the endpoint answers 404, the inbound log
  is hidden and no outgoing mail gets a `Reply-To` pointing here.

  `SLIPDOCK_INBOUND_SECRET_PREVIOUS` is accepted alongside the current secret,
  so the secret can be rotated: set the new one here with the old one as
  previous, update the Worker, then drop the previous one.
  """

  alias Slipdock.Config

  @doc "Whether inbound mail is configured: a domain and at least one secret."
  @spec enabled?() :: boolean()
  def enabled?, do: domain() != nil and secrets() != []

  @doc "The domain mail is received on, such as `in.slipdock.us`; nil when unset."
  @spec domain() :: String.t() | nil
  def domain, do: blank_to_nil(config()[:domain])

  @doc """
  The secrets a request may be signed with, current first. More than one only
  while a rotation is under way.
  """
  @spec secrets() :: [String.t()]
  def secrets do
    config()
    |> Keyword.get(:secrets, [])
    |> List.wrap()
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
  end

  defp config, do: Config.get(:inbound, [])

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
