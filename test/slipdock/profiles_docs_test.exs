defmodule Slipdock.ProfilesDocsTest do
  @moduledoc """
  Profiles and the human tier (#1950) where a reader starts: the README's
  feature bullet links the manual's sections and names the switch, the tier
  setting and the six profiles; the in-app help names the chip, the select
  and the board settings.
  """
  use ExUnit.Case, async: true

  import Slipdock.DocsFacts, only: [assert_states: 3]

  alias Slipdock.Profiles

  @root Path.expand("../..", __DIR__)
  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the manual has the sections the README links" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^## Profiles$/m
    assert manual =~ ~r/^### The human tier$/m
  end

  test "README's bullet links them, with the switch, the tier setting and every profile" do
    readme = read("README.md")
    [_, bullet] = String.split(readme, "- **Profiles and the human tier**", parts: 2)
    [bullet | _] = String.split(bullet, "\n- **", parts: 2)

    for part <- [
          "docs/manual/profiles.md",
          "docs/manual/profiles.md#the-human-tier",
          "set-board --profiles on",
          "--profile-tier",
          "`spike` only by tag"
        ],
        do: assert(bullet =~ part, inspect(part))

    for name <- Profiles.names(), do: assert(bullet =~ "`#{name}`", name)
  end

  test "the in-app help names the chip, the select and both board settings" do
    help = read("lib/slipdock_web/live/help_live/guides.ex")
    assert help =~ "<strong>Profiles</strong>"

    for part <- [
          "<em>Profiles</em>",
          "<em>Profile</em>",
          "<em>Human tier, by profile</em>",
          "chip"
        ],
        do: assert(help =~ part, inspect(part))

    for name <- Profiles.names(), do: assert(help =~ name, name)
  end

  # #2017: both say the profile is checked again when an agent completes the
  # card, raised and never lowered, and that a fix a person set keeps its size.
  test "README and the in-app help say the profile is raised at completion" do
    readme = read("README.md")
    [_, bullet] = String.split(readme, "- **Profiles and the human tier**", parts: 2)
    [bullet | _] = String.split(bullet, "\n- **", parts: 2)
    bullet = String.replace(bullet, ~r/\s+/, " ")

    help =
      read("lib/slipdock_web/live/help_live/guides.ex") |> String.replace(~r/\s+/, " ")

    for text <- [bullet, help],
        part <- [
          "completes the card",
          "never lowered",
          "a migration or a security path",
          "400 changed lines",
          "keeps it"
        ],
        do: assert_states(text, part, inspect(part))
  end

  # #2349: a spike's tier is none, so nothing that lists the defaults may
  # still put it with schema and security under before_merge, or say it
  # waits for a person, or is held. The skills too (#2351).
  @stale_spike [
    ~r/before_merge[ (]*schema[ ,\/]+security[ ,\/]+(and )?spike/,
    ~r/schema[ ,\/]+security[ ,\/]+(and |or )?spike[ )]*(before_merge|changes wait|wait|card an agent accepts (is )?(held|waits))/
  ]

  test "nothing lists spike's tier as before_merge" do
    files =
      Enum.flat_map(
        ["lib/**/*.ex", "docs/**/*.md", "priv/skills/**/*.md"],
        &Path.wildcard(Path.join(@root, &1))
      ) ++
        Enum.map(["README.md", "cli/help.txt"], &Path.join(@root, &1))

    stale =
      for file <- files,
          text = file |> File.read!() |> flatten(),
          Enum.any?(@stale_spike, &Regex.match?(&1, text)),
          do: Path.relative_to(file, @root)

    assert stale == []
  end

  test "the stale wording is caught, wrapped or quoted" do
    for stale <- [
          "default puts it back (docs/fix none, feature ledger,\n   schema/security/spike before_merge)",
          "`before_merge` (`schema`, `security`,\n`spike`) holds it",
          "| `before_merge` | `schema`, `security`, `spike` | holds the card |",
          "by default schema, security and spike changes wait for you",
          "a schema, security or spike card an agent accepts waits for a person",
          "a `schema`, `security` or `spike` card an agent\n  accepts is *held* for a person",
          "\"docs/fix none, feature ledger, schema/security/spike before_merge.\""
        ],
        do: assert(Enum.any?(@stale_spike, &Regex.match?(&1, flatten(stale))), stale)

    refute Enum.any?(
             @stale_spike,
             &Regex.match?(&1, flatten("docs/fix/spike none, schema/security before_merge"))
           )
  end

  # Backticks, table pipes, quotes, emphasis and string joins out; one space.
  defp flatten(text) do
    text
    |> String.replace(~r/[`|"*]/, " ")
    |> String.replace(~r/\s*<>\s*/, " ")
    |> String.replace(~r/\s+/, " ")
  end
end
