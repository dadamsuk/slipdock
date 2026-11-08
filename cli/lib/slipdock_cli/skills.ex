defmodule SlipdockCLI.Skills do
  @moduledoc false

  # The agent skills the server ships, fetched and written to disk; and
  # `skills board <board> [name]` (#2063), the skills enabled on a board from
  # the registry with their pinned text, which the plan skill uses for a
  # Playbook stage that names one.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(skills)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  ## Skills ------------------------------------------------------------------
  #
  # The server ships the instructions for using it, versioned with the code
  # they describe. A skill file that hardcodes board names rots; one that is
  # fetched from the server that answers the calls does not.

  def run("skills", [], o), do: HTTP.get("/skills") |> out(o, &Render.skills(&1["skills"]))

  def run("skills", ["install"], o) do
    dir = skills_dir(o)

    {:ok, %{"skills" => skills}} = HTTP.get("/skills")

    written =
      Enum.flat_map(skills, fn skill ->
        Enum.map(skill["files"], fn file ->
          {:ok, %{"content" => content}} =
            HTTP.get("/skills/#{enc(skill["name"])}/#{file}")

          path = contained!(dir, Path.join(skill["name"], file))
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
          path
        end)
      end)

    if o[:json] do
      Render.json(%{"installed" => written, "dir" => dir})
    else
      IO.puts("installed #{length(skills)} skill(s), #{length(written)} file(s), into #{dir}")

      Enum.each(Render.scrub(skills), fn s ->
        IO.puts("  " <> s["name"] <> "  " <> Render.dim(s["sha"]))
      end)
    end
  end

  def run("skills", ["check"], o) do
    dir = skills_dir(o)
    {:ok, %{"skills" => skills}} = HTTP.get("/skills")

    rows =
      Enum.map(skills, fn skill ->
        local = Path.join([dir, skill["name"], "SKILL.md"])

        state =
          cond do
            not File.exists?(local) -> "not installed"
            skill_current?(dir, skill) -> "current"
            true -> "behind — run `slipdock skills install`"
          end

        [skill["name"], skill["sha"], state]
      end)

    if o[:json],
      do: Render.json(%{"skills" => skills, "dir" => dir}),
      else: Render.table(["SKILL", "SERVER", "LOCAL COPY"], Render.scrub(rows))
  end

  # ChatGPT can't run this CLI, so its versions of the skills are zips to
  # upload by hand: saved here, into the current directory unless told
  # otherwise. Which skills have one is the server's to say.
  def run("skills", ["chatgpt"], o) do
    dir = o[:dir] || "."
    {:ok, %{"skills" => skills}} = HTTP.get("/skills")

    written =
      for %{"name" => name, "chatgpt_zip" => "/api" <> zip} <- skills do
        case HTTP.get(zip) do
          {:ok, %{"raw" => bytes}} ->
            path = contained!(dir, name <> ".zip")
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, bytes)
            path

          _ ->
            fail("could not download the ChatGPT version of #{name}")
        end
      end

    if o[:json] do
      Render.json(%{"saved" => written, "dir" => dir})
    else
      IO.puts("saved #{length(written)} ChatGPT skill(s) into #{dir}:")
      Enum.each(written, &IO.puts("  " <> Render.scrub(&1)))
      IO.puts("Upload each in ChatGPT, and connect it to #{HTTP.base_url()}/mcp first.")
    end
  end

  def run("skills", ["board", board | name], o) when length(name) <= 1 do
    "/boards/#{enc(board)}/skills"
    |> HTTP.get()
    |> board_skills(List.first(name))
    |> out(o, &render_board(&1, board))
  end

  def run("skills", _args, _o),
    do:
      fail(
        "usage: slipdock skills | skills install [--dir D] | skills check | " <>
          "skills chatgpt [--dir D] | skills board <board> [<name>]"
      )

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## A board's skills (#2063) ---------------------------------------------------

  @doc """
  The answer to `skills board`, narrowed to the one skill named, if any. A
  name not enabled there is a 404 with a sentence saying so, as the server
  would give it.
  """
  def board_skills({:ok, data}, nil), do: {:ok, data}

  def board_skills({:ok, %{"skills" => skills} = data}, name) do
    case Enum.find(skills, &(&1["name"] == name)) do
      nil ->
        {:error, 404,
         %{"error" => "no skill named #{name} is enabled on #{board_label(data["board"])}"}}

      skill ->
        {:ok, %{"board" => data["board"], "skill" => skill}}
    end
  end

  def board_skills(other, _name), do: other

  @doc false
  def render_board(%{"skill" => s}, _ref) do
    IO.puts(:stderr, Render.dim(provenance(s)))
    IO.puts(s["text"])
  end

  def render_board(%{"skills" => [], "board" => b}, _ref),
    do:
      IO.puts(
        Render.dim("no skills are enabled on #{board_label(b)} — see slipdock registry enable")
      )

  def render_board(%{"skills" => skills}, _ref) do
    Render.table(
      ["NAME", "FROM", "LICENCE", "PINNED", "STATUS"],
      Enum.map(skills, fn s ->
        [
          s["name"],
          s["source_name"] || "-",
          s["licence"] || "-",
          String.slice(s["pinned_hash"] || "", 0, 12),
          status(s["status"])
        ]
      end)
    )
  end

  defp provenance(s),
    do:
      "#{s["name"]} from #{s["source_name"]} · licence #{s["licence"] || "none given"} · " <>
        "pinned #{String.slice(s["pinned_hash"] || "", 0, 12)} · #{status(s["status"])}"

  defp status("current"), do: "current"
  defp status("changed"), do: "changed upstream: the pinned text is served until re-pinned"
  defp status("removed"), do: "gone from its source: the pinned text is served"
  defp status(other), do: to_string(other)

  defp board_label(%{"name" => name, "code" => code}) when is_binary(code),
    do: "#{name} (#{code})"

  defp board_label(%{"name" => name}), do: name
  defp board_label(_), do: "that board"

  ## Helpers ------------------------------------------------------------------

  defp skills_dir(o) do
    o[:dir] || Path.join([HTTP.home(), ".claude", "skills"])
  end

  # The server's sha is over every file of the skill; recomputing it locally is
  # how `check` answers without diffing four files.
  defp skill_current?(dir, skill) do
    digest =
      Enum.reduce(skill["files"], :crypto.hash_init(:sha256), fn file, acc ->
        case File.read(Path.join([dir, skill["name"], file])) do
          {:ok, text} -> :crypto.hash_update(acc, file <> "\0" <> text)
          _ -> acc
        end
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    digest == skill["sha"]
  end
end
