defmodule SlipdockCLI.PageFileAlsoTest do
  @moduledoc "`slipdock page file --also/--not-in`: one page filed in several folders."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-also-#{System.unique_integer([:positive])}")
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

  @page ~s({"page":{"code":"W-31","title":"Note","url":"/x","also_in":[{"path":"Notes","board":"jobs"}]}})

  defp run(opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @page}]))
    out = capture_io(fn -> Wiki.run("page", ["file", "W-31"], opts) end)
    assert_received {:request, "POST", path, body}
    {path, body, out}
  end

  test "--also sends the folder (and --board), and lists where it is also filed" do
    {path, body, out} = run(also: "/Journal/Notes", board: "jobs")
    assert path =~ "/pages/W-31/folder"
    assert body =~ ~s("also":"/Journal/Notes")
    assert body =~ ~s("board":"jobs")
    refute body =~ ~s("folder")
    assert out =~ "filed W-31 Note"
    assert out =~ "also in Notes"
  end

  test "--not-in sends the folder to take it out of" do
    {_path, body, _out} = run(not_in: "Notes")
    assert body =~ ~s("not_in":"Notes")
  end

  test "--folder alone still files its home" do
    {_path, body, _out} = run(folder: "Home")
    assert body == ~s({"folder":"Home"})
  end
end
