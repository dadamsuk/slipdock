defmodule SlipdockCLI.Tools do
  @moduledoc false

  # Tools (#958): packages of docs, files, a board blueprint and skills that
  # somebody publishes on the server and others install.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(tools)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  @usage "usage: slipdock tools | tools show <name> [--version V] | tools publish <dir> | " <>
           "tools install-board <name> [--version V] [--name N]"

  def run("tools", [], o) do
    HTTP.get("/tools")
    |> out(o, fn %{"tools" => tools} -> render_list(tools) end)
  end

  def run("tools", ["show", name], o) do
    HTTP.get("/tools/#{enc(name)}", version_query(o))
    |> out(o, fn %{"tool" => tool} -> render_tool(tool) end)
  end

  # The folder is packed here, as the server reads it: tool.json at the top,
  # dotfiles and .git left out.
  def run("tools", ["publish", dir], o) do
    unless File.exists?(Path.join(dir, "tool.json")),
      do: fail("#{dir} has no tool.json — point at the Tool's folder")

    bytes = pack(dir)

    HTTP.post_multipart("/tools", [], [
      {"package", Path.basename(Path.expand(dir)) <> ".tar.gz", "application/gzip", bytes}
    ])
    |> out(o, fn %{"tool" => tool} ->
      IO.puts("published #{tool["name"]} #{tool["version"]}  " <> Render.dim(tool["sha"]))
    end)
  end

  # The server builds the board; this only asks for it.
  def run("tools", ["install-board", name], o) do
    body = %{} |> put_opt("version", o[:version]) |> put_opt("name", o[:name])

    HTTP.post("/tools/#{enc(name)}/install", body)
    |> out(o, fn %{"install" => i} ->
      verb = if i["created"], do: "made", else: "already have"

      IO.puts(
        "#{verb} board #{i["board"]} (#{i["board_name"]}), #{name} #{i["installed_version"]}"
      )

      IO.puts("  " <> i["url"])

      for {part, names} <- i["added"] || %{}, names != [] do
        IO.puts("  added #{part}: " <> Enum.join(names, ", "))
      end
    end)
  end

  def run("tools", _args, _o), do: fail(@usage)

  def run(cmd, _args, _o), do: bad_usage(cmd)

  @doc false
  # Every regular file under `dir` as a gzipped tar, paths relative to it.
  def pack(dir) do
    root = Path.expand(dir)

    entries =
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()
      |> Enum.map(&{String.to_charlist(&1), File.read!(Path.join(root, &1))})

    path =
      Path.join(System.tmp_dir!(), "slipdock-tool-#{System.unique_integer([:positive])}.tar.gz")

    try do
      :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed, :write])
      File.read!(path)
    after
      File.rm(path)
    end
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp version_query(o), do: if(o[:version], do: [version: o[:version]], else: [])

  defp render_list([]), do: IO.puts(Render.dim("no Tools you can see on this server"))

  defp render_list(tools) do
    rows =
      Enum.map(tools, fn t ->
        [t["name"], t["version"] || "-", kind(t), t["summary"] || ""]
      end)

    Render.table(["TOOL", "VERSION", "", "SUMMARY"], rows)
  end

  defp kind(%{"mine" => true}), do: "mine"
  defp kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp kind(_), do: ""

  defp render_tool(t) do
    IO.puts("#{t["title"]} (#{t["name"]}) #{t["version"]}  " <> Render.dim(t["sha"] || ""))
    if t["summary"], do: IO.puts(t["summary"])
    if t["author"], do: IO.puts("by " <> t["author"])
    IO.puts("")

    if board = t["board"] do
      IO.puts("board: " <> Enum.map_join(board["lists"] || [], " → ", & &1["name"]))

      for {key, label} <- [{"folders", "folders"}, {"tags", "tags"}],
          items = board[key] || [],
          items != [] do
        IO.puts("  #{label}: " <> Enum.map_join(items, ", ", &item_name/1))
      end

      pages = board["pages"] || []
      if pages != [], do: IO.puts("  pages: " <> Enum.map_join(pages, ", ", & &1["title"]))

      rules = board["automations"] || []
      if rules != [], do: IO.puts("  automations: " <> Enum.map_join(rules, ", ", & &1["preset"]))
    end

    Enum.each(t["skills"] || [], fn s ->
      IO.puts(
        "skill: #{s["name"]}  " <> Render.dim(s["sha"]) <> "  #{length(s["files"])} file(s)"
      )
    end)

    Enum.each(t["files"] || [], fn f ->
      where = if f["install"] == "local", do: "beside #{f["skill"]}", else: "on the board"
      IO.puts("file: #{f["path"]} (#{where})")
    end)

    if versions = t["versions"],
      do: IO.puts(Render.dim("versions: " <> Enum.join(versions, ", ")))
  end

  defp item_name(name) when is_binary(name), do: name
  defp item_name(%{"name" => name}), do: name
end
