defmodule SlipdockCLI.FolderFileAlsoTest do
  @moduledoc "`slipdock folder file --also/--not-in` and `folder show`: one folder in several places (#808)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Render, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-falso-#{System.unique_integer([:positive])}")
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

  @folder ~s({"folder":{"id":7,"path":"Home/Topic","slug":"topic","also_in":[{"path":"Ideas","board":"kb"},{"path":"Notes","board":"jobs"}]}})

  defp run(args, opts, responses) do
    System.put_env("SLIPDOCK_URL", FakeServer.start(responses))
    capture_io(fn -> Wiki.run("folder", args, opts) end)
  end

  test "--also, repeated, sends one change each to the folder's path, and lists where it is filed" do
    out =
      run(["file", "kb", "Home/Topic"], [also: "Ideas", also: "/Journal/Notes"], [
        {200, @folder},
        {200, @folder}
      ])

    assert_received {:request, "PATCH", path, body}
    assert path =~ "/boards/kb/folders/Home/Topic"
    assert body == ~s({"also":"Ideas"})
    assert_received {:request, "PATCH", _path, body}
    assert body == ~s({"also":"/Journal/Notes"})

    assert out =~ "Home/Topic"
    assert out =~ "also in Ideas"
    assert out =~ "also in Notes"
  end

  test "--not-in and --board go as not_in and in_board" do
    run(["file", "kb", "Topic"], [not_in: "Notes", board: "jobs"], [{200, @folder}])
    assert_received {:request, "PATCH", _path, body}
    assert body =~ ~s("not_in":"Notes")
    assert body =~ ~s("in_board":"jobs")
  end

  test "a refusal stops at once: the rest are not sent, and the refusal is the answer" do
    refused = ~s({"error":"“Topic” cannot be filed in Topic/Inner: it is inside “Topic”"})
    System.put_env("SLIPDOCK_URL", FakeServer.start([{422, refused}]))

    assert {:error, 422, %{"error" => msg}} =
             Wiki.file_folder(
               "/boards/kb/folders/Topic",
               [{"also", "Topic/Inner"}, {"also", "Ideas"}],
               nil
             )

    assert msg =~ "inside"
    assert_received {:request, "PATCH", _path, _body}
    refute_received {:request, "PATCH", _path, _body}
  end

  test "folder show prints its path and where else it is filed" do
    out = run(["show", "kb", "Home/Topic"], [], [{200, @folder}])
    assert_received {:request, "GET", path, _}
    assert path =~ "/boards/kb/folders/Home/Topic"
    assert out =~ "also in Ideas"
  end

  test "folder ls marks a folder also filed elsewhere" do
    folders = [
      %{
        "name" => "Topic",
        "slug" => "topic",
        "also_in" => [%{"path" => "Ideas"}],
        "folders" => [],
        "pages" => []
      },
      %{"name" => "Ideas", "slug" => "ideas", "also_in" => [], "folders" => [], "pages" => []}
    ]

    out = capture_io(fn -> Render.folders(folders, []) end)
    assert out =~ ~r/Topic.*also in Ideas/
    refute out =~ ~r/Ideas.*also in/
  end
end
