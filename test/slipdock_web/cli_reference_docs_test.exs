defmodule SlipdockWeb.CLIReferenceDocsTest do
  @moduledoc """
  The CLI command reference (#1884) as the docs describe it: the manual's CLI
  section, docs/agents.md and the README name the page, and the manual says
  it is made from `cli/help.txt`, the file `slipdock help` prints.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp flat(path),
    do: @root |> Path.join(path) |> Slipdock.DocsText.read!() |> String.replace(~r/\s+/, " ")

  test "the manual's CLI section names the page and its one source" do
    manual = flat("docs/manual.md")
    [_, cli] = String.split(manual, "## CLI `cli/` is a zero-dependency escript", parts: 2)
    [cli | _] = String.split(cli, " ## ", parts: 2)

    assert cli =~ "**command reference** (`/help/agents/cli/reference`, readable signed out)"
    assert cli =~ "`cli/help.txt`, the same file `slipdock help` prints"
  end

  test "docs/agents.md and the README point at it" do
    assert flat("docs/agents.md") =~
             "(`/help/agents/cli/reference`): every command in `slipdock help`"

    assert flat("README.md") =~ "CLI command at `/help/agents/cli/reference`"
  end
end
