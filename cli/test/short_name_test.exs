defmodule SlipdockCLI.ShortNameTest do
  @moduledoc "`--short-name` on add and edit (#1590)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-short-#{System.unique_integer([:positive])}")
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

  @card ~s({"card":{"id":9,"title":"Long","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  defp run(command, args, opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @card}]))
    capture_io(fn -> Boards.run(command, args, opts) end)
    assert_received {:request, _method, _path, body}
    JSON.decode!(body)
  end

  test "add sends it" do
    assert run("add", ["3", "Long"], short_name: "Mine")["short_name"] == "Mine"
  end

  test "edit sends it" do
    assert run("edit", ["9"], short_name: "Mine")["short_name"] == "Mine"
  end

  test "an empty one is sent, to hand it back" do
    assert run("edit", ["9"], short_name: "")["short_name"] == ""
  end

  test "left out, it isn't sent" do
    refute Map.has_key?(run("edit", ["9"], title: "Long"), "short_name")
  end
end
