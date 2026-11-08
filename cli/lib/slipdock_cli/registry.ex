defmodule SlipdockCLI.Registry do
  @moduledoc false

  # The skills registry (#2072): skills fetched from outside Slipdock.
  #
  # `registry` lists your sources and the seeds; `registry add <url>`
  # (`--seed`: for everyone, admins only, #2075),
  # `registry source|refresh|rm <id>` handle one; `registry entry <id>`
  # prints one skill in full with the hash a pin is made against;
  # `registry enable <entry> --board B --hash H`, `registry repin <name>
  # --board B --hash H` and `registry disable <name> --board B` change a
  # board's skills (a writer only); `registry stages` lists the Playbook
  # stages naming a skill.
  #
  # Each command is planned first (`plan/3`: the request, or a usage error),
  # so what is sent and what is refused can be checked without the halt a
  # refusal ends in.

  import SlipdockCLI.Util

  alias SlipdockCLI.{HTTP, Render}

  @commands ~w(registry)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  @usage "usage: slipdock registry [add|source|refresh|rm|entry|enable|repin|disable|stages] … (see slipdock help)"

  def run(cmd, args, o) do
    case plan(cmd, args, o) do
      {:ok, {what, request}} -> request |> send_request() |> out(o, &render(what, &1, o))
      {:error, message} -> fail(message)
    end
  end

  @doc """
  What a command sends: `{:ok, {what, {method, path, body_or_query}}}`, or
  `{:error, message}` for a usage it can't make a request of.
  """
  def plan("registry", [], _o), do: {:ok, {:sources, {:get, "/skill-sources", []}}}
  def plan("registry", ["sources"], _o), do: {:ok, {:sources, {:get, "/skill-sources", []}}}

  def plan("registry", ["add", url], o) do
    body = if o[:seed], do: %{"url" => url, "seed" => true}, else: %{"url" => url}
    {:ok, {:added, {:post, "/skill-sources", body}}}
  end

  def plan("registry", ["source", id], _o),
    do: {:ok, {:source, {:get, "/skill-sources/#{enc(id)}", []}}}

  def plan("registry", ["refresh", id], _o),
    do: {:ok, {:refreshed, {:post, "/skill-sources/#{enc(id)}/refresh", %{}}}}

  def plan("registry", ["rm", id], _o),
    do: {:ok, {:removed, {:delete, "/skill-sources/#{enc(id)}", []}}}

  def plan("registry", ["entry", id], _o),
    do: {:ok, {:entry, {:get, "/skill-entries/#{enc(id)}", []}}}

  def plan("registry", ["stages"], _o), do: {:ok, {:stages, {:get, "/skill-stages", []}}}

  def plan("registry", ["enable", entry], o) do
    with {:ok, board} <- board(o),
         {:ok, hash} <- hash(o, entry) do
      {:ok,
       {:pinned, {:post, "/boards/#{enc(board)}/skills", %{"entry" => entry, "hash" => hash}}}}
    end
  end

  def plan("registry", ["repin", name], o) do
    with {:ok, board} <- board(o),
         {:ok, hash} <- hash(o, nil) do
      {:ok, {:pinned, {:patch, "/boards/#{enc(board)}/skills/#{enc(name)}", %{"hash" => hash}}}}
    end
  end

  def plan("registry", ["disable", name], o) do
    with {:ok, board} <- board(o),
         do: {:ok, {:disabled, {:delete, "/boards/#{enc(board)}/skills/#{enc(name)}", []}}}
  end

  def plan("registry", [sub], _o) when sub in ~w(add source refresh rm entry),
    do: {:error, "usage: slipdock registry #{sub} <#{if sub == "add", do: "url", else: "id"}>"}

  def plan("registry", [sub], _o) when sub in ~w(enable repin disable),
    do:
      {:error,
       "usage: slipdock registry #{sub} <#{if sub == "enable", do: "entry", else: "name"}> --board B" <>
         if(sub == "disable", do: "", else: " --hash H")}

  def plan("registry", _args, _o), do: {:error, @usage}

  @doc "Sends a planned request: the API's answer, as `SlipdockCLI.HTTP` gives it."
  def send_request({:get, path, query}), do: HTTP.get(path, query)
  def send_request({:delete, path, query}), do: HTTP.delete(path, query)
  def send_request({:post, path, body}), do: HTTP.post(path, body)
  def send_request({:patch, path, body}), do: HTTP.patch(path, body)

  defp board(o) do
    case nonblank(o[:board]) do
      nil -> {:error, "--board is required: the board whose skills change"}
      board -> {:ok, board}
    end
  end

  # A pin is made against the text read, so the hash is never guessed here.
  defp hash(o, entry) do
    case nonblank(o[:hash]) do
      nil ->
        read =
          if entry, do: "slipdock registry entry #{entry}", else: "slipdock registry entry <id>"

        {:error, "--hash is required: read the skill first (#{read}) and give its content_hash"}

      hash ->
        {:ok, hash}
    end
  end

  ## Rendering

  @doc false
  def render(:sources, %{"sources" => []}, _o),
    do: IO.puts(Render.dim("no skill sources yet — try: slipdock registry add <github url>"))

  def render(:sources, %{"sources" => sources}, _o) do
    Render.table(
      ["ID", "SOURCE", "SKILLS", "LICENCE", "FETCHED", ""],
      Enum.map(sources, fn s ->
        [
          to_string(s["id"]),
          s["name"],
          to_string(length(s["entries"] || [])),
          s["licence"] || "-",
          s["fetched_at"] || "-",
          if(s["seed"], do: "seed", else: "")
        ]
      end)
    )
  end

  def render(:added, %{"source" => s}, o) do
    IO.puts("added #{s["name"]} (#{s["id"]}): #{count(s["entries"])}")
    render(:source, %{"source" => s}, o)
  end

  def render(:source, %{"source" => s}, _o) do
    IO.puts("#{s["name"]}  " <> Render.dim("id #{s["id"]} · #{s["url"]}"))

    IO.puts(
      "  licence #{s["licence"] || "none given"} · version #{s["version"] || "-"} · fetched #{s["fetched_at"]}"
    )

    Enum.each(s["report"] || [], &IO.puts("  left out: " <> &1))

    Render.table(
      ["ENTRY", "NAME", "PATH", "DESCRIPTION"],
      Enum.map(s["entries"] || [], fn e ->
        [to_string(e["id"]), e["name"], e["path"], e["description"] || ""]
      end)
    )
  end

  def render(:refreshed, %{"source" => s, "changes" => changes}, _o) do
    parts =
      for group <- ~w(added changed removed),
          names = changes[group] || [],
          names != [],
          do: "#{group} #{Enum.join(names, ", ")}"

    IO.puts(
      "refreshed #{s["name"]}: " <>
        if(parts == [], do: "nothing changed", else: Enum.join(parts, "; "))
    )
  end

  def render(:removed, %{"deleted" => s}, _o), do: IO.puts("removed #{s["name"]} and its skills")

  def render(:entry, %{"entry" => e}, _o) do
    IO.puts("#{e["name"]}  " <> Render.dim("id #{e["id"]} · from #{e["source"]["name"]}"))

    IO.puts(
      "  #{e["path"]} · version #{e["version"] || "-"} · licence #{e["licence"] || "none given"}"
    )

    IO.puts("  content_hash #{e["content_hash"]}")

    Enum.each(e["enabled_on"] || [], fn p ->
      IO.puts("  enabled on #{board_name(p["board"])}: #{p["status"]}")
    end)

    Enum.each(e["stages"] || [], fn s ->
      IO.puts("  named by #{board_name(s["board"])} · #{s["stage"]}")
    end)

    IO.puts("")
    IO.puts(e["body"])
  end

  def render(:pinned, %{"skill" => s}, _o),
    do:
      IO.puts(
        "pinned #{s["name"]} from #{s["source_name"]} to #{String.slice(s["pinned_hash"], 0, 12)}"
      )

  def render(:disabled, %{"disabled" => d}, _o),
    do: IO.puts("disabled #{d["name"]} on #{d["board"]}")

  def render(:stages, %{"boards" => []}, _o),
    do: IO.puts(Render.dim("no Playbook on a board you can read names a skill"))

  def render(:stages, %{"boards" => boards}, _o) do
    rows =
      for b <- boards, s <- b["stages"] do
        [board_name(b["board"]), s["stage"], s["skill"], gets(s)]
      end

    Render.table(["BOARD", "STAGE", "SKILL", "GETS"], rows)
  end

  defp gets(%{"enabled" => %{"source_name" => from, "status" => status}}),
    do: "enabled, from #{from}" <> if(status == "current", do: "", else: " (#{status} upstream)")

  defp gets(%{"shipped" => true}), do: "a skill Slipdock ships"
  defp gets(_), do: "nothing: not enabled here, not shipped"

  defp board_name(b), do: "#{b["name"]} (#{b["code"] || b["id"]})"

  defp count([_]), do: "1 skill"
  defp count(list), do: "#{length(list || [])} skills"
end
