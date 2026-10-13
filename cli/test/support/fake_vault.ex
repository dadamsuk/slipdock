defmodule SlipdockCLI.FakeVault do
  @moduledoc """
  A vault held in memory, answering the sync engine the way the server's
  `/api/vaults/:id/sync` does: pages by id with a path and content, the
  hash of the content as the file's hash, writes refused as conflicts when
  their base is stale or their path is somebody else's, and archived pages
  gone from the listing. The test edits the "server" side directly with
  `put/3`, `move/3` and `archive/2`.

  `ctx` is the Agent. A `:normalise` function, when set, rewrites content
  on the way in, as the server patches a title key after a rename.

  Its folders are every directory a page or file sits in, and any made
  empty with `add_folder/2`; `folders: false` lists none at all, as a
  server from before folders were listed.
  """
  @behaviour SlipdockCLI.Sync.Remote

  def start(opts \\ []) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          pages: %{},
          files: %{},
          next: 1,
          cursor: 0,
          normalise: opts[:normalise],
          folders: if(opts[:folders] == false, do: false, else: MapSet.new()),
          fail: nil,
          calls: []
        }
      end)

    pid
  end

  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  ## The server side, as a test edits it ------------------------------------

  def put(vault, path, content) do
    Agent.get_and_update(vault, fn s ->
      case Enum.find(s.pages, fn {_id, p} -> p.path == path end) do
        {id, p} ->
          {id, bump(%{s | pages: Map.put(s.pages, id, %{p | content: content})})}

        nil ->
          {s.next,
           bump(%{
             s
             | pages: Map.put(s.pages, s.next, %{path: path, content: content}),
               next: s.next + 1
           })}
      end
    end)
  end

  def move(vault, id, path),
    do: Agent.update(vault, fn s -> bump(update_in(s.pages[id], &%{&1 | path: path})) end)

  def archive(vault, id),
    do: Agent.update(vault, fn s -> bump(%{s | pages: Map.delete(s.pages, id)}) end)

  def pages(vault), do: Agent.get(vault, fn s -> s.pages end)

  def add_folder(vault, path),
    do: Agent.update(vault, fn s -> bump(%{s | folders: MapSet.put(s.folders, path)}) end)

  @doc "Deletes a folder, its pages and files moved out to the root first."
  def delete_folder(vault, path) do
    Agent.update(vault, fn s ->
      out = fn p -> if String.starts_with?(p, path <> "/"), do: Path.basename(p), else: p end

      bump(%{
        s
        | folders:
            MapSet.reject(s.folders, &(&1 == path or String.starts_with?(&1, path <> "/"))),
          pages: Map.new(s.pages, fn {id, p} -> {id, %{p | path: out.(p.path)}} end),
          files: Map.new(s.files, fn {id, f} -> {id, %{f | path: out.(f.path)}} end)
      })
    end)
  end

  def by_path(vault, path) do
    vault
    |> pages()
    |> Enum.find_value(fn {id, p} -> if p.path == path, do: Map.put(p, :id, id) end)
  end

  def calls(vault), do: Agent.get(vault, fn s -> Enum.reverse(s.calls) end)

  @doc "Makes the next write answer with an error."
  def fail_next(vault, msg), do: Agent.update(vault, &%{&1 | fail: msg})

  defp bump(s), do: %{s | cursor: s.cursor + 1}

  @doc "A file that is not a note, put on the server side (ids shared with pages, as on the server they are not)."
  def put_file(vault, path, bytes) do
    Agent.get_and_update(vault, fn s ->
      case Enum.find(s.files, fn {_id, f} -> f.path == path end) do
        {id, f} ->
          {id, bump(%{s | files: Map.put(s.files, id, %{f | bytes: bytes})})}

        nil ->
          {s.next,
           bump(%{
             s
             | files: Map.put(s.files, s.next, %{path: path, bytes: bytes}),
               next: s.next + 1
           })}
      end
    end)
  end

  def files(vault), do: Agent.get(vault, fn s -> s.files end)

  def file_by_path(vault, path) do
    vault
    |> files()
    |> Enum.find_value(fn {id, f} -> if f.path == path, do: Map.put(f, :id, id) end)
  end

  def archive_file_server(vault, id),
    do: Agent.update(vault, fn s -> bump(%{s | files: Map.delete(s.files, id)}) end)

  ## The remote, as the engine calls it -------------------------------------

  @impl true
  def read_file(vault, id, dest) do
    case Agent.get(vault, fn s -> s.files[id] end) do
      nil ->
        {:error, "file #{id} not found (HTTP 404)"}

      f ->
        File.write!(dest, f.bytes)
        {:ok, hash(f.bytes)}
    end
  end

  @impl true
  def write_file(vault, id, params, source) do
    bytes = File.read!(source)

    Agent.get_and_update(vault, fn s ->
      s = %{s | calls: [{:write_file, id, params["path"]} | s.calls]}
      path = params["path"]

      taken =
        Enum.find(s.files, fn {other, f} ->
          other != id and String.downcase(f.path) == String.downcase(path)
        end)

      cond do
        s.fail ->
          {{:error, s.fail}, %{s | fail: nil}}

        taken ->
          {other, f} = taken
          {{:conflict, file_entry(other, f)}, s}

        is_nil(id) ->
          f = %{path: path, bytes: bytes}

          {{:ok, file_entry(s.next, f)},
           bump(%{s | files: Map.put(s.files, s.next, f), next: s.next + 1})}

        params["base"] && params["base"] != hash(s.files[id].bytes) ->
          {{:conflict, file_entry(id, s.files[id])}, s}

        true ->
          f = %{path: path, bytes: bytes}
          {{:ok, file_entry(id, f)}, bump(%{s | files: Map.put(s.files, id, f)})}
      end
    end)
  end

  @impl true
  def move_file(vault, id, params) do
    Agent.get_and_update(vault, fn s ->
      s = %{s | calls: [{:move_file, id, params["path"]} | s.calls]}

      case s.files[id] do
        nil ->
          {{:error, "not found"}, s}

        f ->
          if params["base"] && params["base"] != hash(f.bytes) do
            {{:conflict, file_entry(id, f)}, s}
          else
            f = %{f | path: params["path"]}
            {{:ok, file_entry(id, f)}, bump(%{s | files: Map.put(s.files, id, f)})}
          end
      end
    end)
  end

  @impl true
  def archive_file(vault, id, base) do
    Agent.get_and_update(vault, fn s ->
      s = %{s | calls: [{:archive_file, id} | s.calls]}

      case s.files[id] do
        nil ->
          {{:error, "not found"}, s}

        f ->
          if base && base != hash(f.bytes),
            do: {{:conflict, file_entry(id, f)}, s},
            else:
              {{:ok, %{"id" => id, "archived" => true}},
               bump(%{s | files: Map.delete(s.files, id)})}
      end
    end)
  end

  @impl true
  def list(vault) do
    Agent.get(vault, fn s ->
      entries =
        for {id, p} <- s.pages,
            do: %{"kind" => "page", "id" => id, "path" => p.path, "hash" => hash(p.content)}

      files = for {id, f} <- s.files, do: file_entry(id, f)
      listing = %{"cursor" => s.cursor, "entries" => entries ++ files}

      if s.folders,
        do: {:ok, Map.put(listing, "folders", folders(s, entries ++ files))},
        else: {:ok, listing}
    end)
  end

  defp folders(s, entries) do
    entries
    |> Enum.flat_map(fn e -> dirs(Path.dirname(e["path"])) end)
    |> Enum.concat(Enum.flat_map(s.folders, &dirs/1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dirs("."), do: []
  defp dirs(dir), do: [dir | dirs(Path.dirname(dir))]

  @impl true
  def read(vault, id) do
    Agent.get(vault, fn s ->
      case s.pages[id] do
        nil -> {:error, "page #{id} not found (HTTP 404)"}
        p -> {:ok, entry(id, p)}
      end
    end)
  end

  @impl true
  def write(vault, id, params) do
    Agent.get_and_update(vault, fn s ->
      s = %{s | calls: [{:write, id, params["path"]} | s.calls]}
      path = params["path"]

      taken =
        Enum.find(s.pages, fn {other, p} ->
          other != id and String.downcase(p.path) == String.downcase(path)
        end)

      content = if s.normalise, do: s.normalise.(path, params["content"]), else: params["content"]

      cond do
        s.fail ->
          {{:error, s.fail}, %{s | fail: nil}}

        taken ->
          {other, p} = taken
          {{:conflict, entry(other, p)}, s}

        is_nil(id) ->
          page = %{path: path, content: content}

          {{:ok, entry(s.next, page)},
           bump(%{s | pages: Map.put(s.pages, s.next, page), next: s.next + 1})}

        is_nil(s.pages[id]) ->
          {{:error, "page #{id} in this vault not found (HTTP 404)"}, s}

        params["base"] && params["base"] != hash(s.pages[id].content) ->
          {{:conflict, entry(id, s.pages[id])}, s}

        true ->
          page = %{path: path, content: content}
          {{:ok, entry(id, page)}, bump(%{s | pages: Map.put(s.pages, id, page)})}
      end
    end)
  end

  @impl true
  def archive(vault, id, base) do
    Agent.get_and_update(vault, fn s ->
      s = %{s | calls: [{:archive, id} | s.calls]}

      case s.pages[id] do
        nil ->
          {{:error, "not found"}, s}

        p when base != nil and base != "" ->
          if hash(p.content) == base,
            do:
              {{:ok, %{"id" => id, "archived" => true}},
               bump(%{s | pages: Map.delete(s.pages, id)})},
            else: {{:conflict, entry(id, p)}, s}

        _ ->
          {{:ok, %{"id" => id, "archived" => true}}, bump(%{s | pages: Map.delete(s.pages, id)})}
      end
    end)
  end

  @impl true
  def changes(vault, since) do
    Agent.get(vault, fn s ->
      changed = if since && since < s.cursor, do: [%{"cursor" => s.cursor}], else: []
      {:ok, %{"changes" => changed, "cursor" => s.cursor, "more" => false, "resync" => false}}
    end)
  end

  defp file_entry(id, f),
    do: %{
      "kind" => "file",
      "id" => id,
      "path" => f.path,
      "hash" => hash(f.bytes),
      "size" => byte_size(f.bytes)
    }

  defp entry(id, p),
    do: %{
      "kind" => "page",
      "id" => id,
      "path" => p.path,
      "hash" => hash(p.content),
      "content" => p.content
    }
end
