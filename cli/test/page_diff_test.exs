defmodule SlipdockCLI.PageDiffTest do
  @moduledoc "`slipdock page diff`: one save's change, or two versions compared."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-pagediff-#{System.unique_integer([:positive])}")
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

  @diff ~s({"revision":{"id":12,"body":"new"},"diff":[{"op":"del","lines":["old"]},{"op":"ins","lines":["new"]}]})

  defp run(opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @diff}]))
    out = capture_io(fn -> Wiki.run("page", ["diff", "W-31"], opts) end)
    assert_received {:request, "GET", path, _}
    {path, out}
  end

  test "without --against diffs a version from the one before it" do
    {path, out} = run(rev: "12")
    assert path =~ "/pages/W-31/revisions/12"
    assert path =~ "diff=previous"
    assert out =~ "- old"
    assert out =~ "+ new"
  end

  test "--against compares with that version instead" do
    {path, _out} = run(rev: "12", against: "7")
    assert path =~ "/pages/W-31/revisions/12"
    assert path =~ "diff=7"
    refute path =~ "previous"
  end
end
