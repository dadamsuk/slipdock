defmodule Slipdock.Inbound.Replies do
  @moduledoc """
  A reply to a notification email about a card (#1258, W-1933): mail to the
  `reply-<signed>@…` address on its `Reply-To` (`Slipdock.Inbound.ReplyToken`)
  becomes a comment on that card, by the person the email was sent to.

    * **The comment** is the reply with quoted history and signatures taken
      off (`Slipdock.Inbound.Trim`, strictly: a reply that is nothing but
      quote adds nothing). Inline images point at the files they arrived as.
    * **Files** go to the card, and the comment links to each one. Any that
      don't fit the account's limits are left off and named in a comment.
    * **Mentions** in the reply tell the people mentioned, as a comment
      typed on the card does (`Slipdock.Boards.add_comment/3`), and never
      the sender.
    * **Nothing to add**: a reply that is empty once trimmed, with no
      files, bounces.

  The address and the sender have been checked by then
  (`Slipdock.Inbound.Dispatcher`).
  """

  alias Slipdock.Boards
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Card
  alias Slipdock.Inbound.{Cards, Message, Trim}

  @nothing "There was nothing to add: the reply was empty once the quoted message was taken off."

  @doc """
  The comment `message` makes on `card`, by `user`: `{:ok, %{comment_id:,
  user_id:}}`, or `{:reject, reason}`.
  """
  @spec to_card(User.t(), Card.t(), Message.t()) :: {:ok, map()} | {:reject, String.t()}
  def to_card(%User{} = user, %Card{} = card, %Message{} = message) do
    files = message.attachments

    if body(message, fn _ -> nil end) == "" and files == [] do
      {:reject, @nothing}
    else
      {stored, left_off} = store_all(card, files)
      cid = fn id -> if a = stored[{:cid, id}], do: Boards.attachment_url(a) end

      text =
        [body(message, cid), links(stored, message)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      comment(user, card, text, left_off)
    end
  end

  # Only files, and none of them kept: nothing reached the card.
  defp comment(_user, _card, "", left_off), do: {:reject, files_refused(left_off)}

  defp comment(user, card, text, left_off) do
    case Boards.add_comment(card, text, by: user) do
      {:ok, comment} ->
        if left_off != [],
          do: Boards.add_comment(card, Cards.left_off_comment(left_off), by: user)

        {:ok, %{comment_id: comment.id, user_id: user.id}}

      {:error, _} ->
        {:reject, "The reply couldn't be added to the card."}
    end
  end

  defp files_refused([{_, :trial} | _]),
    do:
      "The free trial on the account that owns this board has run out, so the files couldn't be kept."

  defp files_refused(_),
    do: "The account that owns this board is out of storage, so the files couldn't be kept."

  @doc """
  The new part of a reply, as Markdown, "" when it adds nothing. The HTML is
  used when it holds inline images and the text part can't show them.
  """
  @spec body(Message.t(), (String.t() -> String.t() | nil)) :: String.t()
  def body(%Message{} = message, cid) do
    message =
      if inline_images?(message) and present?(message.html),
        do: %{message | text: nil},
        else: message

    Trim.markdown(message, cid: cid, strict: true)
  end

  # Every file stored on the card, keyed by its position and, for an inline
  # image, its content id too; and the ones that couldn't be.
  defp store_all(card, files) do
    files
    |> Enum.with_index()
    |> Enum.reduce({%{}, []}, fn {file, i}, {stored, left_off} ->
      case Cards.store(card, file) do
        {:ok, attachment} ->
          stored = Map.put(stored, i, {file, attachment})

          stored =
            if file.content_id,
              do: Map.put(stored, {:cid, file.content_id}, attachment),
              else: stored

          {stored, left_off}

        {:error, why} ->
          {stored, [{file, why} | left_off]}
      end
    end)
    |> then(fn {stored, left_off} -> {stored, Enum.reverse(left_off)} end)
  end

  # A link to each stored file the body doesn't already show inline.
  defp links(stored, message) do
    shown_inline = inline_images?(message) and present?(message.html)

    stored
    |> Enum.filter(fn {key, _} -> is_integer(key) end)
    |> Enum.sort_by(fn {i, _} -> i end)
    |> Enum.reject(fn {_, {file, _}} -> shown_inline and file.inline and file.content_id end)
    |> Enum.map(fn {_, {file, attachment}} ->
      "- [#{file.filename}](#{Boards.attachment_url(attachment)})"
    end)
    |> case do
      [] -> ""
      lines -> Enum.join(["**Attached:**" | lines], "\n")
    end
  end

  defp inline_images?(%Message{attachments: a}),
    do: Enum.any?(a, &(&1.inline and &1.content_id != nil))

  defp present?(nil), do: false
  defp present?(value), do: String.trim(value) != ""
end
