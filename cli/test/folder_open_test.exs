defmodule SlipdockCLI.FolderOpenTest do
  @moduledoc "`slipdock folder open`: one level of the wiki tree (W-103 R11.1)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-tree-#{System.unique_integer([:positive])}")
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
    assert_received {:request, "GET", path, _}
    {path, out}
  end

  @rows ~s({"node":"root","rows":[
    {"kind":"folder","id":4,"title":"Design","pages":12,"count":3},
    {"kind":"page","id":7,"title":"Plan","code":"W-7","count":0,"draft":true},
    {"kind":"file","id":2,"title":"logo.png","content_type":"image/png","count":0}]})

  test "with no folder it opens the top of the wiki and draws each kind of row" do
    {path, out} = run(["open", "handbook"], [], @rows)

    assert path =~ "/boards/handbook/tree"
    refute path =~ "folder="
    assert out =~ "Design/"
    assert out =~ "12 page(s) · folder:4"
    assert out =~ "▸ 3"
    assert out =~ "W-7 · page:7 · draft"
    assert out =~ "logo.png"
    assert out =~ "image/png"
  end

  test "a folder path is sent whole, and --page and --all are passed on" do
    {path, _} = run(["open", "handbook", "Design/Decisions"], [all: true], @rows)
    assert path =~ "folder=Design%2FDecisions"
    assert path =~ "archived=all"

    {path, _} = run(["open", "handbook"], [page: "W-7"], @rows)
    assert path =~ "page=W-7"
  end

  test "an empty level says so" do
    {_path, out} = run(["open", "handbook"], [], ~s({"node":"root","rows":[]}))
    assert out =~ "nothing here"
  end
end
