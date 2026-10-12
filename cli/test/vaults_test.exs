defmodule SlipdockCLI.VaultsTest do
  @moduledoc "`slipdock vault …`: what each command sends, and how its answer reads."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Vaults}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-vaults-#{System.unique_integer([:positive])}")
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

  @one ~s({"id":3,"name":"Notes","mappings":[
    {"id":1,"path":"/","board":{"id":1,"code":"kb","name":"KnowledgeBase"},"folder":null},
    {"id":2,"path":"/Jobs","board":{"id":2,"code":"jobs","name":"Job Hunt"},"folder":{"id":9,"path":"Notes"}}]})
  @vault ~s({"vault":#{@one}})

  defp run(args, opts \\ [], response \\ @vault) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Vaults.run("vault", args, opts) end)
    assert_received {:request, method, path, body}
    {method, path, body, out}
  end

  test "ls lists each vault with its mappings, root first" do
    {"GET", path, _, out} = run(["ls"], [], ~s({"vaults":[#{@one}]}))
    assert path =~ "/api/vaults"
    assert out =~ "Notes"
    assert out =~ "KnowledgeBase wiki"
    assert out =~ "Job Hunt wiki, folder Notes"
  end

  test "ls with none says how to make one" do
    {_, _, _, out} = run(["ls"], [], ~s({"vaults":[]}))
    assert out =~ "slipdock vault new"
  end

  test "new sends the words as one name" do
    {"POST", path, body, out} = run(["new", "My", "Notes"])
    assert path =~ "/api/vaults"
    assert body =~ ~s("name":"My Notes")
    assert out =~ "made Notes"
  end

  test "map sends path, board and folder" do
    {"POST", path, body, out} = run(["map", "Notes", "/Jobs"], board: "jobs", folder: "Notes")
    assert path =~ "/api/vaults/Notes/mappings"
    assert body =~ ~s("path":"/Jobs")
    assert body =~ ~s("board":"jobs")
    assert body =~ ~s("folder":"Notes")
    assert out =~ "mapped Notes"
  end

  test "unmap names the mapping by path in the query" do
    {"DELETE", path, _, _} = run(["unmap", "Notes", "/Jobs"])
    assert path =~ "/api/vaults/Notes/mappings?path=%2FJobs"
  end

  test "locate prints the mapping and what is left of the path" do
    response =
      ~s({"mapping":{"id":2,"path":"/Jobs","board":{"id":2,"code":"jobs","name":"Job Hunt"},"folder":null},"rest":"Acme/Call.md"})

    {"GET", path, _, out} = run(["locate", "Notes", "/Jobs/Acme/Call.md"], [], response)
    assert path =~ "/api/vaults/Notes/locate?path="
    assert out =~ "/Jobs"
    assert out =~ "then Acme/Call.md"
  end

  test "rm says the pages stay" do
    {"DELETE", path, _, out} = run(["rm", "Notes"], [], ~s({"deleted":{"id":3,"name":"Notes"}}))
    assert path =~ "/api/vaults/Notes"
    assert out =~ "every page stays"
  end

  test "resolve sends the link's words and prints the page and its path" do
    response = ~s({"page":{"code":"W-9","title":"Acme"},"path":"/Jobs/Acme"})
    {"GET", path, _, out} = run(["resolve", "Notes", "Jobs/Acme"], [], response)
    assert path =~ "/api/vaults/Notes/resolve?link=Jobs%2FAcme"
    assert out =~ "W-9 Acme"
    assert out =~ "/Jobs/Acme"
  end

  test "wanted lists each wanted page with where it is wanted from" do
    response = ~s({"wanted":[{"title":"Ghost","count":2,"from":[{"code":"W-1"},{"code":"W-2"}]}]})
    {"GET", path, _, out} = run(["wanted", "Notes"], [], response)
    assert path =~ "/api/vaults/Notes/wanted"
    assert out =~ "[[Ghost]]"
    assert out =~ "from W-1, W-2"

    {_, _, _, none} = run(["wanted", "Notes"], [], ~s({"wanted":[]}))
    assert none =~ "nothing wanted"
  end

  test "changes asks for what changed after --since and prints each with the cursor" do
    response =
      ~s({"changes":[{"cursor":12,"subject":"page","action":"changed","path":"/Jobs/Acme","id":4},{"cursor":13,"subject":"folder","action":"deleted","id":9}],"cursor":13,"more":true})

    {"GET", path, _, out} = run(["changes", "Notes"], [since: 11, limit: 2], response)
    assert path =~ "/api/vaults/Notes/changes?"
    assert path =~ "since=11"
    assert path =~ "limit=2"
    assert out =~ "page changed  /Jobs/Acme"
    assert out =~ "folder deleted  #9"
    assert out =~ "cursor 13 — more to come"
  end

  test "changes says to resync when the cursor is older than what is kept" do
    {_, _, _, out} =
      run(
        ["changes", "Notes"],
        [since: 1],
        ~s({"changes":[],"cursor":900,"more":false,"resync":true})
      )

    assert out =~ "resync"
    assert out =~ "cursor 900"
  end
end
