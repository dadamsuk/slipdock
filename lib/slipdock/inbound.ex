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

  import Ecto.Query

  alias Slipdock.{Accounts, Config, RateLimit, Repo}
  alias Slipdock.Inbound.{Dispatcher, Email, Message}

  # Per address and per sender, an hour at a time (W-1933, "Rate limits").
  @token_limit 30
  @sender_limit 60
  @window :timer.hours(1)

  @local_part ~r/^(card|page|add|reply)-([a-z0-9]+)$/

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

  @typedoc """
  What the endpoint makes of a request, for the response it gives:

    * `{:accepted, email}` — handled (202)
    * `{:duplicate, email}` — seen before and accepted then: no new write (200)
    * `{:rejected, reason, email}` — refused, with a reason the sender reads (4xx);
      a repeat of a refused message is refused again without a second row
    * `{:rate_limited, reason}` — too much mail to that address or from that
      sender; not recorded, which is the point of the limit (429)
  """
  @type outcome ::
          {:accepted, Email.t()}
          | {:duplicate, Email.t()}
          | {:rejected, String.t(), Email.t()}
          | {:rate_limited, String.t()}

  @doc """
  Decides about one message: `raw` is the MIME as the Worker sent it,
  `envelope_to` the address Cloudflare delivered it to and `envelope_from`
  the SMTP sender. The signature has already been checked.
  """
  @spec receive_message(%{
          raw: binary(),
          envelope_to: String.t(),
          envelope_from: String.t() | nil
        }) ::
          outcome()
  def receive_message(%{raw: raw, envelope_to: envelope_to} = request) do
    recipient = envelope_to |> to_string() |> String.trim() |> String.downcase()
    {kind, token} = address(recipient)
    parsed = Message.parse(raw)

    base =
      case parsed do
        {:ok, message} ->
          %{
            message_id: present(message.message_id) || synthetic_id(raw),
            sender: message.from || envelope_sender(request),
            subject: message.subject
          }

        {:error, _} ->
          %{message_id: synthetic_id(raw), sender: envelope_sender(request), subject: nil}
      end
      |> Map.merge(%{recipient: recipient, kind: kind, size: byte_size(raw)})

    case Repo.get_by(Email, message_id: base.message_id, recipient: recipient) do
      %Email{outcome: "accepted"} = seen ->
        {:duplicate, seen}

      %Email{reason: reason} = seen ->
        {:rejected, reason, seen}

      nil ->
        with :ok <- rate_limit(token, base.sender) do
          case parsed do
            {:ok, message} ->
              decide(base, %{
                kind: kind,
                token: token,
                recipient: recipient,
                sender: base.sender,
                message: message
              })

            {:error, _} ->
              reason = "The message couldn't be read."
              {:rejected, reason, record(base, %{}, "rejected", reason)}
          end
        end
    end
  end

  defp decide(base, request) do
    case dispatch(base, request) do
      {:ok, attrs} ->
        {:accepted, record(base, attrs, "accepted", nil)}

      {:reject, reason, attrs} ->
        {:rejected, reason, record(base, attrs, "rejected", reason)}
    end
  end

  defp dispatch(%{recipient: recipient}, request) do
    if in_domain?(recipient),
      do: dispatcher().dispatch(request),
      else: {:reject, "No such address here.", %{}}
  end

  # A test can stand a dispatcher of its own in, for the outcomes the real one
  # cannot reach yet.
  defp dispatcher, do: Config.get(:inbound_dispatcher, Dispatcher)

  # Two deliveries of one message can race; the loser reads the winner's row.
  defp record(base, attrs, outcome, reason) do
    attrs =
      base
      |> Map.merge(Map.take(attrs, [:user_id, :card_id, :page_id, :comment_id]))
      |> Map.put(:outcome, outcome)
      |> Map.put(:reason, reason)
      |> Map.put_new_lazy(:user_id, fn -> claimed_user_id(base.sender) end)

    case %Email{} |> Email.changeset(attrs) |> Repo.insert() do
      {:ok, email} -> email
      {:error, _} -> Repo.get_by!(Email, message_id: base.message_id, recipient: base.recipient)
    end
  end

  defp claimed_user_id(nil), do: nil

  defp claimed_user_id(sender) do
    case Accounts.get_user_by_email(sender) do
      nil -> nil
      user -> user.id
    end
  end

  defp rate_limit(token, sender) do
    with :ok <- hit("inbound:token:#{token}", token, @token_limit),
         :ok <- hit("inbound:sender:#{sender}", sender, @sender_limit) do
      :ok
    else
      {:error, seconds} ->
        {:rate_limited,
         "Too much mail to this address. Try again in #{div(seconds + 59, 60)} minutes."}
    end
  end

  defp hit(_key, nil, _limit), do: :ok
  defp hit(key, _, limit), do: RateLimit.hit(key, limit, @window)

  @doc """
  The kind of address and its token: `{"card", "abc"}` for `card-abc@…`, and
  `{"unknown", nil}` for anything not in the pattern.
  """
  @spec address(String.t()) :: {String.t(), String.t() | nil}
  def address(recipient) do
    local = recipient |> String.split("@") |> hd() |> String.split("+") |> hd()

    case Regex.run(@local_part, local) do
      [_, kind, token] -> {kind, token}
      nil -> {"unknown", nil}
    end
  end

  defp in_domain?(recipient) do
    case String.split(recipient, "@") do
      [_local, host] -> host == String.downcase(domain() || "")
      _ -> false
    end
  end

  @doc """
  The last `limit` messages in `user`'s inbound log, newest first.
  """
  def recent(%{id: user_id}, limit \\ 50) do
    Email
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  # A message with no Message-ID still has to be recognised when it repeats.
  defp synthetic_id(raw),
    do: "<" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower) <> "@slipdock.invalid>"

  defp present(nil), do: nil
  defp present(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp envelope_sender(request) do
    case request[:envelope_from] do
      from when is_binary(from) and from != "" -> from |> String.trim() |> String.downcase()
      _ -> nil
    end
  end
end
