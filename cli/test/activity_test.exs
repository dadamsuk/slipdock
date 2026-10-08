defmodule SlipdockCLI.ActivityTest do
  @moduledoc "`slipdock activity`: the board's log, or with `--card` one card's."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-activity-#{System.unique_integer([:positive])}")
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

  defp path_for(opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"activity":[]})}]))
    capture_io(fn -> Boards.run("activity", ["b"], opts) end)
    assert_received {:request, "GET", path, _}
    path
  end

  test "without --card asks for the whole board" do
    path = path_for(limit: 5)
    assert path =~ "/boards/b/activity"
    assert path =~ "limit=5"
    refute path =~ "card="
  end

  test "--card asks for that card's entries" do
    assert path_for(card: "129") =~ "card=129"
  end
end
