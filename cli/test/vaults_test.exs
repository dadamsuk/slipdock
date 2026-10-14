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
    {"id":1,"path":"/","board":{"id":1,"code":"kb","name":"Keystone"},"folder":null},
    {"id":2,"path":"/Journal","board":{"id":2,"code":"jobs","name":"Journal Desk"},"folder":{"id":9,"path":"Notes"}}]})
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
    assert out =~ "Keystone wiki"
    assert out =~ "Journal Desk wiki, folder Notes"
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

  test "new --with-board asks for a board to hold its pages (#757)" do
    {"POST", _path, body, _out} = run(["new", "Brain"], with_board: true)
    assert body =~ ~s("with_board":true)

    {"POST", _path, body, _out} = run(["new", "Brain"])
    refute body =~ "with_board"
  end

  test "map --inside keeps the board inside the vault" do
    {"POST", _path, body, _out} = run(["map", "Notes", "/"], board: "kb", inside: true)
    assert body =~ ~s("inside":true)
  end

  test "inside keeps a mapped board inside, --off lets it out, and ls says which" do
    inside =
      ~s({"vault":{"id":3,"name":"Notes","mappings":[
        {"id":1,"path":"/","board":{"id":1,"code":"kb","name":"Keystone"},"folder":null,"inside":true}]}})

    {"PATCH", path, body, out} = run(["inside", "Notes", "/"], [], inside)
    assert path =~ "/api/vaults/Notes/mappings"
    assert body =~ ~s("inside":true)
    assert body =~ ~s("path":"/")
    assert out =~ "kept inside Notes"
    assert out =~ "· kept inside"

    {"PATCH", _path, body, out} = run(["inside", "Notes", "/"], off: true)
    assert body =~ ~s("inside":false)
    assert out =~ "let out Notes"
    refute out =~ "· kept inside"
  end

  test "map sends path, board and folder" do
    {"POST", path, body, out} = run(["map", "Notes", "/Journal"], board: "jobs", folder: "Notes")
    assert path =~ "/api/vaults/Notes/mappings"
    assert body =~ ~s("path":"/Journal")
    assert body =~ ~s("board":"jobs")
    assert body =~ ~s("folder":"Notes")
    assert out =~ "mapped Notes"
  end

  test "unmap names the mapping by path in the query" do
    {"DELETE", path, _, _} = run(["unmap", "Notes", "/Journal"])
    assert path =~ "/api/vaults/Notes/mappings?path=%2FJournal"
  end

  test "locate prints the mapping and what is left of the path" do
    response =
      ~s({"mapping":{"id":2,"path":"/Journal","board":{"id":2,"code":"jobs","name":"Journal Desk"},"folder":null},"rest":"Acme/Call.md"})

    {"GET", path, _, out} = run(["locate", "Notes", "/Journal/Acme/Call.md"], [], response)
    assert path =~ "/api/vaults/Notes/locate?path="
    assert out =~ "/Journal"
    assert out =~ "then Acme/Call.md"
  end

  test "rm says the pages stay" do
    {"DELETE", path, _, out} = run(["rm", "Notes"], [], ~s({"deleted":{"id":3,"name":"Notes"}}))
    assert path =~ "/api/vaults/Notes"
    assert out =~ "every page stays"
  end

  test "resolve sends the link's words and prints the page and its path" do
    response = ~s({"page":{"code":"W-9","title":"Acme"},"path":"/Journal/Acme"})
    {"GET", path, _, out} = run(["resolve", "Notes", "Journal/Acme"], [], response)
    assert path =~ "/api/vaults/Notes/resolve?link=Journal%2FAcme"
    assert out =~ "W-9 Acme"
    assert out =~ "/Journal/Acme"
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
      ~s({"changes":[{"cursor":12,"subject":"page","action":"changed","path":"/Journal/Acme","id":4},{"cursor":13,"subject":"folder","action":"deleted","id":9}],"cursor":13,"more":true})

    {"GET", path, _, out} = run(["changes", "Notes"], [since: 11, limit: 2], response)
    assert path =~ "/api/vaults/Notes/changes?"
    assert path =~ "since=11"
    assert path =~ "limit=2"
    assert out =~ "page changed  /Journal/Acme"
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

  describe "recordings on Google Drive (W-1690)" do
    test "vault set --recordings-folder sends the folder" do
      response =
        ~s({"vault":{"id":3,"name":"Notes","mappings":[],"recordings_folder":"Meeting Recordings"}})

      {"PATCH", path, body, out} =
        run(["set", "Notes"], [recordings_folder: "Meeting Recordings"], response)

      assert path =~ "/api/vaults/Notes"
      assert body =~ ~s("recordings_folder":"Meeting Recordings")
      assert out =~ "Notes plays its recordings from Meeting Recordings on Google Drive"
    end

    test "vault set with an empty folder clears it" do
      response = ~s({"vault":{"id":3,"name":"Notes","mappings":[],"recordings_folder":null}})
      {"PATCH", _path, body, out} = run(["set", "Notes"], [recordings_folder: ""], response)
      assert body =~ ~s("recordings_folder":"")
      assert out =~ "Notes has no recordings folder now"
    end

    test "show names the recordings folder" do
      response = ~s({"vault":{"id":3,"name":"Notes","mappings":[],"recordings_folder":"Rec"}})
      {"GET", _, _, out} = run(["show", "Notes"], [], response)
      assert out =~ "recordings: Rec on Google Drive"
    end

    test "drive status, connected" do
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([
          {200,
           ~s({"drive":{"status":"connected","email":"me@example.com"},"vaults":[{"id":3,"name":"Notes","recordings_folder":"Rec"},{"id":4,"name":"Other","recordings_folder":null}]})}
        ])
      )

      out = capture_io(fn -> Vaults.run("drive", ["status"], []) end)
      assert_received {:request, "GET", path, _}
      assert path =~ "/api/me/drive"
      assert out =~ "Google Drive: connected as me@example.com"
      assert out =~ "Notes: Rec"
      assert out =~ "Other: no recordings folder"
    end

    test "drive status, not connected and not set up" do
      for {status, words} <- [
            {"not_connected", "not connected — connect it on Account → Settings"},
            {"revoked", "no longer accepted by Google"},
            {"not_configured", "not set up on this server"}
          ] do
        System.put_env(
          "SLIPDOCK_URL",
          FakeServer.start([{200, ~s({"drive":{"status":"#{status}","email":null},"vaults":[]})}])
        )

        out = capture_io(fn -> Vaults.run("drive", [], []) end)
        assert_received {:request, "GET", _, _}
        assert out =~ words
      end
    end
  end
end
