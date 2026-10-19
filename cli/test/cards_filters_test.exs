defmodule SlipdockCLI.CardsFiltersTest do
  @moduledoc """
  `slipdock cards --stuck --driver agent` (#1117): the filters reach the
  server, and each card's line shows its state, who drives it and how long
  it has sat in its list — with nothing added for a card that has none.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-filters-#{System.unique_integer([:positive])}")
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

  @card %{
    "id" => 7,
    "title" => "Build",
    "column" => "In Progress",
    "priority" => "none",
    "flags" => [],
    "tags" => [],
    "checklist" => %{"done" => 0, "total" => 0},
    "comments" => []
  }

  defp run(opts, body \\ ~s({"cards":[]})) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))
    out = capture_io(fn -> Boards.run("cards", ["b"], opts) end)
    assert_received {:request, "GET", path, _}
    {path, out}
  end

  test "--stuck and --driver go to the server" do
    {path, _} = run(stuck: true, driver: "agent")
    assert path =~ "stuck=true"
    assert path =~ "driver=agent"
  end

  test "neither flag asks for neither" do
    {path, _} = run([])
    refute path =~ "stuck"
    refute path =~ "driver"
  end

  test "a stuck card's line: its state, driver and how far over usual" do
    card =
      Map.merge(@card, %{
        "state" => "Running · runner-2 · 7m",
        "driver" => "agent",
        "age" => 3 * 3600 + 30,
        "over_usual" => 3600,
        "stuck" => true
      })

    {_, out} = run([stuck: true], JSON.encode!(%{"cards" => [card]}))
    assert out =~ "#7"
    assert out =~ "🤖agent"
    assert out =~ "⏳3h (1h over usual, stuck)"
    assert out =~ "▸ Running · runner-2 · 7m"
  end

  test "a card with no state shows its age alone" do
    line = Render.card_line(Map.put(@card, "age", 120), true)
    assert line =~ "⏳2m"
    refute line =~ "▸"
    refute line =~ "agent"
    refute Render.card_line(@card, true) =~ "⏳"
  end

  test "slipdock card shows the state, driver and time in list" do
    card =
      Map.merge(@card, %{
        "board_id" => 1,
        "column_id" => 2,
        "position" => 0,
        "state" => "Waiting on Dana · 41m",
        "driver" => "human",
        "age" => 86_400 * 2,
        "blocked_by" => [],
        "blocks" => []
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ "Waiting on Dana · 41m"
    assert out =~ "human"
    assert out =~ "⏳2d"
  end
end
