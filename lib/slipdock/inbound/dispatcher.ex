defmodule Slipdock.Inbound.Dispatcher do
  @moduledoc """
  What an inbound message *means*, by the kind of address it was sent to:
  `card-…`, `page-…`, `add-…` or `reply-…` (W-1933). The endpoint has already
  checked the signature, the size and the rate limits; this resolves the
  address, decides whether to trust the sender and writes what the mail asks
  for.

  Answers `{:ok, attrs}` with what was created (`card_id`, `page_id`,
  `comment_id`) and whose it was (`user_id`), or `{:reject, reason, attrs}`
  with a reason the sender reads in the bounce.

  `card-…` makes a card on the board's ready list (#1247,
  `Slipdock.Inbound.Cards`). The kinds not acted on yet are refused; the
  epics after #1233 fill them in, one clause each.
  """

  alias Slipdock.Inbound.{Cards, Tokens, Trust}

  @type request :: %{
          kind: String.t(),
          token: String.t() | nil,
          recipient: String.t(),
          sender: String.t() | nil,
          message: Slipdock.Inbound.Message.t()
        }

  # The kinds mail is acted on, and so the addresses the app hands out.
  @live [:card, :add]

  @doc "Whether mail to addresses of `kind` (`:card`, `:page`, `:add`) is acted on yet."
  @spec live?(atom()) :: boolean()
  def live?(kind), do: kind in @live

  @spec dispatch(request()) :: {:ok, map()} | {:reject, String.t(), map()}
  def dispatch(%{kind: "unknown"}), do: {:reject, "No such address here.", %{}}

  def dispatch(%{kind: "card", recipient: recipient, message: message}) do
    with {:ok, {:card, user, board}} <- resolve(recipient),
         :ok <- trust(message, user, {:board, board}) do
      case Cards.to_board(user, board, message) do
        {:ok, attrs} -> {:ok, attrs}
        {:reject, reason} -> {:reject, reason, %{user_id: user.id}}
      end
    end
  end

  def dispatch(%{kind: _kind}),
    do: {:reject, "Mail to this address isn't set up on this server yet.", %{}}

  @doc """
  The owner and target of an address, or the bounce for one that resolves
  to nothing usable (`Slipdock.Inbound.Tokens.resolve/1`).
  """
  @spec resolve(String.t()) :: {:ok, tuple()} | {:reject, String.t(), map()}
  def resolve(recipient) do
    case Tokens.resolve(recipient) do
      {:ok, found} -> {:ok, found}
      {:error, why} -> {:reject, unresolved(why), %{}}
    end
  end

  defp unresolved(:revoked),
    do: "This address is no longer in use: its owner has replaced it or turned it off."

  defp unresolved(:inactive), do: "This address is no longer active."
  defp unresolved(:archived), do: "This board is archived, so it doesn't take new cards."
  defp unresolved(:forbidden), do: "You can no longer add to this board."
  defp unresolved(_), do: "No such address here."

  @doc "`Slipdock.Inbound.Trust.check/3`, as the dispatcher answers."
  def trust(message, user, target) do
    case Trust.check(message, user, target) do
      :ok -> :ok
      {:reject, reason} -> {:reject, reason, %{user_id: user.id}}
    end
  end
end
