defmodule SlipdockCLI.PageNoteTagsTest do
  @moduledoc "`slipdock page tags` and `page ls --note-tag`."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-notetags-#{System.unique_integer([:positive])}")
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
    out = capture_io(fn -> Wiki.run("page", args, opts) end)
    assert_received {:request, "GET", path, _}
    {path, out}
  end

  test "page tags lists each tag with its count" do
    {path, out} =
      run(
        ["tags", "brain"],
        [],
        ~s({"tags":[{"tag":"area","count":2},{"tag":"area/sub","count":1}]})
      )

    assert path =~ "/boards/brain/pages/tags"
    assert out =~ ~r/#area\s+2/
    assert out =~ ~r/#area\/sub\s+1/
  end

  test "page tags with none says where they come from" do
    {_path, out} = run(["tags", "brain"], [], ~s({"tags":[]}))
    assert out =~ "in a vault"
  end

  test "page ls --note-tag sends the filter" do
    {path, _out} = run(["ls", "brain"], [note_tag: "area/sub"], ~s({"pages":[]}))
    assert path =~ "note_tag=area%2Fsub"
  end
end
