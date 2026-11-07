defmodule Slipdock.ProfilesDocsTest do
  @moduledoc """
  Profiles and the human tier (#1950) where a reader starts: the README's
  feature bullet links the manual's sections and names the switch, the tier
  setting and the six profiles; the in-app help names the chip, the select
  and the board settings.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Profiles

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

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
          "docs/manual.md#profiles",
          "docs/manual.md#the-human-tier",
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
end
