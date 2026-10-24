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

  Nothing is set up yet: every kind is refused. The epics after #1233 fill the
  kinds in, one clause each.
  """

  @type request :: %{
          kind: String.t(),
          token: String.t() | nil,
          recipient: String.t(),
          sender: String.t() | nil,
          message: Slipdock.Inbound.Message.t()
        }

  @spec dispatch(request()) :: {:ok, map()} | {:reject, String.t(), map()}
  def dispatch(%{kind: "unknown"}), do: {:reject, "No such address here.", %{}}

  def dispatch(%{kind: _kind}),
    do: {:reject, "Mail to this address isn't set up on this server yet.", %{}}
end
