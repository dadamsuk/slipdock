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

  test "folder mv --board --contents --dry-run sends to_board and prints the report" do
    report =
      ~s({"dry_run":true,"board":"hunt","report":{"into":"Job Hunt","folders":2,"pages":201,"files":3,
        "per_folder":[{"path":"Jobs","pages":180},{"path":"Jobs/Acme","pages":21},{"path":"Jobs/Empty","pages":0}],
        "tags":{"carried":["ops"],"dropped":["kb"]},"fields":{"carried":[],"dropped":[]},
        "pins":{"carried":[],"dropped":[]},"assignees":{"carried":[],"dropped":["Sam"]},
        "left_behind":["Odd one"],"filing_dropped":2,"title_clashes":["Readme"]}})

    {method, path, body, out} =
      run("folder", ["mv", "kb", "Jobs"], [board: "hunt", contents: true, dry_run: true], report)

    assert method == "PATCH"
    assert path =~ "/boards/kb/folders/Jobs"
    assert body =~ ~s("to_board":"hunt")
    assert body =~ ~s("contents":true)
    assert body =~ ~s("dry_run":true)
    assert out =~ "moving Jobs to hunt would move:"
    assert out =~ "2 folder(s), 201 page(s), 3 file(s)"
    assert out =~ "Jobs/Acme: 21"
    refute out =~ "Jobs/Empty"
    assert out =~ "drop tags: kb"
    assert out =~ "let go of assignees: Sam"
    assert out =~ "leave behind (under a page that stays): Odd one"
    assert out =~ "land beside pages of the same title: Readme"
    assert out =~ "take away 2 filing(s)"
  end

  test "folder mv without --board still moves within the board" do
    {method, _path, body, _out} =
      run(
        "folder",
        ["mv", "kb", "Jobs"],
        [root: true],
        ~s({"folder":{"id":1,"name":"Jobs","path":"Jobs"}})
      )

    assert method == "PATCH"
    refute body =~ "to_board"
  end
end
