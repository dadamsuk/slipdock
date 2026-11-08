defmodule SlipdockWeb.EveryInstanceDocsTest do
  @moduledoc """
  Every instance in one rejection (#2071, after #2046) is said where people
  and agents read how to verify: the manual's Verified work (the verdict in
  parts and the resubmission paragraph), the CLI's `verify --check` help and
  the MCP `verify_card` tool's `checks` description.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.MCP.Tools.VerifyCard

  @root Path.expand("../..", __DIR__)

  defp flat(path), do: @root |> Path.join(path) |> File.read!() |> squash()
  defp squash(text), do: String.replace(text, ~r/\s+/, " ")

  # The paragraph of the manual's bullet list that starts with `lead`.
  defp manual_bullet(lead) do
    manual = flat("docs/manual.md")
    [_, rest] = String.split(manual, "- **" <> lead, parts: 2)
    rest |> String.split(" - **", parts: 2) |> hd()
  end

  test "the verdict in parts gives one broken line per instance, all in one rejection" do
    para = manual_bullet("The verdict in parts.")

    assert para =~ "A rejection names every instance found"
    assert para =~ "one `rule:<id>=broken:<file>:<line>` line per instance"
    assert para =~ "all in one rejection"
    assert para =~ "its instances are listed under the rule"
    assert para =~ "never the first now and the next in another round"
  end

  test "the resubmission paragraph says the same: every instance, under the one rule" do
    para = manual_bullet("A resubmission is judged on what changed.")

    assert para =~ "under the one rule"
    assert para =~ "a `rule:<id>=broken:<file>:<line>` line for every instance it finds"
    assert para =~ "all in this rejection"
  end

  test "the CLI's verify --check help says it in a line" do
    help = flat("cli/help.txt")
    [_, entry] = String.split(help, "--check PART=RESULT[:note]", parts: 2)
    [entry, _] = String.split(entry, "--checks-file F", parts: 2)

    assert entry =~ "A rule broken in several places"
    assert entry =~ "rule:UX-4=broken:lib/x.ex:42 per instance"
    assert entry =~ "every one found, all in this reject (listed under the rule)"
  end

  test "verify_card's checks description says it in a line" do
    desc = squash(VerifyCard.input_schema().properties.checks.description)

    assert desc =~ "a rule broken in several places"
    assert desc =~ "one rule:UX-4=broken:<file>:<line>[:why] per instance"
    assert desc =~ "every one found, all in this rejection (listed under the rule)"
  end
end
