defmodule Slipdock.Inbound.ReplyToken do
  @moduledoc """
  The signed part of a `reply-<signed>@…` address (#1256, W-1933
  "Addresses"): the `Reply-To` on a notification email about a card, so a
  reply can become a comment on that card, by the person the email was for.

  Signed, not stored. The token packs `(card id, user id, day issued)` with
  a version byte, followed by an 80-bit truncated HMAC-SHA256, all base32
  in lowercase without padding: 37 characters, so the whole local part
  `reply-…` is 43, well inside the 64 an address allows.

  The HMAC key is derived from `SLIPDOCK_INBOUND_SECRET`. Every secret
  `Slipdock.Inbound.secrets/0` lists is accepted when verifying, so during a
  rotation (`SLIPDOCK_INBOUND_SECRET_PREVIOUS`) addresses already sent keep
  working. Once the previous secret is dropped, they stop.

  **Age.** An address is good for a year from the day it was sent
  (decision on #1256). Old enough that nobody's reply to last month's
  mention bounces; short enough that a leaked address doesn't last forever.
  """

  alias Slipdock.{Access, Inbound, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Card

  @version 1
  @mac_bytes 10
  @max_age_days 365
  @context "slipdock inbound reply token v1"

  @doc "How many days an address stays good."
  def max_age_days, do: @max_age_days

  @doc """
  The token for a reply by `user` to `card`, signed with the current
  secret. `today` (a `Date`) is for tests. Nil when inbound mail is off, or
  an id doesn't fit.
  """
  @spec sign(Card.t() | integer(), User.t() | integer(), Date.t()) :: String.t() | nil
  def sign(card, user, today \\ Date.utc_today()) do
    card_id = id(card)
    user_id = id(user)
    day = Date.diff(today, ~D[1970-01-01])

    case Inbound.secrets() do
      [secret | _] when card_id < 0x10000000000 and user_id < 0x10000000000 and day >= 0 ->
        payload = <<@version::8, card_id::40, user_id::40, day::16>>
        Base.encode32(payload <> mac(secret, payload), case: :lower, padding: false)

      _ ->
        nil
    end
  end

  @doc """
  The full `Reply-To` address for `user` replying to `card`, or nil when
  inbound mail is off.
  """
  @spec address(Card.t() | integer(), User.t() | integer()) :: String.t() | nil
  def address(card, user) do
    with true <- Inbound.enabled?(),
         token when is_binary(token) <- sign(card, user) do
      "reply-#{token}@#{Inbound.domain()}"
    else
      _ -> nil
    end
  end

  @doc """
  The card and the person a token stands for, `{:ok, card, user}`, or why
  not:

    * `:invalid` — not one of ours: malformed, or a MAC no current secret made
    * `:expired` — older than a year, or dated in the future
    * `:gone` — the card or the person no longer exists, or the card is archived
    * `:forbidden` — the person can no longer comment on the card
  """
  @spec verify(String.t(), Date.t()) ::
          {:ok, Card.t(), User.t()} | {:error, :invalid | :expired | :gone | :forbidden}
  def verify(token, today \\ Date.utc_today())

  def verify(token, today) when is_binary(token) do
    with {:ok, card_id, user_id, day} <- unpack(token),
         :ok <- fresh(day, today),
         {:ok, card, user} <- load(card_id, user_id) do
      if user |> Access.card_permission(card) |> Access.can_comment?(),
        do: {:ok, card, user},
        else: {:error, :forbidden}
    end
  end

  def verify(_, _), do: {:error, :invalid}

  defp unpack(token) do
    with {:ok, <<payload::binary-size(13), given::binary-size(@mac_bytes)>>} <-
           Base.decode32(String.upcase(token), padding: false),
         <<@version::8, card_id::40, user_id::40, day::16>> <- payload,
         true <-
           Enum.any?(Inbound.secrets(), &Plug.Crypto.secure_compare(mac(&1, payload), given)) do
      {:ok, card_id, user_id, day}
    else
      _ -> {:error, :invalid}
    end
  end

  defp fresh(day, today) do
    age = Date.diff(today, ~D[1970-01-01]) - day
    if age >= 0 and age <= @max_age_days, do: :ok, else: {:error, :expired}
  end

  defp load(card_id, user_id) do
    case {Repo.get(Card, card_id), Repo.get(User, user_id)} do
      {%Card{archived_at: nil} = card, %User{} = user} -> {:ok, card, user}
      _ -> {:error, :gone}
    end
  end

  defp mac(secret, payload) do
    key = :crypto.mac(:hmac, :sha256, secret, @context)
    :crypto.mac(:hmac, :sha256, key, payload) |> binary_part(0, @mac_bytes)
  end

  defp id(%{id: id}), do: id
  defp id(id) when is_integer(id), do: id
end
