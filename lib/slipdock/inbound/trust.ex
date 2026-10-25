defmodule Slipdock.Inbound.Trust do
  @moduledoc """
  Whether to act on an inbound message (#1240; the rules are W-1933's
  "Trust"). The address has already been resolved to the account it belongs
  to and what it points at; this says yes, or why not, in words the sender
  reads in the bounce.

  `automatic/1` comes first and is separate, because the answer to automatic
  mail is to drop it *without* a bounce: replying to an auto-responder is how
  mail loops start.

  Authentication is read from the topmost `Authentication-Results` or
  `ARC-Authentication-Results` header written by a server we trust: Cloudflare
  Email Routing, `mx.cloudflare.net` (W-1933, "Spike findings"). Receiving
  servers *prepend* their results, so anything further down could have been
  written by the sender and is ignored. `config :slipdock, :inbound,
  authserv_ids: [...]` changes the list.
  """

  alias Slipdock.{Access, Config}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Inbound.Message

  @authserv_ids ["mx.cloudflare.net"]

  # `:personal` is a personal Quick Add address: no board yet, and Quick Add
  # only offers boards the person can write to. `{:cards, board}` is one of
  # the board's card addresses, which also take mail from the board's
  # permitted senders (#1289, `Board.permitted_sender?/2`).
  @type target :: {:board, Board.t()} | {:cards, Board.t()} | {:card, Card.t()} | :personal

  @doc """
  Why `message` is automatic and must not be answered, or nil: an
  `Auto-Submitted` other than `no`, `Precedence: bulk/junk/list`, a
  `List-Id`, or our own sending address as the sender.
  """
  @spec automatic(Message.t()) :: String.t() | nil
  def automatic(%Message{} = message) do
    auto = message.auto_submitted |> to_string() |> String.downcase() |> String.trim()
    precedence = message.precedence |> to_string() |> String.downcase() |> String.trim()

    cond do
      auto != "" and not String.starts_with?(auto, "no") ->
        "Automatic mail (Auto-Submitted) is ignored."

      precedence in ["bulk", "junk", "list"] ->
        "Bulk or list mail is ignored."

      present?(message.list_id) ->
        "Mailing-list mail is ignored."

      own_address?(message.from) ->
        "Mail from Slipdock itself is ignored."

      true ->
        nil
    end
  end

  @doc """
  `:ok` when `user` may act on `target` by mail, or `{:reject, reason}`:

    * the account is gone or disabled
    * `From:` is not the account's address (nor, for a board's card
      address, one of the board's permitted senders)
    * neither DMARC nor an aligned DKIM signature passed
    * the account can no longer write to the board (or comment, for a card)
  """
  @spec check(Message.t(), User.t() | nil, target()) :: :ok | {:reject, String.t()}
  def check(%Message{} = message, user, target) do
    cond do
      not active?(user) ->
        {:reject, "This address is no longer active."}

      not (own_mail?(message, user) or permitted?(message, target)) ->
        {:reject, wrong_sender(target)}

      not authenticated?(message) ->
        {:reject,
         "We couldn't confirm this message came from #{message.from}: it passed neither DMARC nor DKIM."}

      not allowed?(user, target) ->
        {:reject, "You can no longer add to this board."}

      true ->
        :ok
    end
  end

  @doc """
  Whether the message passed DMARC, or carries a passing DKIM signature
  aligned with its `From:` domain, according to the trusted server's results.
  """
  @spec authenticated?(Message.t()) :: boolean()
  def authenticated?(%Message{from: from} = message) when is_binary(from) do
    domain = from |> String.split("@") |> List.last() |> String.downcase()

    case trusted_results(message) do
      nil ->
        false

      results ->
        Enum.any?(results, fn
          {"dmarc", "pass", props} ->
            aligned?(props["header.from"] || domain, domain)

          {"dkim", "pass", props} ->
            aligned?(props["header.d"] || domain_of(props["header.i"]), domain)

          _ ->
            false
        end)
    end
  end

  def authenticated?(_), do: false

  # The method results of the topmost header a trusted server wrote, as
  # {method, result, %{property => value}}; nil when there is none.
  defp trusted_results(%Message{authentication_results: headers}) do
    ids = Config.get(:inbound, [])[:authserv_ids] || @authserv_ids

    Enum.find_value(headers, fn {_name, value} ->
      [first | rest] = value |> String.split(";") |> Enum.map(&String.trim/1)

      # ARC-Authentication-Results opens with "i=N;", then the authserv-id.
      {id, rest} =
        if String.match?(first, ~r/^i=\d+$/),
          do: {List.first(rest), Enum.drop(rest, 1)},
          else: {first, rest}

      authserv = id |> to_string() |> String.split(~r/\s/, parts: 2) |> hd() |> String.downcase()
      if authserv in ids, do: Enum.flat_map(rest, &method/1)
    end)
  end

  # "dkim=pass (2048-bit key) header.d=example.com header.s=s1"
  defp method(clause) do
    clause = String.replace(clause, ~r/\([^)]*\)/, "")

    case String.split(clause, ~r/\s+/, trim: true) do
      [result | props] ->
        case String.split(result, "=", parts: 2) do
          [method, outcome] ->
            props =
              Map.new(props, fn prop ->
                case String.split(prop, "=", parts: 2) do
                  [k, v] -> {String.downcase(k), v |> String.trim("\"") |> String.downcase()}
                  [k] -> {String.downcase(k), ""}
                end
              end)

            [{String.downcase(method), String.downcase(outcome), props}]

          _ ->
            []
        end

      [] ->
        []
    end
  end

  # Relaxed alignment: the same domain, or one a subdomain of the other.
  defp aligned?(nil, _domain), do: false

  defp aligned?(signer, domain) do
    signer = String.downcase(signer)

    signer == domain or String.ends_with?(domain, "." <> signer) or
      String.ends_with?(signer, "." <> domain)
  end

  defp domain_of(nil), do: nil
  defp domain_of(identity), do: identity |> String.split("@") |> List.last()

  defp active?(%User{disabled_at: nil}), do: true
  defp active?(_), do: false

  defp own_mail?(%Message{from: from}, %User{email: email}) when is_binary(from),
    do: Slipdock.Email.normalize(from) == Slipdock.Email.normalize(email)

  defp own_mail?(_, _), do: false

  @doc """
  Whether `message` comes from somebody other than `user`: one of the
  board's permitted senders (#1289). What they send is written as `user`,
  so it says who it was really from.
  """
  @spec on_behalf?(Message.t(), User.t()) :: boolean()
  def on_behalf?(%Message{} = message, %User{} = user), do: not own_mail?(message, user)

  defp permitted?(%Message{from: from}, {:cards, %Board{} = board}),
    do: Board.permitted_sender?(board, from)

  defp permitted?(_message, _target), do: false

  defp wrong_sender({:cards, _board}),
    do:
      "Mail to this address has to come from the address of the account it belongs to, " <>
        "or from one the board's owner has allowed."

  defp wrong_sender(_target),
    do: "Mail to this address has to come from the address of the account it belongs to."

  defp allowed?(_user, :personal), do: true

  defp allowed?(user, {kind, %Board{} = board}) when kind in [:board, :cards],
    do: user |> Access.board_permission(board) |> Access.can_write?()

  defp allowed?(user, {:card, %Card{} = card}),
    do: user |> Access.card_permission(card) |> Access.can_comment?()

  defp own_address?(nil), do: false

  defp own_address?(from) do
    ours =
      case Slipdock.Mailer.from() do
        {_name, address} -> address
        address -> address
      end

    Slipdock.Email.normalize(from) == Slipdock.Email.normalize(to_string(ours))
  end

  defp present?(nil), do: false
  defp present?(value), do: String.trim(value) != ""
end
