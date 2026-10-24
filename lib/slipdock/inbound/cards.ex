defmodule Slipdock.Inbound.Cards do
  @moduledoc """
  A card from an email (#1247, W-1933 "Content"): what a message to a
  `card-…` address makes, and the part of it a personal `add-…` address
  shares (#1248).

    * **Title** — the subject, with `Re:`, `Fwd:` and their kin stripped,
      or `(no subject)`.
    * **Description** — the body as Markdown (`Slipdock.Inbound.Trim`), with
      `cid:` images pointing at the files they arrived as. A forward opens
      with a line naming who first sent it, and when.
    * **Files** — every attachment, uploaded to the card. Any that don't fit
      the account's limits are left off and a comment on the card names them.
    * **Who** — the address's owner, through the `email` door
      (`Slipdock.Actor.email/1`), so the timeline says who added it.

  Refusals come back as `{:reject, reason}` in words for the bounce: a full
  account, an expired trial, or a message that is nothing but files when
  there is no room to keep them.
  """

  import Ecto.Query

  alias Slipdock.{Actor, Boards, Quota, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Inbound.{Message, Trim}

  @prefix ~r/^\s*((re|fwd?|aw|wg|sv|vs|tr|rv|antw|r|enc)\s*(\[\d+\])?\s*:\s*)+/iu
  @title_max 200
  @no_subject "(no subject)"

  @doc """
  A card on `board`'s ready list from `message`, made as `user`.
  `{:ok, %{card_id:, user_id:}}`, or `{:reject, reason}`.
  """
  @spec to_board(User.t(), Board.t(), Message.t()) :: {:ok, map()} | {:reject, String.t()}
  def to_board(%User{} = user, %Board{} = board, %Message{} = message) do
    case ready_column(board) do
      nil -> {:reject, "This board has no lists to put a card on."}
      column -> create(user, column, %{"title" => title(message.subject)}, message)
    end
  end

  @doc """
  The card itself: `attrs` (a title at least) plus the description and the
  files from `message`, in `column`, as `user`. Shared with Quick Add mail,
  which works the title and list out of the subject first.
  """
  @spec create(User.t(), Column.t(), map(), Message.t()) :: {:ok, map()} | {:reject, String.t()}
  def create(%User{} = user, %Column{} = column, attrs, %Message{} = message) do
    files = message.attachments
    description = description(message, fn _ -> nil end)

    with :ok <- room_for_files(column, description, files) do
      extra = attrs["description"]
      attrs = Map.put(attrs, "description", join_description(extra, description))

      case Boards.create_card(column, attrs, by: user, actor: Actor.email(user)) do
        {:ok, card} ->
          attach(card, user, message, extra)
          {:ok, %{card_id: card.id, user_id: user.id}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:reject, refusal(changeset)}
      end
    end
  end

  @doc "The title a subject makes: reply and forward prefixes off, at most 200 characters."
  @spec title(String.t() | nil) :: String.t()
  def title(subject) do
    case subject |> to_string() |> String.replace(@prefix, "") |> String.trim() do
      "" -> @no_subject
      title -> String.slice(title, 0, @title_max)
    end
  end

  @doc "Whether a subject marks a forward (`Fwd:`, `Fw:`, `WG:`, `TR:`…)."
  @spec forward?(String.t() | nil) :: boolean()
  def forward?(subject),
    do: Regex.match?(~r/^\s*((re|aw|sv)\s*:\s*)*(fwd?|wg|tr|rv|enc)\s*:/iu, to_string(subject))

  @doc """
  The description `message` makes. `cid` maps an inline image's content id to
  its URL (nil leaves it out). The HTML is used when it holds inline images
  and the text part can't show them.
  """
  @spec description(Message.t(), (String.t() -> String.t() | nil)) :: String.t()
  def description(%Message{} = message, cid) do
    body =
      if inline_images?(message) and present?(message.html),
        do: Trim.markdown(%{message | text: nil}, cid: cid),
        else: Trim.markdown(message, cid: cid)

    case forward_line(message) do
      nil -> body
      line -> String.trim(line <> "\n\n" <> body)
    end
  end

  @doc """
  For a forward, the line that opens the description: who sent the original,
  and when, from the forwarded headers in the body or the attached message.
  Nil for anything else, or when they can't be found.
  """
  @spec forward_line(Message.t()) :: String.t() | nil
  def forward_line(%Message{} = message) do
    with true <- forward?(message.subject) or attached_message?(message),
         {from, date} when not is_nil(from) <- forwarded_from(message) do
      "*Forwarded: first sent by #{from}#{if date, do: " on #{date}", else: ""}.*"
    else
      _ -> nil
    end
  end

  ## The forwarded headers -----------------------------------------------------

  defp forwarded_from(message) do
    attached(message) || inline_forward(message.text || html_text(message.html))
  end

  defp attached(%Message{attachments: attachments}) do
    Enum.find_value(attachments, fn
      %{content_type: "message/rfc822", data: data} ->
        case Message.parse(data) do
          {:ok, inner} when not is_nil(inner.from) ->
            {sender(inner.from_name, inner.from), Message.header(inner.headers, "date")}

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  # Gmail's "---------- Forwarded message ---------", Apple Mail's "Begin
  # forwarded message:", Outlook's "-----Original Message-----" or a bare
  # "From:" block: the first From: and Date:/Sent: after the marker.
  defp inline_forward(nil), do: nil

  defp inline_forward(text) do
    lines = String.split(text, ~r/\r?\n/)

    start =
      Enum.find_index(lines, fn line ->
        line = line |> String.trim() |> String.trim_leading(">") |> String.trim()

        Regex.match?(
          ~r/^(-+\s*(forwarded message|original message|message transféré|weitergeleitete nachricht)\s*-+|begin forwarded message:)/iu,
          line
        )
      end)

    if start do
      block =
        lines
        |> Enum.drop(start + 1)
        |> Enum.take(12)
        |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(">") |> String.trim()))

      from = field(block, ~w(from von de))
      date = field(block, ~w(date sent datum gesendet envoyé))
      if from, do: {String.replace(from, ~r/\*+/, ""), date && String.replace(date, ~r/\*+/, "")}
    end
  end

  defp field(lines, names) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^\**([\p{L} ]+?)\**\s*:\**\s*(.+)$/u, line) do
        [_, name, value] -> if String.downcase(String.trim(name)) in names, do: String.trim(value)
        _ -> nil
      end
    end)
  end

  defp html_text(nil), do: nil
  defp html_text(html), do: Slipdock.Inbound.HtmlToMarkdown.convert(html)

  defp sender(nil, address), do: address
  defp sender("", address), do: address
  defp sender(name, address), do: "#{name} <#{address}>"

  defp attached_message?(%Message{attachments: a}),
    do: Enum.any?(a, &(&1.content_type == "message/rfc822"))

  ## Files ---------------------------------------------------------------------

  # A message that is nothing but files is pointless without them: with no
  # room for any, it bounces rather than making an empty card.
  defp room_for_files(_column, _description, []), do: :ok

  defp room_for_files(column, description, files) do
    if present?(description) do
      :ok
    else
      smallest = files |> Enum.map(&byte_size(&1.data)) |> Enum.min()

      case Quota.check_board(column, :storage, smallest) do
        :ok ->
          :ok

        {:error, :trial_expired} ->
          :ok

        {:error, _} ->
          {:reject,
           "The account that owns this board is out of storage, so the attachments couldn't be kept and no card was made."}
      end
    end
  end

  @doc """
  Uploads `message`'s attachments to `card`, then points its description's
  `cid:` images at them (after `extra`, whatever the description opened
  with) and names in a comment any that were left off.
  """
  @spec attach(Card.t(), User.t(), Message.t(), String.t() | nil) :: :ok
  def attach(%Card{} = card, user, %Message{} = message, extra) do
    {stored, left_off} =
      Enum.reduce(message.attachments, {%{}, []}, fn file, {stored, left_off} ->
        case store(card, file) do
          {:ok, attachment} ->
            {if(file.content_id, do: Map.put(stored, file.content_id, attachment), else: stored),
             left_off}

          {:error, why} ->
            {stored, [{file, why} | left_off]}
        end
      end)

    if stored != %{} and inline_images?(message) do
      cid = fn id -> if a = stored[id], do: Boards.attachment_url(a) end
      description = join_description(extra, description(message, cid))

      if description != card.description do
        {:ok, _} =
          Boards.update_card(Repo.get!(Card, card.id), %{"description" => description},
            by: user,
            actor: Actor.email(user)
          )
      end
    end

    if left_off != [] do
      Boards.add_comment(card, left_off_comment(Enum.reverse(left_off)), by: user)
    end

    :ok
  end

  @doc """
  One attachment from a message, uploaded to `card`: `{:ok, attachment}`,
  or `{:error, why}` with the limit that stopped it (`:storage`, `:items`,
  `:trial`) or `:invalid`.
  """
  def store(%Card{} = card, file) do
    path = Path.join(System.tmp_dir!(), "slipdock-inbound-#{System.unique_integer([:positive])}")
    File.write!(path, file.data)

    try do
      meta = %{
        filename: file.filename,
        content_type: file.content_type,
        size: byte_size(file.data)
      }

      case Boards.add_attachment(card, meta, path) do
        {:ok, attachment} ->
          {:ok, attachment}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, Quota.limit_kind(changeset) || :invalid}
      end
    after
      File.rm(path)
    end
  end

  @doc "The comment naming files that came with a message but weren't kept."
  def left_off_comment(files) do
    lines =
      Enum.map(files, fn {file, why} ->
        "- `#{file.filename}` (#{size(byte_size(file.data))}): #{why_left_off(why)}"
      end)

    Enum.join(
      ["**Not attached.** These files came with the email but weren't kept:", "" | lines],
      "\n"
    )
  end

  defp why_left_off(:storage), do: "the account's storage is full"
  defp why_left_off(:items), do: "the account's item limit is reached"
  defp why_left_off(:trial), do: "the free trial has run out"
  defp why_left_off(_), do: "it couldn't be stored"

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  ## Plumbing ------------------------------------------------------------------

  @doc "The bounce for a card the database refused: which limit, in plain words."
  @spec refusal(Ecto.Changeset.t()) :: String.t()
  def refusal(changeset) do
    case Quota.limit_kind(changeset) do
      :items ->
        "The account that owns this board is full, so no card was made. Archiving or deleting something finished with makes room."

      :trial ->
        "The free trial on the account that owns this board has run out, so no card was made."

      :storage ->
        "The account that owns this board is out of storage, so no card was made."

      _ ->
        "The card couldn't be made from this message."
    end
  end

  defp ready_column(%Board{id: board_id}) do
    columns = Repo.all(from(c in Column, where: c.board_id == ^board_id, order_by: c.position))
    SlipdockWeb.APIGuide.list_roles(columns).ready || List.first(columns)
  end

  defp join_description(nil, body), do: body
  defp join_description("", body), do: body
  defp join_description(extra, ""), do: extra
  defp join_description(extra, body), do: extra <> "\n\n" <> body

  defp inline_images?(%Message{attachments: a}),
    do: Enum.any?(a, &(&1.inline and &1.content_id != nil))

  defp present?(nil), do: false
  defp present?(value), do: String.trim(value) != ""
end
