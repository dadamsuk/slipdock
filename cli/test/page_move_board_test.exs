defmodule SlipdockCLI.PageMoveBoardTest do
  @moduledoc "`slipdock page mv --board` and `folder mv --sort` (W-103 R11.8, R11.9)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-mvboard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp run(group, args, opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Wiki.run(group, args, opts) end)
    assert_received {:request, method, path, body}
    {method, path, body, out}
  end

  test "page mv --board --dry-run prints what would stay behind" do
    report =
      ~s({"dry_run":true,"board":"jobs","report":{"pages":2,"tags":{"carried":["ops"],"dropped":["kb"]},
        "fields":{"carried":[],"dropped":[]},"pins":{"carried":[],"dropped":["Card A"]},
        "assignee":{"carried":null,"dropped":null},"list":"Doing","parent":null}})

    {method, path, body, out} =
      run("page", ["mv", "W-7"], [board: "jobs", folder: "Acme", dry_run: true], report)

    assert method == "POST"
    assert path =~ "/pages/W-7/move"
    assert body =~ ~s("board":"jobs")
    assert body =~ ~s("folder":"Acme")
    assert body =~ ~s("dry_run":true)
    assert out =~ "take 1 page(s) under it along"
    assert out =~ "drop tags: kb"
    assert out =~ "unpin cards: Card A"
    assert out =~ "leave its list: Doing"
    refute out =~ "drop field values"
  end

  test "page mv --board moves it" do
    {_m, _p, body, out} =
      run(
        "page",
        ["mv", "W-7"],
        [board: "jobs"],
        ~s({"page":{"code":"W-7","title":"Call","url":"/boards/2/wiki/call"}})
      )

    refute body =~ "dry_run"
    assert out =~ "moved"
  end

  test "folder mv --sort sends the sort" do
    {method, path, body, _out} =
      run(
        "folder",
        ["mv", "kb", "Specs"],
        [sort: "name"],
        ~s({"folder":{"path":"Specs","slug":"specs","id":1}})
      )

    assert method == "PATCH"
    assert path =~ "/boards/kb/folders/Specs"
    assert body =~ ~s("sort":"name")
  end
end
