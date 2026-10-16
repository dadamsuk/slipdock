defmodule Slipdock.JobScanPackageTest do
  @moduledoc """
  The job-scan Tool kept in `packages/job-scan` (#966) is a package the
  server accepts, and the board it builds is the one its skills expect:
  Found is where work is taken from, Closed is done, and documents are
  queued from Generate.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Tools, Wiki}
  alias Slipdock.Tools.Package

  @dir Path.expand("../../packages/job-scan", __DIR__)

  defp entries do
    @dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Path.relative_to(&1, @dir), File.read!(&1)})
  end

  defp tarball do
    path = Path.join(System.tmp_dir!(), "job-scan-#{System.unique_integer([:positive])}.tar.gz")
    tar = Enum.map(entries(), fn {p, c} -> {String.to_charlist(p), c} end)
    :ok = :erl_tar.create(String.to_charlist(path), tar, [:compressed, :write])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  test "the package reads, with its three skills" do
    assert {:ok, package} = Package.read(tarball())
    assert package.manifest["name"] == "job-scan"
    assert Enum.map(package.skills, & &1.name) == ~w(job-scan job-scan-build job-scan-setup)
    assert Enum.all?(package.skills, &(is_binary(&1.description) and &1.description != ""))
  end

  test "its board has the roles the skills rely on, the six pages and the Generate rule" do
    user = user_fixture()
    {:ok, version} = Tools.publish(user, tarball())
    Slipdock.TestConfig.own_uploads_dir()
    {:ok, %{board: board}} = Tools.install_board(user, version.tool)

    assert Enum.map(board.columns, & &1.name) ==
             ["Found", "Interested", "Generate", "Ready", "Applied", "In conversation", "Closed"]

    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    assert roles.ready.name == "Found"
    assert roles.done.name == "Closed"

    titles = board |> Wiki.list_pages() |> Enum.map(& &1.title) |> Enum.sort()

    assert titles ==
             Enum.sort([
               "Job Scan Config",
               "Job Scan Search Profile",
               "Job Scan Decision Rules",
               "Job Scan About Me",
               "Job Scan CV Baseline",
               "Job Scan Document Rules"
             ])

    assert [rule] = Automations.list_rules(board.id)
    assert rule.spec["trigger"] == %{"type" => "card_entered", "column" => "Generate"}
    assert [%{"type" => "runner", "pool" => "default"} | _] = rule.spec["actions"]
  end

  test "the skills find the board through the install, not a page title" do
    scan = File.read!(Path.join(@dir, "skills/job-scan/SKILL.md"))
    setup = File.read!(Path.join(@dir, "skills/job-scan-setup/SKILL.md"))

    assert scan =~ "`list_tools`"
    assert scan =~ "installed.board"
    assert setup =~ "`install_tool` with `tool: \"job-scan\"`"
    refute setup =~ "Use `create_board`"
  end
end
