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

  When the card has an open wait on the person replying, the reply answers
  it instead (#1259, `Slipdock.Inbound.WaitReply`), as `slipdock answer`
  would; one that can't be read as an answer is a comment, and the wait
  stays open with a comment saying why.

  The address and the sender have been checked by then
  (`Slipdock.Inbound.Dispatcher`).
  """

  import Ecto.Query

  alias Slipdock.{Actor, Boards, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Comment, Wait}
  alias Slipdock.Inbound.{Cards, Message, Trim, WaitReply}

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

      said = body(message, cid)
      links = links(stored, message)

      case waiting_on(card, user) do
        %Wait{} = wait when said != "" -> answer(user, card, wait, said, links, left_off)
        _ -> comment(user, card, join(said, links), left_off)
      end
    end
  end

  # The card's open wait, when it waits on this very person (#1259).
  defp waiting_on(card, user) do
    case Boards.current_wait(card) do
      %Wait{on_user_id: id} = wait when id == user.id -> wait
      _ -> nil
    end
  end

  # The reply as the wait's answer; the answer is the comment
  # `Boards.answer_wait/3` posts, with any files linked in one after it.
  # A reply that can't be read as an answer is a plain comment, with a
  # second saying why the wait is still open.
  defp answer(user, card, wait, said, links, left_off) do
    with {:ok, attrs} <- WaitReply.attrs(wait, said),
         {:ok, _closed} <- Boards.answer_wait(wait, Actor.email(user), attrs) do
      if links != "", do: Boards.add_comment(card, links, by: user)
      if left_off != [], do: Boards.add_comment(card, Cards.left_off_comment(left_off), by: user)
      {:ok, %{comment_id: answer_comment_id(card, user), user_id: user.id}}
    else
      {:error, why} ->
        with {:ok, attrs} <- comment(user, card, join(said, links), left_off) do
          Boards.add_comment(
            card,
            "**Not taken as the answer** to “#{wait.needs}”: #{why}. The wait is still open.",
            by: user
          )

          {:ok, attrs}
        end
    end
  end

  defp answer_comment_id(card, user) do
    Repo.one(
      from(c in Comment,
        where: c.card_id == ^card.id and c.user_id == ^user.id,
        order_by: [desc: c.id],
        limit: 1,
        select: c.id
      )
    )
  end

  defp join(said, links), do: [said, links] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

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
