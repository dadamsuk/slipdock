defmodule Slipdock.Wiki.AutoOrganise do
  @moduledoc """
  A folder's "Organise…" (#791): works out where each page and file filed in
  a folder ought to go, shows that as a plan, and then files what the reader
  kept of it.

  Planning and doing are separate on purpose. `plan/3` changes nothing and
  returns one entry per item that would move; `apply_plan/2` takes the
  entries (all of them, or the ones somebody left ticked) and files them,
  making any folder along the way that is not there yet.

  The ways to organise (`modes/0`):

    * `"date"` — into a dated subfolder of a chosen parent: `Meetings/2026-10`
      for a note written on 12 October 2026. By month, year, year then month,
      or day. The date is the note's own `created:` or `date:` front matter
      when it has one (a note brought in from a vault was "added" the day it
      was imported), otherwise when it was added here.
    * `"ai"` — a cheap model reads the board's folders and the items' titles
      and suggests a home for each. It may make folders beneath an existing
      top-level folder, never a new top-level one; anything else it says is
      dropped.
    * `"tag"` — into a subfolder named after the note's first tag
      (`project/acme` nests as two folders).
    * `"flatten"` — everything filed in the folder's subfolders, however deep,
      back up into the folder itself. The emptied subfolders stay.

  Only the folder's own board is organised: a move to another board of a
  vault is the Move dialog's, which asks first about what goes with it.

  A page that sits under another page in the same folder goes where its
  parent goes, so a page and the pages under it are never split up.
  """

  import Ecto.Query, warn: false

  alias Slipdock.{AI, Repo, Wiki}
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Files, Folder, Folders, FrontMatter, Page, WikiFile}

  @modes ~w(date ai tag flatten)
  @granularities ~w(month year year_month day)
  @date_keys ~w(created date created_at)

  # How much one AI call is shown: the items it is asked about, the folders
  # it may choose between, and the titles given as examples of each.
  @ai_items 150
  @ai_folders 400
  @ai_examples 4

  @type entry :: %{
          key: String.t(),
          kind: :page | :file,
          id: integer(),
          title: String.t(),
          from: String.t(),
          to: String.t()
        }

  def modes, do: @modes
  def granularities, do: @granularities
  def ai_limit, do: @ai_items

  ## Planning -----------------------------------------------------------------

  @doc """
  Where the items in `folder` would go, by `mode`. Changes nothing.

  Options:

    * `"date"`: `:parent` (a folder path from the top of the wiki, `""` for
      the top; the folder itself when absent), `:granularity` (one of
      `granularities/0`, `"month"` by default) and `:source` (`"auto"`, the
      default, reads the front matter first; `"added"` only when it was added).
    * `"ai"`: `:user`, whose model is asked; also passed on to `Slipdock.AI`.

  Returns `{:ok, entries}` — only the items that would move, each with the
  path it is `from` and the path it goes `to` (`""` is the top) — or
  `{:error, message}`.
  """
  @spec plan(Folder.t(), String.t(), keyword()) :: {:ok, [entry()]} | {:error, String.t()}
  def plan(folder, mode, opts \\ [])

  def plan(%Folder{} = folder, "date", opts) do
    here = Folders.path(folder)
    granularity = opts[:granularity] || "month"

    with {:ok, parent} <- clean_path(Keyword.get(opts, :parent, here) || ""),
         true <- granularity in @granularities || {:error, "That isn't a way to group dates."} do
      source = opts[:source] || "auto"

      {:ok,
       folder
       |> items()
       |> Enum.map(fn item ->
         entry(item, here, join(parent, dated(date_of(item, source), granularity)))
       end)
       |> moving()}
    end
  end

  def plan(%Folder{} = folder, "tag", _opts) do
    here = Folders.path(folder)

    {:ok,
     folder
     |> items()
     |> Enum.flat_map(fn
       %Page{note_tags: [tag | _]} = page ->
         case clean_path(tag) do
           {:ok, path} when path != "" -> [entry(page, here, join(here, path))]
           _ -> []
         end

       _ ->
         []
     end)
     |> moving()}
  end

  def plan(%Folder{} = folder, "flatten", _opts) do
    here = Folders.path(folder)

    {:ok,
     folder
     |> Folders.descendants()
     |> Enum.flat_map(fn sub ->
       from = Folders.path(sub)
       Enum.map(items(sub), &entry(&1, from, here))
     end)
     |> moving()}
  end

  def plan(%Folder{} = folder, "ai", opts) do
    here = Folders.path(folder)
    board = Repo.get!(Board, folder.board_id)
    folders = Folders.list(board)
    paths = paths(folders)
    tops = for f <- folders, is_nil(f.parent_id), do: String.downcase(f.name)
    items = folder |> items() |> Enum.take(@ai_items)

    cond do
      items == [] ->
        {:ok, []}

      tops == [] ->
        {:error, "This board has no folders yet for the model to choose between."}

      true ->
        by_ref = Map.new(items, &{ref(&1), &1})

        with {:ok, answer} <-
               AI.complete_json(ai_messages(board, folders, paths, here, items),
                 user: opts[:user],
                 organise: true,
                 max_tokens: 4000,
                 temperature: 0.1
               ) do
          {:ok,
           answer
           |> Map.get("moves", [])
           |> List.wrap()
           |> Enum.flat_map(fn
             %{"id" => id, "folder" => to} when is_binary(id) and is_binary(to) ->
               with %{} = item <- by_ref[id],
                    {:ok, path} when path != "" <- clean_path(to),
                    true <- under_existing_top?(path, tops) do
                 [entry(item, here, canonical(path, paths))]
               else
                 _ -> []
               end

             _ ->
               []
           end)
           |> Enum.uniq_by(& &1.key)
           |> moving()}
        end
    end
  end

  def plan(%Folder{}, _mode, _opts), do: {:error, "That isn't a way to organise a folder."}

  # What is filed in a folder and can be moved: its live pages that are not
  # under another of its pages, and its live files.
  defp items(%Folder{id: id}) do
    pages =
      Repo.all(
        from(p in Page,
          where: p.folder_id == ^id and is_nil(p.archived_at),
          order_by: [asc: fragment("lower(?)", p.title)]
        )
      )

    here = MapSet.new(pages, & &1.id)
    tops = Enum.reject(pages, &(&1.parent_id && MapSet.member?(here, &1.parent_id)))

    files =
      Repo.all(
        from(f in WikiFile,
          where: f.folder_id == ^id and is_nil(f.archived_at),
          order_by: [asc: fragment("lower(?)", f.name)]
        )
      )

    tops ++ files
  end

  defp entry(%Page{} = page, from, to),
    do: %{key: "page:#{page.id}", kind: :page, id: page.id, title: page.title, from: from, to: to}

  defp entry(%WikiFile{} = file, from, to),
    do: %{key: "file:#{file.id}", kind: :file, id: file.id, title: file.name, from: from, to: to}

  defp moving(entries),
    do: Enum.reject(entries, &(String.downcase(&1.from) == String.downcase(&1.to)))

  defp join("", path), do: path
  defp join(parent, ""), do: parent
  defp join(parent, path), do: parent <> "/" <> path

  @doc """
  The date an item is filed by: a page's own `created:`, `date:` or
  `created_at:` front matter when `source` is `"auto"` and one of them holds
  a date, otherwise the day it was added.
  """
  def date_of(%Page{} = page, "auto") do
    yaml = FrontMatter.yaml(page.front_matter)

    Enum.find_value(@date_keys, fn key -> yaml && parse_date(FrontMatter.get(yaml, key)) end) ||
      DateTime.to_date(page.inserted_at)
  end

  def date_of(%{inserted_at: %DateTime{} = at}, _source), do: DateTime.to_date(at)
  def date_of(%{inserted_at: %NaiveDateTime{} = at}, _source), do: NaiveDateTime.to_date(at)

  defp parse_date(value) when is_binary(value) do
    with [ymd] <- Regex.run(~r/\d{4}-\d{2}-\d{2}/, value),
         {:ok, date} <- Date.from_iso8601(ymd),
         do: date,
         else: (_ -> nil)
  end

  defp parse_date(_), do: nil

  @doc ~S'The dated folder for `date`: "2026-10", "2026", "2026/10" or "2026-10-12".'
  def dated(%Date{} = date, "month"), do: Calendar.strftime(date, "%Y-%m")
  def dated(%Date{} = date, "year"), do: Calendar.strftime(date, "%Y")
  def dated(%Date{} = date, "year_month"), do: Calendar.strftime(date, "%Y/%m")
  def dated(%Date{} = date, "day"), do: Date.to_iso8601(date)

  @doc """
  A folder path as somebody typed it, tidied: segments trimmed, empty ones
  and leading or trailing slashes dropped. `{:error, message}` for a segment
  that is `.` or `..`, or longer than a folder's name may be.
  """
  def clean_path(path) when is_binary(path) do
    segments =
      path |> String.split(["/", "\\"]) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, "A folder can't be called “.” or “..”."}

      Enum.any?(segments, &(String.length(&1) > Folder.name_length())) ->
        {:error, "A folder's name can be #{Folder.name_length()} characters at most."}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  def clean_path(_), do: {:error, "That isn't a folder path."}

  @doc "Every folder on the board as its path, in tree order."
  def folder_paths(%Board{} = board),
    do: board |> Folders.list() |> paths() |> Map.values() |> Enum.sort_by(&String.downcase/1)

  # id => "A/B/C", from one read of the board's folders.
  defp paths(folders) do
    by_id = Map.new(folders, &{&1.id, &1})

    Map.new(folders, fn f -> {f.id, path_of(f, by_id)} end)
  end

  defp path_of(%Folder{parent_id: nil, name: name}, _by_id), do: name

  defp path_of(%Folder{parent_id: parent_id, name: name}, by_id) do
    case by_id[parent_id] do
      nil -> name
      parent -> path_of(parent, by_id) <> "/" <> name
    end
  end

  defp under_existing_top?(path, tops),
    do: String.downcase(hd(String.split(path, "/"))) in tops

  # The model's path written as the folders are, where they exist already,
  # so the plan reads "Projects/Acme" and not "projects/acme".
  defp canonical(path, paths) do
    known = Map.new(Map.values(paths), &{String.downcase(&1), &1})
    segments = String.split(path, "/")

    Enum.reduce(length(segments)..1//-1, nil, fn n, found ->
      found ||
        case known[String.downcase(Enum.join(Enum.take(segments, n), "/"))] do
          nil -> nil
          prefix -> Enum.join([prefix | Enum.drop(segments, n)], "/")
        end
    end) || path
  end

  defp ref(%Page{id: id}), do: "p#{id}"
  defp ref(%WikiFile{id: id}), do: "f#{id}"

  defp ai_messages(board, folders, paths, here, items) do
    titles =
      Repo.all(
        from(p in Page,
          where: p.board_id == ^board.id and is_nil(p.archived_at) and not is_nil(p.folder_id),
          order_by: [desc: p.updated_at],
          select: {p.folder_id, p.title}
        )
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    tree =
      folders
      |> Enum.map(&{paths[&1.id], Map.get(titles, &1.id, [])})
      |> Enum.sort_by(&String.downcase(elem(&1, 0)))
      |> Enum.take(@ai_folders)
      |> Enum.map_join("\n", fn {path, examples} ->
        case Enum.take(examples, @ai_examples) do
          [] -> "- #{path}"
          some -> "- #{path} (e.g. #{Enum.map_join(some, "; ", &inspect/1)})"
        end
      end)

    listing = Enum.map_join(items, "\n", &"- #{ref(&1)}: #{inspect(title(&1))}")

    [
      %{
        role: "system",
        content: """
        You file the notes and files of a wiki into its folders. You are given
        the wiki's folders, as paths from the top, with a few example titles
        of what is in each, and a list of items to file, each with an id and
        a title. Suggest the best folder for each item from its title.

        Rules:
        - Prefer an existing folder. You may suggest a new folder only
          beneath an existing folder (for example a new "Projects/Acme" when
          "Projects" exists). Never invent a new top-level folder.
        - Use "/" between folder names, with no leading or trailing slash.
        - Leave out any item whose best place is where it already is, or
          that you cannot place with confidence.

        Answer with one JSON object and nothing else:
        {"moves": [{"id": "<item id>", "folder": "<folder path>"}]}
        """
      },
      %{
        role: "user",
        content: """
        Folders on the wiki "#{board.name}":
        #{tree}

        The items are now in "#{here}":
        #{listing}
        """
      }
    ]
  end

  defp title(%Page{title: title}), do: title
  defp title(%WikiFile{name: name}), do: name

  ## Doing --------------------------------------------------------------------

  @doc """
  Files the planned `entries` on `board`, making every folder along each
  path that is missing. Each item is looked at again first: one archived,
  gone, moved to another board or filed elsewhere since the plan was made
  is left alone, and so is a file whose name is already taken where it
  would go.

  Returns `{:ok, %{moved: n, folders: n, skipped: [{title, reason}]}}`.
  """
  def apply_plan(%Board{} = board, entries) do
    result =
      entries
      |> Enum.group_by(& &1.to)
      |> Enum.reduce(%{moved: 0, folders: 0, skipped: []}, fn {to, group}, acc ->
        case ensure_path(board, to) do
          {:ok, folder, made} ->
            Enum.reduce(
              group,
              %{acc | folders: acc.folders + made},
              &apply_entry(board, &1, folder, &2)
            )

          {:error, message} ->
            %{acc | skipped: acc.skipped ++ Enum.map(group, &{&1.title, message})}
        end
      end)

    if result.moved > 0, do: Wiki.broadcast_board(board.id)
    {:ok, result}
  end

  defp apply_entry(board, %{kind: :page} = entry, folder, acc) do
    with %Page{archived_at: nil} = page <- Wiki.get_page(entry.id),
         true <- page.board_id == board.id,
         true <- folder_path(page.folder_id) == entry.from do
      old = page.folder_id

      case Wiki.file_page(page, folder) do
        {:ok, page} ->
          # The pages under it that were filed with it go with it.
          for child <- Wiki.descendants(page),
              child.folder_id == old,
              do: Wiki.file_page(child, folder)

          %{acc | moved: acc.moved + 1}

        _ ->
          skip(acc, entry, "it couldn't be moved")
      end
    else
      _ -> skip(acc, entry, "it has changed since the plan was made")
    end
  end

  defp apply_entry(board, %{kind: :file} = entry, folder, acc) do
    with %WikiFile{archived_at: nil} = file <- Files.get(entry.id),
         true <- file.board_id == board.id,
         true <- folder_path(file.folder_id) == entry.from do
      if Files.taken?(board.id, folder_id(folder), file.name, file.id) do
        skip(acc, entry, "a file of that name is already in #{entry.to}")
      else
        case Files.move(file, %{folder_id: folder_id(folder)}) do
          {:ok, _} -> %{acc | moved: acc.moved + 1}
          _ -> skip(acc, entry, "it couldn't be moved")
        end
      end
    else
      _ -> skip(acc, entry, "it has changed since the plan was made")
    end
  end

  defp skip(acc, entry, reason), do: %{acc | skipped: acc.skipped ++ [{entry.title, reason}]}

  defp folder_id(nil), do: nil
  defp folder_id(%Folder{id: id}), do: id

  defp folder_path(nil), do: ""
  defp folder_path(id), do: id |> Folders.get() |> then(&if(&1, do: Folders.path(&1), else: ""))

  # The folder at `path` from the top of the board, made (with any folder
  # above it) when missing: {:ok, folder | nil, how many were made}.
  defp ensure_path(board, path) do
    case clean_path(path) do
      {:ok, ""} ->
        {:ok, nil, 0}

      {:ok, path} ->
        path
        |> String.split("/")
        |> Enum.reduce_while({:ok, nil, 0}, fn name, {:ok, parent, made} ->
          case child(board, parent, name) do
            %Folder{} = folder ->
              {:cont, {:ok, folder, made}}

            nil ->
              case Folders.create(board, %{"name" => name, "parent_id" => folder_id(parent)}) do
                {:ok, folder} -> {:cont, {:ok, folder, made + 1}}
                {:error, _} -> {:halt, {:error, "the folder “#{name}” couldn't be made"}}
              end
          end
        end)

      error ->
        error
    end
  end

  defp child(board, parent, name) do
    from(f in Folder,
      where: f.board_id == ^board.id and fragment("lower(?)", f.name) == ^String.downcase(name),
      limit: 1
    )
    |> where([f], ^parent_is(folder_id(parent)))
    |> Repo.one()
  end

  defp parent_is(nil), do: dynamic([f], is_nil(f.parent_id))
  defp parent_is(id), do: dynamic([f], f.parent_id == ^id)
end
