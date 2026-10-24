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
  `Slipdock.Inbound.Cards`); `add-…` goes through Quick Add (#1248,
  `Slipdock.Inbound.QuickAdd`), which checks the board it picks itself;
  `page-…` makes or adds to a wiki page (#1251, `Slipdock.Inbound.Pages`),
  in the folder when the address is a folder's (#1277);
  `reply-…` comments on the card a notification was about (#1258,
  `Slipdock.Inbound.Replies`).
  """

  alias Slipdock.Inbound.{Cards, Pages, QuickAdd, Replies, ReplyToken, Tokens, Trust}
  alias Slipdock.Wiki.Folder

  @type request :: %{
          kind: String.t(),
          token: String.t() | nil,
          recipient: String.t(),
          sender: String.t() | nil,
          message: Slipdock.Inbound.Message.t()
        }

  # The kinds mail is acted on, and so the addresses the app hands out.
  @live [:card, :page, :add, :reply]

  @doc "Whether mail to addresses of `kind` (`:card`, `:page`, `:add`, `:reply`) is acted on yet."
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

  # A board's page address, or a folder's (#1277), whose page goes in it.
  def dispatch(%{kind: "page", recipient: recipient, message: message}) do
    with {:ok, {:page, user, target}} <- resolve(recipient),
         {board, opts} = page_target(target),
         :ok <- trust(message, user, {:board, board}) do
      case Pages.to_board(user, board, message, opts) do
        {:ok, attrs} -> {:ok, attrs}
        {:reject, reason} -> {:reject, reason, %{user_id: user.id}}
      end
    end
  end

  def dispatch(%{kind: "add", recipient: recipient, message: message}) do
    with {:ok, {:add, user, nil}} <- resolve(recipient),
         :ok <- trust(message, user, :personal) do
      case QuickAdd.capture(user, message) do
        {:ok, attrs} -> {:ok, attrs}
        {:reject, reason} -> {:reject, reason, %{user_id: user.id}}
      end
    end
  end

  def dispatch(%{kind: "reply", token: token, message: message}) do
    case ReplyToken.verify(token) do
      {:ok, card, user} ->
        with :ok <- trust(message, user, {:card, card}) do
          case Replies.to_card(user, card, message) do
            {:ok, attrs} -> {:ok, attrs}
            {:reject, reason} -> {:reject, reason, %{user_id: user.id}}
          end
        end

      {:error, why} ->
        {:reject, reply_refused(why), %{}}
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

  defp page_target(%Folder{board: board} = folder), do: {board, folder: folder}
  defp page_target(board), do: {board, []}

  # Every refusal of a reply address is said plainly, but a forged one is
  # not told what a real one would look like.
  defp reply_refused(:expired),
    do: "This reply address has expired. Comment on the card in Slipdock instead."

  defp reply_refused(:gone), do: "The card this reply was for has been deleted or archived."
  defp reply_refused(:forbidden), do: "You can no longer comment on this card."
  defp reply_refused(_), do: "No such address here."

  defp unresolved(:revoked),
    do: "This address is no longer in use: its owner has replaced it or turned it off."

  defp unresolved(:inactive), do: "This address is no longer active."
  defp unresolved(:archived), do: "This board is archived, so it doesn't take mail."
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
