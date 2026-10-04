defmodule SlipdockCLI.Skills do
  @moduledoc false

  # The agent skills the server ships, fetched and written to disk.

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

  def run("skills", _args, _o),
    do: fail("usage: slipdock skills | skills install [--dir D] | skills check")

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Helpers ------------------------------------------------------------------

  defp skills_dir(o) do
    o[:dir] || Path.join([System.get_env("HOME") || ".", ".claude", "skills"])
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
