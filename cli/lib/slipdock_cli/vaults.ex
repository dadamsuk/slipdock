defmodule SlipdockCLI.Vaults do
  @moduledoc false

  # Vaults: board wikis laid out as one Obsidian-style vault (W-103). A vault
  # is named by its id or its name; a path is vault-relative, "/" the root.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(vault)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("vault", ["ls"], o), do: HTTP.get("/vaults") |> out(o, &vaults(&1["vaults"]))
  def run("vault", [], o), do: run("vault", ["ls"], o)

  def run("vault", ["show", ref], o),
    do: HTTP.get("/vaults/#{enc(ref)}") |> out(o, &vault(&1["vault"]))

  def run("vault", ["new" | words], o) when words != [] do
    HTTP.post("/vaults", %{"name" => Enum.join(words, " ")})
    |> out(o, &vault(&1["vault"], "made"))
  end

  def run("vault", ["rename", ref | words], o) when words != [] do
    HTTP.patch("/vaults/#{enc(ref)}", %{"name" => Enum.join(words, " ")})
    |> out(o, &vault(&1["vault"], "renamed"))
  end

  def run("vault", ["rm", ref], o) do
    HTTP.delete("/vaults/#{enc(ref)}")
    |> out(o, fn r ->
      IO.puts("deleted the vault #{r["deleted"]["name"]} — every page stays on its board")
    end)
  end

  def run("vault", ["map", ref, path], o) do
    if is_nil(o[:board]), do: fail("say which board: --board B (and --folder F for one folder)")

    body = compact(%{"path" => path, "board" => o[:board], "folder" => o[:folder]})

    HTTP.post("/vaults/#{enc(ref)}/mappings", body) |> out(o, &vault(&1["vault"], "mapped"))
  end

  def run("vault", ["unmap", ref, path], o) do
    HTTP.delete("/vaults/#{enc(ref)}/mappings", path: path)
    |> out(o, &vault(&1["vault"], "unmapped"))
  end

  def run("vault", ["locate", ref, path], o) do
    HTTP.get("/vaults/#{enc(ref)}/locate", path: path)
    |> out(o, fn r ->
      IO.puts(mapping_line(r["mapping"]))
      if r["rest"] != "", do: IO.puts("  then " <> r["rest"])
    end)
  end

  def run("vault", ["resolve", ref | words], o) when words != [] do
    HTTP.get("/vaults/#{enc(ref)}/resolve", link: Enum.join(words, " "))
    |> out(o, fn r ->
      IO.puts("#{r["page"]["code"]} #{r["page"]["title"]}  " <> Render.dim(r["path"]))
    end)
  end

  def run("vault", ["wanted", ref], o) do
    HTTP.get("/vaults/#{enc(ref)}/wanted")
    |> out(o, fn
      %{"wanted" => []} ->
        IO.puts(Render.dim("nothing wanted: every link in the vault finds a page"))

      %{"wanted" => wanted} ->
        Enum.each(wanted, fn w ->
          from = Enum.map_join(w["from"], ", ", & &1["code"])
          IO.puts("[[#{w["title"]}]]  ×#{w["count"]}  " <> Render.dim("from " <> from))
        end)
    end)
  end

  # What changed since a cursor: what a sync polls. Without --since, the
  # cursor to start from.
  def run("vault", ["changes", ref], o) do
    HTTP.get("/vaults/#{enc(ref)}/changes", since: o[:since], limit: o[:limit])
    |> out(o, fn r ->
      Enum.each(r["changes"], fn c ->
        what = c["path"] || c["code"] || c["filename"] || c["name"] || "##{c["id"]}"

        IO.puts(
          String.pad_trailing("#{c["cursor"]}", 8) <> "#{c["subject"]} #{c["action"]}  #{what}"
        )
      end)

      IO.puts(
        Render.dim("cursor #{r["cursor"]}" <> if(r["more"], do: " — more to come", else: ""))
      )
    end)
  end

  def run("vault", _args, _o),
    do:
      fail(
        "usage: slipdock vault ls | show V | new NAME | rename V NAME | rm V | " <>
          "map V PATH --board B [--folder F] | unmap V PATH | locate V PATH | resolve V LINK | wanted V | changes V [--since N]"
      )

  defp vaults([]), do: IO.puts(Render.dim("no vaults — `slipdock vault new NAME` makes one"))
  defp vaults(list), do: Enum.each(list, &vault/1)

  defp vault(v, verb \\ nil) do
    head = Render.bold(v["name"]) <> "  " <> Render.dim("id #{v["id"]}")
    IO.puts(if verb, do: "#{verb} " <> head, else: head)

    case v["mappings"] do
      [] -> IO.puts("  " <> Render.dim("nothing mapped yet"))
      mappings -> Enum.each(mappings, &IO.puts("  " <> mapping_line(&1)))
    end
  end

  @doc false
  def mapping_line(m) do
    target =
      case m["folder"] do
        nil -> "#{m["board"]["name"]} wiki"
        folder -> "#{m["board"]["name"]} wiki, folder #{folder["path"]}"
      end

    String.pad_trailing(m["path"], 16) <>
      " → " <> target <> "  " <> Render.dim(m["board"]["code"] || "")
  end
end
