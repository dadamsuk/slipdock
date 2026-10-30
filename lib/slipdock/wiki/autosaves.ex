defmodule Slipdock.Wiki.Autosaves do
  @moduledoc """
  Unsaved work in the wiki's editor (#1532). The editor keeps one row per page
  being edited, and one per new page being written, up to date as the person
  types. A real save or a Cancel removes it; otherwise it waits for them to
  come back, for `ttl_days/0` days.

  This is also what lets an image go into a page that does not exist yet: the
  file is held under `autosaves/` and `adopt/2` turns it into the new page's
  attachment as the page is created. Held files are not attachments, so they
  count towards no quota; `add_file/4` checks the board's storage before taking
  one, and a person can hold `max_held_bytes/0` at most.

  Everything here is one person's: every read is by user, and nothing here
  reaches the page, its history, search or sync until they save.

  The shared-page editor (#1534) keeps its work here too. Its writers may not be
  able to read the board, so theirs is listed by `shared_with/1`, on Shared with
  me, rather than by `on_board/2`.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.{Attachment, Board}
  alias Slipdock.{Access, Quota, Repo, Wiki}
  alias Slipdock.Wiki.{Autosave, AutosaveFile, Page, Sharing}

  @ttl_days 30
  @max_held_bytes 500 * 1024 * 1024
  @fields ~w(title summary body status folder_id icon color)

  def ttl_days, do: @ttl_days

  @doc "The form fields an auto-save keeps."
  def fields, do: @fields

  @doc "Whether the form still says what the page says: nothing to keep."
  def unchanged?(%Page{} = page, params) do
    params
    |> Map.take(@fields)
    |> Enum.all?(fn {field, value} ->
      form_text(value) == form_text(Map.get(page, String.to_existing_atom(field)))
    end)
  end

  defp form_text(nil), do: ""
  defp form_text(value), do: value |> to_string() |> String.replace("\r\n", "\n")

  @doc "The most a person can hold in images not saved yet: 500 MB."
  def max_held_bytes, do: Slipdock.Config.get(:autosave_max_held_bytes, @max_held_bytes)

  @doc "`user`'s unsaved edit of `page`, or nil."
  def for_page(%User{id: user_id}, %Page{id: page_id}),
    do: Repo.get_by(Autosave, user_id: user_id, page_id: page_id)

  @doc "`user`'s unsaved new page on `board`, by id, or nil."
  def get_new(%User{id: user_id}, %Board{id: board_id}, id) do
    with {id, ""} <- Integer.parse(to_string(id)) do
      Repo.one(
        from(a in Autosave,
          where:
            a.id == ^id and a.user_id == ^user_id and a.board_id == ^board_id and
              is_nil(a.page_id)
        )
      )
    else
      _ -> nil
    end
  end

  @doc "Everything `user` has unsaved on `board`, the latest first."
  def on_board(%User{id: user_id}, %Board{id: board_id}) do
    from(a in Autosave,
      where: a.user_id == ^user_id and a.board_id == ^board_id,
      order_by: [desc: a.updated_at, desc: a.id],
      preload: [:page]
    )
    |> Repo.all()
  end

  @doc """
  The edits `user` has unsaved on pages shared with them to write, the latest
  first. A board's own writers find theirs on its wiki instead, and a share
  taken back takes the entry with it: the row waits, unlisted, for its expiry.
  """
  def shared_with(%User{id: user_id} = user) do
    from(a in Autosave,
      join: p in assoc(a, :page),
      where: a.user_id == ^user_id and is_nil(p.archived_at),
      order_by: [desc: a.updated_at, desc: a.id],
      preload: [page: p]
    )
    |> Repo.all()
    |> Enum.filter(fn %{page: page} ->
      Access.can_write?(Access.share_permission(user, page)) and
        not Sharing.board_writer?(user, page.board_id)
    end)
  end

  @doc "One of `user`'s, on `board`, by id, or nil."
  def get(%User{id: user_id}, %Board{id: board_id}, id) do
    Repo.one(
      from(a in Autosave,
        where: a.id == ^id and a.user_id == ^user_id and a.board_id == ^board_id
      )
    )
  end

  @doc """
  Keeps the form as it stands: one row a page per person, however often it is
  called. `autosave` is the row for a new page, nil before there is one.
  """
  def save(%User{} = user, %Board{} = board, %Page{} = page, _autosave, attrs, base_hash) do
    %Autosave{user_id: user.id, board_id: board.id, page_id: page.id}
    |> Autosave.changeset(%{attrs: attrs, base_hash: base_hash})
    |> Repo.insert(
      on_conflict: {:replace, [:attrs, :base_hash, :updated_at]},
      conflict_target: {:unsafe_fragment, "(user_id, page_id) WHERE page_id IS NOT NULL"},
      returning: true
    )
  end

  def save(%User{} = user, %Board{} = board, nil, %Autosave{} = autosave, attrs, _base_hash) do
    case autosave |> Autosave.changeset(%{attrs: attrs}) |> Repo.update(stale_error_field: :id) do
      {:ok, saved} -> {:ok, saved}
      # Discarded in another tab, and this one is still being typed in.
      {:error, _} -> save(user, board, nil, nil, attrs, nil)
    end
  end

  def save(%User{} = user, %Board{} = board, nil, nil, attrs, _base_hash) do
    %Autosave{user_id: user.id, board_id: board.id}
    |> Autosave.changeset(%{attrs: attrs})
    |> Repo.insert()
  end

  @doc """
  Holds an image for an unsaved page. Answers `{:ok, file}`, or `{:error,
  message}` to show the person: the board's storage is full, they already hold
  too much, or it is not an image.
  """
  def add_file(%Autosave{} = autosave, %User{} = user, meta, source) do
    size = Map.get(meta, :size) || File.stat!(source).size
    key = Path.join("autosaves/#{autosave.id}", Ecto.UUID.generate() <> ext(meta[:filename]))

    changeset =
      %AutosaveFile{autosave_id: autosave.id}
      |> AutosaveFile.changeset(%{
        filename: meta[:filename],
        content_type: meta[:content_type],
        size: size,
        key: key
      })

    with :ok <- check_room(autosave, user, size),
         {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- Boards.put_file(source, key),
         {:ok, file} <- Repo.insert(changeset) do
      {:ok, file}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, %Ecto.Changeset{}} -> {:error, "That image could not be stored."}
      {:error, _reason} -> {:error, "That image could not be stored."}
    end
  end

  defp check_room(%Autosave{board_id: board_id}, %User{id: user_id}, size) do
    cond do
      held_bytes(user_id) + size > max_held_bytes() ->
        {:error, "You're holding too many images in unsaved pages. Save or discard one first."}

      Quota.check_board(board_id, :storage, size) != :ok ->
        {:error, "This board's storage is full, so that image can't be added."}

      true ->
        :ok
    end
  end

  defp held_bytes(user_id) do
    Repo.one(
      from(f in AutosaveFile,
        join: a in assoc(f, :autosave),
        where: a.user_id == ^user_id,
        select: coalesce(sum(f.size), 0)
      )
    )
    |> then(&if(is_struct(&1, Decimal), do: Decimal.to_integer(&1), else: &1))
  end

  defp ext(nil), do: ""

  defp ext(name) do
    case name |> Path.extname() |> String.downcase() do
      ext when ext in ~w(.png .jpg .jpeg .gif .webp) -> ext
      _ -> ""
    end
  end

  @doc "`user`'s held file, by id, or nil: nobody else's is ever served."
  def get_file(%User{id: user_id}, id) do
    Repo.one(
      from(f in AutosaveFile,
        join: a in assoc(f, :autosave),
        where: f.id == ^id and a.user_id == ^user_id
      )
    )
  end

  def file_url(%AutosaveFile{} = file),
    do: "/autosave-files/#{file.id}/#{URI.encode(file.filename)}"

  def file_path(%AutosaveFile{key: key}), do: Path.join(Boards.uploads_dir(), key)

  @doc """
  Turns the held images `body` still shows into attachments of `page`, and
  answers `{:ok, body}` with their links pointing at them, or `{:error,
  message}`. One taken out of the text again is left behind to be discarded.
  """
  def adopt(%Autosave{} = autosave, %Page{} = page, body) do
    autosave
    |> files()
    |> Enum.filter(&String.contains?(body, file_url(&1)))
    |> Enum.reduce_while({:ok, body}, fn file, {:ok, body} ->
      meta = %{filename: file.filename, content_type: file.content_type, size: file.size}

      case Wiki.add_attachment(page, meta, file_path(file)) do
        {:ok, %Attachment{} = attachment} ->
          {:cont, {:ok, String.replace(body, file_url(file), Boards.attachment_url(attachment))}}

        {:error, _} ->
          {:halt, {:error, "“#{file.filename}” couldn't be attached, so nothing was saved."}}
      end
    end)
  end

  defp files(%Autosave{id: id}),
    do: Repo.all(from(f in AutosaveFile, where: f.autosave_id == ^id, order_by: f.id))

  @doc "Throws it away, with anything it was holding."
  def discard(nil), do: :ok

  def discard(%Autosave{id: id} = autosave) do
    keys = Repo.all(from(f in AutosaveFile, where: f.autosave_id == ^id, select: f.key))
    Repo.delete(autosave, stale_error_field: :id)
    Boards.remove_files(keys)
    :ok
  end

  @doc "Lets go of what nobody has touched for `ttl_days/0`. Answers how many."
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@ttl_days, :day)
    stale = from(a in Autosave, where: a.updated_at < ^cutoff)
    keys = keys_of(stale)
    {count, _} = Repo.delete_all(stale)
    Boards.remove_files(keys)
    count
  end

  @doc "The held files on these boards, for whoever deletes the boards."
  def board_keys(board_ids_query),
    do: keys_of(from(a in Autosave, where: a.board_id in subquery(board_ids_query)))

  @doc "The files `user` holds, for deleting the account: their rows go with it."
  def user_keys(%User{id: id}), do: keys_of(from(a in Autosave, where: a.user_id == ^id))

  defp keys_of(autosaves) do
    Repo.all(
      from(f in AutosaveFile,
        where: f.autosave_id in subquery(from(a in autosaves, select: a.id)),
        select: f.key
      )
    )
  end
end
