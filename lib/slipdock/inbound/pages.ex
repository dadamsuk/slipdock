defmodule Slipdock.Inbound.Pages do
  @moduledoc """
  A wiki page from an email (#1252, W-1933 "Content"): what a message to a
  board's `page-…` address makes.

    * **Title** — the subject, with `Re:`, `Fwd:` and their kin stripped
      (`Slipdock.Inbound.Cards.title/1`), or `(no subject)`. A title another
      page already has is allowed, as it is anywhere in the wiki: the new page
      gets its own slug.
    * **Folder** — `Inbox`, made when the board has none. A subject of the
      form `[Design/Decisions] Title` files it in that folder instead, making
      any folder along the path that is missing.
    * **Body** — the message as Markdown, the same as a card's description
      (`Slipdock.Inbound.Cards.description/2`), with `cid:` images pointing at
      the files they arrived as. Its first line is the page's summary.
    * **Files** — every attachment, attached to the page. Any that don't fit
      the account's limits are left off and named at the end of the page.
    * **Who** — the address's owner, with `By email from <sender>` as the
      edit message and `email` as where the revision came from.

  Refusals come back as `{:reject, reason}` in words for the bounce.
  """

  alias Slipdock.{Boards, Quota, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Inbound.{Cards, Message}
  alias Slipdock.Wiki.{Folders, Page}

  @inbox "Inbox"
  @summary_max 300

  @doc """
  A page on `board` from `message`, made as `user`.
  `{:ok, %{page_id:, user_id:}}`, or `{:reject, reason}`.
  """
  @spec to_board(User.t(), Board.t(), Message.t()) :: {:ok, map()} | {:reject, String.t()}
  def to_board(%User{} = user, %Board{} = board, %Message{} = message) do
    {folder_path, title} = subject(message.subject)
    create(user, board, folder_path, title, message)
  end

  @doc """
  What a subject asks for: `{folder_path, title}`. `[a/b] Title` names the
  folder; anything else goes to `Inbox`.
  """
  @spec subject(String.t() | nil) :: {String.t(), String.t()}
  def subject(subject) do
    title = Cards.title(subject)

    case Regex.run(~r/^\[([^\]]*)\]\s*(.*)$/u, title) do
      [_, folder, rest] ->
        folder =
          folder |> String.split("/") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        {if(folder == [], do: @inbox, else: Enum.join(folder, "/")), Cards.title(rest)}

      nil ->
        {@inbox, title}
    end
  end

  ## Making the page -----------------------------------------------------------

  defp create(user, board, folder_path, title, message) do
    files = message.attachments
    body = Cards.description(message, fn _ -> nil end)

    with :ok <- room_for_files(board, body, files),
         :ok <- room_for_page(board),
         {:ok, folder} <- folder(board, folder_path, user) do
      attrs = %{
        "title" => title,
        "body" => body,
        "summary" => summary(body),
        "folder_id" => folder.id
      }

      case Wiki.create_page(board, attrs, write_opts(user, message)) do
        {:ok, page} ->
          attach(page, user, message)
          {:ok, %{page_id: page.id, user_id: user.id}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:reject, refusal(changeset)}

        {:error, _} ->
          {:reject, "The page couldn't be made from this message."}
      end
    end
  end

  # The folder named, found or made; `Inbox` by default. A folder made here
  # counts against nothing, so it is made before the page is checked.
  defp folder(board, path, user) do
    case Folders.find(board, path) do
      {:ok, folder} ->
        {:ok, folder}

      {:error, :not_found, _} ->
        case Folders.create(board, %{"name" => path}, user: user) do
          {:ok, folder} -> {:ok, folder}
          _ -> {:reject, "The folder “#{path}” couldn't be made on this board."}
        end
    end
  end

  @doc false
  def write_opts(user, %Message{} = message) do
    [user: user, via: "email", message: "By email from #{message.from || "an unknown sender"}"]
  end

  @doc "A page's summary from its body: the first line with any text, as plain as it comes."
  @spec summary(String.t() | nil) :: String.t() | nil
  def summary(body) do
    (body || "")
    |> String.split(~r/\r?\n/)
    |> Enum.map(&plain_line/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> String.slice(line, 0, @summary_max)
    end
  end

  # Heading marks, quote marks, bullets and emphasis off one line.
  defp plain_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^(#+|>+|[-*+]\s|\d+[.)]\s)\s*/u, "")
    |> String.replace(~r/[*_`]/u, "")
    |> String.trim()
  end

  ## Files ---------------------------------------------------------------------

  # As for a card: a message that is nothing but files is pointless without
  # them, so with no room for any it bounces rather than making an empty page.
  defp room_for_files(_board, _body, []), do: :ok

  defp room_for_files(board, body, files) do
    if String.trim(body) != "" do
      :ok
    else
      smallest = files |> Enum.map(&byte_size(&1.data)) |> Enum.min()

      case Quota.check_board(board, :storage, smallest) do
        {:error, kind} when kind != :trial_expired ->
          {:reject,
           "The account that owns this board is out of storage, so the attachments couldn't be kept and no page was made."}

        _ ->
          :ok
      end
    end
  end

  # Asked first so a full account bounces before a folder is made for nothing.
  defp room_for_page(board) do
    case Quota.check_board(board) do
      :ok -> :ok
      {:error, :trial_expired} -> {:reject, refusal(:trial)}
      {:error, _} -> {:reject, refusal(:items)}
    end
  end

  @doc """
  Attaches `message`'s files to `page`, then points the body's `cid:` images
  at them and names any that were left off at the end of the page.
  """
  @spec attach(Page.t(), User.t(), Message.t()) :: :ok
  def attach(%Page{} = page, user, %Message{} = message) do
    {stored, left_off} = store_all(page, message)

    body =
      if stored != %{} and inline_images?(message),
        do: Cards.description(message, cid_url(stored)),
        else: page.body

    body =
      case left_off do
        [] -> body
        files -> String.trim_trailing(body || "") <> "\n\n" <> left_off_note(files)
      end

    if body != page.body do
      {:ok, _} = Wiki.update_page(page, %{"body" => String.trim(body)}, write_opts(user, message))
    end

    :ok
  end

  @doc """
  Stores each of `message`'s attachments on `page`: `{stored, left_off}`,
  stored as a map of content id to attachment, left off as `{file, why}`.
  """
  def store_all(%Page{} = page, %Message{} = message) do
    {stored, left_off} =
      Enum.reduce(message.attachments, {%{}, []}, fn file, {stored, left_off} ->
        case store(page, file) do
          {:ok, attachment} ->
            {if(file.content_id, do: Map.put(stored, file.content_id, attachment), else: stored),
             left_off}

          {:error, why} ->
            {stored, [{file, why} | left_off]}
        end
      end)

    {stored, Enum.reverse(left_off)}
  end

  @doc false
  def cid_url(stored), do: fn id -> if a = stored[id], do: Boards.attachment_url(a) end

  defp store(page, file) do
    path = Path.join(System.tmp_dir!(), "slipdock-inbound-#{System.unique_integer([:positive])}")
    File.write!(path, file.data)

    try do
      meta = %{
        filename: file.filename,
        content_type: file.content_type,
        size: byte_size(file.data)
      }

      case Wiki.add_attachment(page, meta, path) do
        {:ok, attachment} ->
          {:ok, attachment}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, Quota.limit_kind(changeset) || :invalid}

        {:error, _} ->
          {:error, :invalid}
      end
    after
      File.rm(path)
    end
  end

  @doc false
  def left_off_note(files) do
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

  @doc false
  def inline_images?(%Message{attachments: a}),
    do: Enum.any?(a, &(&1.inline and &1.content_id != nil))

  ## Plumbing ------------------------------------------------------------------

  defp refusal(%Ecto.Changeset{} = changeset) do
    case Quota.limit_kind(changeset) do
      nil -> "The page couldn't be made from this message."
      kind -> refusal(kind)
    end
  end

  defp refusal(:items),
    do:
      "The account that owns this board is full, so no page was made. Archiving or deleting something finished with makes room."

  defp refusal(:trial),
    do: "The free trial on the account that owns this board has run out, so no page was made."

  defp refusal(:storage),
    do: "The account that owns this board is out of storage, so no page was made."

  defp refusal(_), do: "The page couldn't be made from this message."
end
