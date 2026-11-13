defmodule SlipdockCLI.WholeWikiTest do
  @moduledoc """
  `slipdock wiki show|set|locate|resolve|wanted|changes` (W-2201): what each
  sends, to `/api/wiki/...` with no wiki named, and how its answer reads; and
  `slipdock vault`, which says where it went.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, WholeWiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-wiki-#{System.unique_integer([:positive])}")
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

  @wiki ~s({"pages":12,"knowledge_base":{"id":9,"code":"kb","name":"Knowledge Base"},"boards":[
    {"id":9,"code":"kb","name":"Knowledge Base","path":"/Knowledge Base","archived":false},
    {"id":1,"code":"plan","name":"Keystone","path":"/Keystone","archived":false}]})
  @show ~s({"wiki":#{@wiki},"boards":[]})

  defp run(args, opts \\ [], response \\ @show) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> WholeWiki.wiki(args, opts) end)
    assert_received {:request, method, path, body}
    {method, path, body, out}
  end

  test "show asks for the one wiki and prints its Knowledge Base, boards and pages" do
    {"GET", path, _, out} = run(["show"])
    assert path =~ ~r{/api/wiki$}
    assert out =~ "Your wiki"
    assert out =~ "Knowledge Base: Knowledge Base (kb)"
    assert out =~ "/Keystone"
    assert out =~ "12 pages"
    refute out =~ ~r/vault/i
  end

  test "show says when the wiki has no boards yet" do
    {_, _, _, out} = run(["show"], [], ~s({"wiki":{"boards":[]},"boards":[]}))
    assert out =~ "no boards yet"
  end

  test "locate sends the path to /api/wiki/locate" do
    response =
      ~s({"board":{"id":2,"code":"jobs","name":"Journal Desk","path":"/Journal Desk"},"rest":"Acme/Call.md"})

    {"GET", path, _, out} = run(["locate", "/Journal Desk/Acme/Call.md"], [], response)
    assert path =~ "/api/wiki/locate?path="
    assert out =~ "/Journal Desk"
    assert out =~ "then Acme/Call.md"
  end

  test "resolve sends the link's words and prints the page and its path" do
    response = ~s({"page":{"code":"W-9","title":"Acme"},"path":"/Journal/Acme"})
    {"GET", path, _, out} = run(["resolve", "Journal/Acme"], [], response)
    assert path =~ "/api/wiki/resolve?link=Journal%2FAcme"
    assert out =~ "W-9 Acme"
    assert out =~ "/Journal/Acme"
  end

  test "wanted lists each wanted page with where it is wanted from" do
    response = ~s({"wanted":[{"title":"Ghost","count":2,"from":[{"code":"W-1"},{"code":"W-2"}]}]})
    {"GET", path, _, out} = run(["wanted"], [], response)
    assert path =~ ~r{/api/wiki/wanted$}
    assert out =~ "[[Ghost]]"
    assert out =~ "from W-1, W-2"

    {_, _, _, none} = run(["wanted"], [], ~s({"wanted":[]}))
    assert none =~ "every link in your wiki finds a page"
  end

  test "changes asks for what changed after --since and prints each with the cursor" do
    response =
      ~s({"changes":[{"cursor":12,"subject":"page","action":"changed","path":"/Journal/Acme","id":4},{"cursor":13,"subject":"folder","action":"deleted","id":9}],"cursor":13,"more":true})

    {"GET", path, _, out} = run(["changes"], [since: 11, limit: 2], response)
    assert path =~ "/api/wiki/changes?"
    assert path =~ "since=11"
    assert path =~ "limit=2"
    assert out =~ "page changed  /Journal/Acme"
    assert out =~ "folder deleted  #9"
    assert out =~ "cursor 13 — more to come"
  end

  test "changes says to resync when the cursor is older than what is kept" do
    {_, _, _, out} =
      run(["changes"], [since: 1], ~s({"changes":[],"cursor":900,"more":false,"resync":true}))

    assert out =~ "resync"
    assert out =~ "list your wiki again"
    assert out =~ "cursor 900"
  end

  describe "slipdock wiki routes its whole-wiki subcommands" do
    test "through SlipdockCLI.Wiki, the plain listing staying there" do
      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"wanted":[]})}]))
      capture_io(fn -> SlipdockCLI.Wiki.run("wiki", ["wanted"], []) end)
      assert_received {:request, "GET", path, _}
      assert path =~ ~r{/api/wiki/wanted$}
    end
  end

  describe "slipdock vault" do
    test "is gone, and says to use slipdock wiki" do
      assert "vault" in WholeWiki.commands()
      assert WholeWiki.vault_gone() =~ "Use `slipdock wiki`"
      assert WholeWiki.vault_gone() =~ "one wiki"
    end
  end

  describe "help" do
    test "offers the wiki commands and no vault commands" do
      help = capture_io(fn -> SlipdockCLI.main(["help"]) end)

      for sub <- ~w(show set locate resolve wanted changes tree import),
          do: assert(help =~ "wiki #{sub}", "wiki #{sub} is missing from the help")

      refute help =~ ~r/^\s+vault /m
      refute help =~ "--vault"
      assert help =~ "sync init <dir>  "
    end
  end

  describe "recordings on Google Drive (W-1690)" do
    test "wiki set --recordings-folder sends the folder to PATCH /api/wiki" do
      response = ~s({"wiki":{"boards":[],"recordings_folder":"Meeting Recordings"}})

      {"PATCH", path, body, out} =
        run(["set"], [recordings_folder: "Meeting Recordings"], response)

      assert path =~ ~r{/api/wiki$}
      assert body =~ ~s("recordings_folder":"Meeting Recordings")
      assert out =~ "your wiki plays its recordings from Meeting Recordings on Google Drive"
    end

    test "wiki set with an empty folder clears it" do
      response = ~s({"wiki":{"boards":[],"recordings_folder":null}})
      {"PATCH", _path, body, out} = run(["set"], [recordings_folder: ""], response)
      assert body =~ ~s("recordings_folder":"")
      assert out =~ "your wiki has no recordings folder now"
    end

    test "show names the recordings folder" do
      response = ~s({"wiki":{"boards":[],"recordings_folder":"Rec"},"boards":[]})
      {"GET", _, _, out} = run(["show"], [], response)
      assert out =~ "recordings: Rec on Google Drive"
    end

    test "drive status, connected" do
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([
          {200,
           ~s({"drive":{"status":"connected","email":"me@example.com"},"vaults":[{"id":3,"name":"Notes","recordings_folder":"Rec"}]})}
        ])
      )

      out = capture_io(fn -> WholeWiki.run("drive", ["status"], []) end)
      assert_received {:request, "GET", path, _}
      assert path =~ "/api/me/drive"
      assert out =~ "Google Drive: connected as me@example.com"
      assert out =~ "your wiki: Rec"
      refute out =~ "Notes"
    end

    test "drive status, not connected and not set up" do
      for {status, words} <- [
            {"not_connected", "not connected — connect it on Account → Preferences"},
            {"revoked", "no longer accepted by Google"},
            {"not_configured", "not set up on this server"}
          ] do
        System.put_env(
          "SLIPDOCK_URL",
          FakeServer.start([{200, ~s({"drive":{"status":"#{status}","email":null},"vaults":[]})}])
        )

        out = capture_io(fn -> WholeWiki.run("drive", [], []) end)
        assert_received {:request, "GET", _, _}
        assert out =~ words
        assert out =~ "your wiki: no recordings folder"
      end
    end
  end
end
