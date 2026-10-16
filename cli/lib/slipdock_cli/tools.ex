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
           "tools install <name> [--dir D] | tools check [<name>...] | " <>
           "tools request-listing <name> [--version V] | " <>
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

  # The skills and their local files, unpacked into ~/.claude/skills (or
  # --dir). Every path is checked to stay inside it before anything is
  # written: a package is somebody else's.
  def run("tools", ["install", name], o) do
    dir = skills_dir(o)
    {:ok, %{"tool" => tool}} = checked(HTTP.get("/tools/#{enc(name)}", version_query(o)))
    query = [version: tool["version"]]

    bytes =
      case HTTP.get("/tools/#{enc(name)}/skills.tar.gz", query) do
        {:ok, %{"raw" => bytes}} -> bytes
        other -> checked(other)
      end

    {:ok, entries} = :erl_tar.extract({:binary, bytes}, [:compressed, :memory])

    targets =
      Enum.map(entries, fn {path, content} -> {contained!(dir, to_string(path)), content} end)

    Enum.each(targets, fn {path, content} ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    if o[:json] do
      Render.json(%{"installed" => Enum.map(targets, &elem(&1, 0)), "dir" => dir, "tool" => tool})
    else
      IO.puts(
        "installed #{tool["name"]} #{tool["version"]}: #{length(tool["skills"])} skill(s), " <>
          "#{length(targets)} file(s), into #{dir}"
      )

      Enum.each(tool["skills"], fn s -> IO.puts("  #{s["name"]}  " <> Render.dim(s["sha"])) end)

      if tool["board"] && is_nil(tool["installed"]) do
        IO.puts(
          "It comes with a board: ask your agent to set up #{tool["title"]}, or run " <>
            "`slipdock tools install-board #{tool["name"]}`."
        )
      end
    end
  end

  def run("tools", ["check" | names], o) do
    dir = skills_dir(o)

    tools =
      case names do
        [] -> HTTP.get("/tools") |> checked() |> elem(1) |> Map.fetch!("tools")
        names -> Enum.map(names, &%{"name" => &1})
      end

    rows =
      for %{"name" => name} <- tools,
          {:ok, %{"tool" => tool}} = checked(HTTP.get("/tools/#{enc(name)}")),
          skill <- tool["skills"] || [],
          names != [] or File.exists?(Path.join([dir, skill["name"], "SKILL.md"])) do
        state =
          cond do
            not File.exists?(Path.join([dir, skill["name"], "SKILL.md"])) -> "not installed"
            skill_current?(dir, skill) -> "current"
            true -> "behind — run `slipdock tools install #{name}`"
          end

        [name, skill["name"], tool["version"], state]
      end

    if o[:json],
      do: Render.json(%{"skills" => rows, "dir" => dir}),
      else: Render.table(["TOOL", "SKILL", "SERVER", "LOCAL COPY"], Render.scrub(rows))
  end

  # Listed for everyone once an admin approves this version.
  def run("tools", ["request-listing", name], o) do
    HTTP.post("/tools/#{enc(name)}/listing", put_opt(%{}, "version", o[:version]))
    |> out(o, fn %{"tool" => t} ->
      IO.puts(
        "asked for #{t["name"]} #{t["version"]} to be listed for everyone; an admin approves it " <>
          "before it shows (#{t["listing"]["this_version"]})"
      )
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

  defp skills_dir(o), do: o[:dir] || Path.join([HTTP.home(), ".claude", "skills"])

  # A request's answer, or the CLI's usual error for it (which exits).
  defp checked({:ok, _} = ok), do: ok
  defp checked(error), do: out(error, [], fn _ -> :ok end)

  # The same sha the server computes (`Slipdock.Skills.digest/1`): over each
  # file of the skill, in the order the server lists them.
  defp skill_current?(dir, skill) do
    skill["files"]
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
      case File.read(Path.join([dir, skill["name"], file])) do
        {:ok, text} -> :crypto.hash_update(acc, file <> "\0" <> text)
        _ -> acc
      end
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
    |> Kernel.==(skill["sha"])
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp version_query(o), do: if(o[:version], do: [version: o[:version]], else: [])

  defp render_list([]), do: IO.puts(Render.dim("no Tools you can see on this server"))

  defp render_list(tools) do
    rows =
      Enum.map(tools, fn t ->
        board = (t["installed"] || %{})["board"] || "-"
        [t["name"], t["version"] || "-", kind(t), board, t["summary"] || ""]
      end)

    Render.table(["TOOL", "VERSION", "KIND", "BOARD", "SUMMARY"], rows)
  end

  defp kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp kind(%{"mine" => true}), do: "mine"
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
