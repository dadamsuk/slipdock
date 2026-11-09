defmodule Slipdock.MachinesDocsTest do
  @moduledoc """
  Machines' enrolment (#2570) is written where people and agents look: the
  agent guide and `docs/agents.md` name the endpoints, the machine key and
  why there is no MCP door; README and the agents help page say what a
  machine key is; and the manual's account page lists Account › Machines
  and the approval page.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the guide and docs/agents.md describe enrolment the same way" do
    for text <- [SlipdockWeb.APIGuide.markdown(), read("docs/agents.md")] do
      for part <- [
            "POST /api/machines/enrol",
            "POST\n/api/machines/enrol/token",
            "/account/machines/approve",
            "POST /api/machines/enrolment-keys",
            "GET /api/machine",
            "DELETE /api/machines/:id",
            "/api/machines/enrolment/approve",
            "sdm_",
            "Not over MCP",
            "slipdock machines"
          ] do
        assert text =~ String.replace(part, "\n", " ") or text =~ part, "missing #{part}"
      end
    end
  end

  test "README and the agents help page say what a machine key is" do
    assert read("README.md") =~ "A machine running runners has a key of its own, not your token."

    help = read("lib/slipdock_web/live/help_live/agents.ex")
    assert help =~ ~s(id="help-machines")
    assert help =~ "which is not an API\n        token"
  end

  test "the manual's account page lists Machines and the approval page" do
    manual = read("docs/manual/accounts-and-sharing.md")
    assert manual =~ "**Machines** (`/account/machines`)"
    assert manual =~ "/account/machines/approve"
  end
end
