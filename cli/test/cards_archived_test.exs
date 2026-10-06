defmodule SlipdockCLI.CardsArchivedTest do
  @moduledoc """
  `slipdock cards --archived` and `--all`: archived cards alone, or alongside
  the live ones, and neither by default.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-cards-#{System.unique_integer([:positive])}")
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
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"cards":[]})}]))
    capture_io(fn -> Boards.run("cards", ["b"], opts) end)
    assert_received {:request, "GET", path, _}
    path
  end

  test "neither flag asks for no archived cards" do
    refute path_for([]) =~ "archived"
  end

  test "--archived asks for them alone" do
    assert path_for(archived: true) =~ "archived=true"
  end

  test "--all asks for them alongside the rest" do
    assert path_for(all: true) =~ "archived=all"
  end
end
