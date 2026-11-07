defmodule SlipdockCLI.ProfilesRecheckTest do
  @moduledoc """
  The actual change on the CLI (#2017): `done --changed-lines` and
  `--changed-files` send it with the completion, `--diff-base REF` counts it
  from `git diff --numstat` (REF...the evidence commit, else HEAD), and the
  flags given by hand win over the count.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-recheck-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)
    cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(cwd)

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp parse(argv) do
    {opts, _args, []} = OptionParser.parse(argv, strict: SlipdockCLI.switches())
    opts
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  @card ~s({"card":{"id":12,"title":"Work","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  test "done --changed-lines and --changed-files send the change" do
    serve([{200, @card}])

    capture_io(fn ->
      Boards.run(
        "done",
        ["12"],
        parse([
          "--changed-lines",
          "612",
          "--changed-files",
          "lib/a.ex, priv/repo/migrations/1.exs"
        ])
      )
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}

    assert JSON.decode!(body) == %{
             "completed" => true,
             "changed_lines" => 612,
             "changed_files" => ["lib/a.ex", "priv/repo/migrations/1.exs"]
           }
  end

  test "done without them sends no change" do
    serve([{200, @card}])
    capture_io(fn -> Boards.run("done", ["12"], parse([])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true}
  end

  test "numstat adds and removes, and a binary file counts no lines" do
    out = "10\t2\tlib/a.ex\n-\t-\tpriv/static/logo.png\n0\t5\tdocs/a b.md\n"

    assert Boards.numstat(out) == %{
             "changed_lines" => 17,
             "changed_files" => ["lib/a.ex", "priv/static/logo.png", "docs/a b.md"]
           }

    assert Boards.numstat("") == %{"changed_lines" => 0, "changed_files" => []}
  end

  test "done --diff-base counts the change from git; flags given by hand win", %{home: home} do
    repo = Path.join(home, "repo")
    File.mkdir_p!(repo)
    git(repo, ["init", "-q", "-b", "main"])
    git(repo, ["config", "user.email", "dev@example.com"])
    git(repo, ["config", "user.name", "Dev"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git(repo, ["add", "."])
    git(repo, ["commit", "-q", "-m", "base"])
    git(repo, ["switch", "-q", "-c", "card-12"])
    File.write!(Path.join(repo, "a.txt"), "one\ntwo\nthree\n")
    File.mkdir_p!(Path.join(repo, "priv/repo/migrations"))
    File.write!(Path.join(repo, "priv/repo/migrations/1_add.exs"), "x\n")
    git(repo, ["add", "."])
    git(repo, ["commit", "-q", "-m", "work"])
    File.cd!(repo)

    serve([{200, @card}, {200, @card}])
    capture_io(fn -> Boards.run("done", ["12"], parse(["--diff-base", "main"])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}

    assert JSON.decode!(body) == %{
             "completed" => true,
             "changed_lines" => 3,
             "changed_files" => ["a.txt", "priv/repo/migrations/1_add.exs"]
           }

    capture_io(fn ->
      Boards.run("done", ["12"], parse(["--diff-base", "main", "--changed-lines", "900"]))
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert %{"changed_lines" => 900, "changed_files" => [_, _]} = JSON.decode!(body)
  end
end
