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

  Mail to a folder's own address (#1277) makes the page in that folder rather
  than `Inbox`, and `[Sub/Path] Title` names a folder beneath it.

  A subject of the form `+ Title` adds to the page of that title instead
  (#1253): a `## <date> — <sender>` section with the body under it, through
  `Slipdock.Wiki.append/3`, so the page's history records it. The body goes
  in whole, however long: the wiki's append takes any length, and the
  inbound endpoint's size cap is the only limit. Files are attached to the
  page. No page of that title bounces, naming up to five near matches.

  Refusals come back as `{:reject, reason}` in words for the bounce.
  """

  import Ecto.Query

  alias Slipdock.{Boards, Quota, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Inbound.{Cards, Message}
  alias Slipdock.Wiki.{Folder, Folders, Page}

  @inbox "Inbox"
  @summary_max 300

  @doc """
  A page on `board` from `message`, made as `user`; with `folder:`, in that
  folder of the board's. `{:ok, %{page_id:, user_id:}}`, or `{:reject, reason}`.
  """
  @spec to_board(User.t(), Board.t(), Message.t(), keyword()) ::
          {:ok, map()} | {:reject, String.t()}
  def to_board(%User{} = user, %Board{} = board, %Message{} = message, opts \\ []) do
    base = if folder = opts[:folder], do: Folders.path(folder)

    case subject(message.subject, base) do
      {:append, title} -> append(user, board, title, message)
      # Straight into the address's folder, not found again by its path,
      # which another folder of the same name could share.
      {^base, title} when not is_nil(base) -> create(user, board, opts[:folder], title, message)
      {folder_path, title} -> create(user, board, folder_path, title, message)
    end
  end

  @doc """
  What a subject asks for: `{:append, title}` for `+ Title`, otherwise
  `{folder_path, title}` for a new page. `[a/b] Title` names the folder;
  anything else goes to `Inbox`. With a `base` folder path (a folder's own
  address), the page goes there, and `[a/b]` is beneath it.
  """
  @spec subject(String.t() | nil, String.t() | nil) :: {:append | String.t(), String.t()}
  def subject(subject, base \\ nil) do
    title = Cards.title(subject)

    cond do
      String.starts_with?(title, "+") ->
        {:append, title |> String.trim_leading("+") |> String.trim()}

      match = Regex.run(~r/^\[([^\]]*)\]\s*(.*)$/u, title) ->
        folder_and_title(match, base)

      true ->
        {base || @inbox, title}
    end
  end

  defp folder_and_title([_, folder, rest], base) do
    folder =
      folder |> String.split("/") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    path =
      case {folder, base} do
        {[], nil} -> @inbox
        {[], base} -> base
        {folder, nil} -> Enum.join(folder, "/")
        {folder, base} -> Enum.join([base | folder], "/")
      end

    {path, Cards.title(rest)}
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
  defp folder(_board, %Folder{} = folder, _user), do: {:ok, folder}

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

  ## Adding to a page (#1253) -------------------------------------------------

  defp append(_user, _board, "", _message),
    do: {:reject, "Name the page to add to after the +, as in “+ Journal”. Nothing was added."}

  defp append(user, board, title, message) do
    with {:ok, page} <- find_page(board, title),
         :ok <- something_to_add(message) do
      {stored, left_off} = store_all(page, message)
      cid = if inline_images?(message), do: cid_url(stored), else: fn _ -> nil end

      body =
        case left_off do
          [] -> Cards.description(message, cid)
          files -> String.trim(Cards.description(message, cid) <> "\n\n" <> left_off_note(files))
        end

      text =
        "## #{today(user)} — #{sender(message)}" <> if(body == "", do: "", else: "\n\n" <> body)

      case Wiki.append(page, text, write_opts(user, message)) do
        {:ok, page} -> {:ok, %{page_id: page.id, user_id: user.id}}
        _ -> {:reject, "The text couldn't be added to “#{page.title}”."}
      end
    end
  end

  @doc """
  The live page on `board` titled `title`, ignoring case: the most lately
  changed when several share it. Archived pages and templates don't count.
  """
  @spec find_page(Board.t(), String.t()) :: {:ok, Page.t()} | {:reject, String.t()}
  def find_page(%Board{id: board_id}, title) do
    pages =
      Repo.all(
        from(p in Page,
          where: p.board_id == ^board_id and is_nil(p.archived_at) and not p.template,
          order_by: [desc: p.updated_at, desc: p.id]
        )
      )

    wanted = String.downcase(title)

    case Enum.find(pages, &(String.downcase(&1.title) == wanted)) do
      %Page{} = page -> {:ok, page}
      nil -> {:reject, no_such_page(title, pages)}
    end
  end

  defp no_such_page(title, pages) do
    case near_matches(title, pages) do
      [] ->
        "There's no page called “#{title}” on this board, so nothing was added."

      near ->
        "There's no page called “#{title}” on this board, so nothing was added. Did you mean: " <>
          Enum.map_join(near, ", ", &"“#{&1}”") <> "?"
    end
  end

  @doc "Up to five titles in `pages` close to `title`, closest first."
  @spec near_matches(String.t(), [Page.t()]) :: [String.t()]
  def near_matches(title, pages) do
    wanted = String.downcase(title)

    pages
    |> Enum.map(& &1.title)
    |> Enum.uniq()
    |> Enum.map(fn t ->
      lower = String.downcase(t)
      contains = String.contains?(lower, wanted) or String.contains?(wanted, lower)
      {if(contains, do: 1.0, else: String.jaro_distance(lower, wanted)), t}
    end)
    |> Enum.filter(fn {score, _} -> score >= 0.8 end)
    |> Enum.sort_by(fn {score, t} -> {-score, String.length(t)} end)
    |> Enum.take(5)
    |> Enum.map(&elem(&1, 1))
  end

  defp something_to_add(%Message{attachments: [_ | _]}), do: :ok

  defp something_to_add(message) do
    if Cards.description(message, fn _ -> nil end) == "",
      do: {:reject, "The message had nothing in it to add, so the page wasn't changed."},
      else: :ok
  end

  # The day in the sender's own timezone when they've set one.
  defp today(%User{timezone: tz}) when is_binary(tz) and tz != "" do
    case DateTime.now(tz) do
      {:ok, now} -> DateTime.to_date(now)
      _ -> Date.utc_today()
    end
  end

  defp today(_user), do: Date.utc_today()

  defp sender(%Message{from_name: name}) when is_binary(name) and name != "", do: name
  defp sender(%Message{from: from}) when is_binary(from), do: from
  defp sender(_), do: "unknown sender"

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
