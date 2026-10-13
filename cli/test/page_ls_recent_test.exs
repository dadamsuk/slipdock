defmodule SlipdockCLI.PageLsRecentTest do
  @moduledoc "`slipdock page ls --recent`: the wiki tree's Recent view from a shell (#738)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-pagels-#{System.unique_integer([:positive])}")
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

  @pages ~s({"pages":[{"code":"W-2","title":"Newer","status":"published","updated_at":"2026-10-01T09:00:00Z"},{"code":"W-1","title":"Older","status":"published","updated_at":"2026-01-01T09:00:00Z"}]})

  defp run(opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @pages}]))
    out = capture_io(fn -> Wiki.run("page", ["ls", "slipdock"], opts) end)
    assert_received {:request, "GET", path, _}
    {path, out}
  end

  test "--recent asks for the newest edits first, and prints them in the order given" do
    {path, out} = run(recent: true)
    assert path =~ "/boards/slipdock/pages"
    assert path =~ "recent=true"
    assert :binary.match(out, "Newer") < :binary.match(out, "Older")
  end

  test "without it, nothing about recent is sent" do
    {path, _out} = run([])
    refute path =~ "recent"
  end
end
