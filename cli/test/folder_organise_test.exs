defmodule SlipdockCLI.FolderOrganiseTest do
  @moduledoc "`slipdock folder organise`: a folder's Organise… from the command line (#791)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-organise-#{System.unique_integer([:positive])}")
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

  defp run(args, opts, response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> Wiki.run("folder", args, opts) end)
    assert_received {:request, "POST", path, body}
    {path, JSON.decode!(body), out}
  end

  @plan ~s([{"key":"page:7","kind":"page","id":7,"title":"Standup","from":"Inbox","to":"Meetings/2026-10"}])

  test "a dry run sends the options and prints the plan" do
    {path, body, out} =
      run(
        ["organise", "notes", "Inbox"],
        [by: "date", parent: "Meetings", per: "year", added: true, dry_run: true],
        ~s({"dry_run":true,"plan":#{@plan}})
      )

    assert path =~ "/boards/notes/organise"

    assert body == %{
             "folder" => "Inbox",
             "mode" => "date",
             "parent" => "Meetings",
             "granularity" => "year",
             "source" => "added",
             "dry_run" => true
           }

    assert out =~ "page:7  Standup  /Inbox → /Meetings/2026-10"
    assert out =~ "dry run: 1 item(s) would move"
  end

  test "--root files under the top; the result and what was skipped are printed" do
    {_path, body, out} =
      run(
        ["organise", "notes", "Inbox"],
        [by: "date", root: true],
        ~s({"plan":#{@plan},"moved":0,"folders_made":2,"skipped":[{"title":"Standup","reason":"it has changed since the plan was made"}]})
      )

    assert body["parent"] == ""
    refute Map.has_key?(body, "dry_run")
    assert out =~ "moved 0 item(s), made 2 folder(s)"
    assert out =~ "left where it was: Standup (it has changed since the plan was made)"
  end

  test "an empty dry run says nothing would move" do
    {_path, body, out} =
      run(
        ["organise", "notes", "Inbox"],
        [by: "ai", dry_run: true],
        ~s({"dry_run":true,"plan":[]})
      )

    assert body["mode"] == "ai"
    assert out =~ "nothing here would move"
  end
end
