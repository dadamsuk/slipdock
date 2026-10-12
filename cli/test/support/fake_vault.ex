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
  """
  @behaviour SlipdockCLI.Sync.Remote

  def start(opts \\ []) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{pages: %{}, next: 1, cursor: 0, normalise: opts[:normalise], fail: nil, calls: []}
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

  def by_path(vault, path) do
    vault
    |> pages()
    |> Enum.find_value(fn {id, p} -> if p.path == path, do: Map.put(p, :id, id) end)
  end

  def calls(vault), do: Agent.get(vault, fn s -> Enum.reverse(s.calls) end)

  @doc "Makes the next write answer with an error."
  def fail_next(vault, msg), do: Agent.update(vault, &%{&1 | fail: msg})

  defp bump(s), do: %{s | cursor: s.cursor + 1}

  ## The remote, as the engine calls it -------------------------------------

  @impl true
  def list(vault) do
    Agent.get(vault, fn s ->
      entries =
        for {id, p} <- s.pages,
            do: %{"kind" => "page", "id" => id, "path" => p.path, "hash" => hash(p.content)}

      {:ok, %{"cursor" => s.cursor, "entries" => entries}}
    end)
  end

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

  defp entry(id, p),
    do: %{
      "kind" => "page",
      "id" => id,
      "path" => p.path,
      "hash" => hash(p.content),
      "content" => p.content
    }
end
