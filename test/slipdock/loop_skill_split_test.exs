defmodule Slipdock.LoopSkillSplitTest do
  @moduledoc """
  The slipdock-loop skill is a short `SKILL.md` and a file per kind of pass
  under `references/` (#3004). A skill's `SKILL.md` is loaded into the
  context of every turn of the job that invoked it, so a single-card runner
  job was carrying how to choose a card, work an epic and verify one (77 KB,
  about 20K tokens a turn) to do none of them. This holds the split: the
  size `SKILL.md` may grow to, that it names every reference with the
  condition that loads it, and that the references ship with the skill.

  It reads `priv/skills/`, so it is on `test/repo_checks.txt`.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  alias Slipdock.Skills

  @dir Path.expand("../../priv/skills/slipdock-loop", __DIR__)

  # What every turn of a job pays for. Something only some passes need goes
  # in the reference for that pass, not here; raise this only for a rule
  # every pass needs.
  @ceiling 50_000

  defp skill, do: File.read!(Path.join(@dir, "SKILL.md"))
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp references,
    do: @dir |> Path.join("references/*.md") |> Path.wildcard() |> Enum.map(&Path.basename/1)

  # The table under "What else to read, and when": `{condition, file}` a row.
  defp rows do
    [_, section] = String.split(skill(), "\n## What else to read, and when\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    for line <- String.split(section, "\n"),
        [_, condition, file] <- [Regex.run(~r/^\| (.+?) \| `references\/([a-z-]+\.md)`/, line)],
        do: {condition, file}
  end

  test "SKILL.md stays under its ceiling" do
    size = byte_size(skill())

    assert size <= @ceiling,
           "priv/skills/slipdock-loop/SKILL.md is #{size} bytes, over its #{@ceiling}: " <>
             "every turn of every job reads it, so what only some passes need goes in references/"
  end

  test "the split took the parts out, and they have not come back" do
    text = skill()

    for {heading, file} <- [
          {"## Refusals that mean stop", "stops.md"},
          {"## When the token dies", "stops.md"},
          {"## 1. Which board", "picking.md"},
          {"## 2. Resume before you claim", "picking.md"},
          {"## 2a. Check CI before you pick", "picking.md"},
          {"## 2b. A job first", "picking.md"},
          {"## 3. Pick the top card", "picking.md"},
          {"A bug: reproduce", "bugs.md"},
          {"- **A verify job** (a job", "verifying.md"},
          {"- **An audit** (a verify job", "verifying.md"},
          {"- **The board has lanes on**", "lanes.md"},
          {"gh run watch <run-id>", "build.md"},
          {"Build the prototype on", "spikes.md"},
          {"the same pull request updates", "pull-requests.md"},
          {"**A card tagged `security`**", "pull-requests.md"}
        ] do
      refute text =~ heading, "SKILL.md has #{inspect(heading)} again: it lives in #{file}"

      assert File.read!(Path.join([@dir, "references", file])) =~ heading,
             "references/#{file} lost #{inspect(heading)}"
    end

    # Step 5 keeps its heading in both: a pointer here, the step there.
    assert text =~ "## 5. Subcards before the parent"
    assert File.read!(Path.join(@dir, "references/subcards.md")) =~ "**Wait for every"
    refute text =~ "**Wait for every"
  end

  test "SKILL.md names every reference, each with the condition that loads it" do
    rows = rows()
    named = Enum.map(rows, &elem(&1, 1))

    assert Enum.sort(named) == Enum.sort(references()),
           "the table and references/ differ: #{inspect(named -- references())} named but " <>
             "missing, #{inspect(references() -- named)} there but not named"

    assert named == Enum.uniq(named)
    for {condition, file} <- rows, do: assert(String.length(condition) > 15, file)

    conditions = Map.new(rows, fn {condition, file} -> {file, condition} end)
    assert conditions["picking.md"] =~ "not given its card"
    assert conditions["picking.md"] =~ "names a pool"
    assert conditions["subcards.md"] =~ "has subcards"
    assert conditions["bugs.md"] =~ "reports a bug"
    assert conditions["spikes.md"] =~ "is a spike"
    assert conditions["verifying.md"] =~ "kind `verify`"
    assert conditions["verifying.md"] =~ "verify or audit a card"
    assert conditions["lanes.md"] =~ "lanes on or advising"
    assert conditions["lanes.md"] =~ "paths yourself"
    assert conditions["lanes.md"] =~ "refused over an overlap"
    assert conditions["pull-requests.md"] =~ "prompt doesn't give"
    assert conditions["pull-requests.md"] =~ "tagged `security`"
    assert conditions["build.md"] =~ "not a pull request's"
    assert conditions["stops.md"] =~ "HTTP 402"
    assert conditions["stops.md"] =~ "`not signed in`, `401` or `invalid token`"
  end

  test "SKILL.md says where the files are and that the others stay unread" do
    text = flat(skill())
    assert text =~ "`references/`, in this skill's own directory"

    assert_states(
      text,
      ~s{read a file "when its condition holds" and "leave the others unread"}
    )
  end

  test "a pass given its card starts at step 3, without choosing one" do
    text = flat(skill())

    assert_states(
      text,
      ~s{a pass "given its card" (a runner's job sets `$SLIPDOCK_JOB_ID`) } <>
        ~s{"does not choose one": after the preflight "it starts at step 3"}
    )

    assert skill() =~ "\n## 3. Read the card\n"
  end

  test "no file of the skill points at a reference that is not there" do
    for file <- ["SKILL.md" | Enum.map(references(), &Path.join("references", &1))],
        text = File.read!(Path.join(@dir, file)),
        [_, name] <- Regex.scan(~r/`(?:references\/)?([a-z-]+\.md)`/, text),
        name != "SKILL.md" do
      assert name in references(), "#{file} names #{name}, which references/ doesn't have"
    end
  end

  test "each reference says whose it is and when it is read" do
    for file <- references() do
      text = File.read!(Path.join([@dir, "references", file]))
      assert text =~ ~r/\A# .+\n\nPart of the `slipdock-loop` skill: /, file

      assert flat(text) =~ ~r/Part of the `slipdock-loop` skill: .{0,40}\bread (when|after)\b/,
             file
    end
  end

  test "the skill ships every reference: its file list, each file, and the tarball" do
    skill = Skills.get("slipdock-loop")
    shipped = for "references/" <> name <- skill.files, do: name
    assert Enum.sort(shipped) == Enum.sort(references())
    assert references() != []

    {:ok, tarball} = Skills.tarball()
    {:ok, entries} = :erl_tar.extract({:binary, tarball}, [:memory, :compressed])
    entries = Map.new(entries, fn {name, body} -> {to_string(name), body} end)

    for name <- references() do
      on_disk = File.read!(Path.join([@dir, "references", name]))
      assert {:ok, ^on_disk} = Skills.read("slipdock-loop", "references/" <> name)
      assert entries["slipdock-loop/references/" <> name] == on_disk
    end
  end
end
