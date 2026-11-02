defmodule SlipdockCLI.VerifiedWorkTest do
  @moduledoc """
  Verified work (#1620) on the CLI: the board switches `set-board` sends,
  `edit --bar`, and what `card` shows of a card's bar.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-verified-#{System.unique_integer([:positive])}")
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

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp parse(argv) do
    {opts, _args, []} = OptionParser.parse(argv, strict: SlipdockCLI.switches())
    opts
  end

  @board ~s({"board":{"id":3,"name":"Docs"}})
  @card ~s({"card":{"id":12,"title":"Work","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  test "set-board --bar-required and --no-bar-required send the switch" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--bar-required"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"bar_required" => true}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--no-bar-required"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"bar_required" => false}
  end

  test "edit --bar sends the card's bar" do
    serve([{200, @card}])
    capture_io(fn -> Boards.run("edit", ["12"], parse(["--bar", "Tests pass"])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"bar" => "Tests pass"}
  end

  defp card(extra) do
    Map.merge(
      %{
        "id" => 12,
        "title" => "Work",
        "board_id" => 3,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "urls" => [],
        "links" => [],
        "attachments" => []
      },
      extra
    )
  end

  test "card shows the bar and whether it has locked, and nothing without one" do
    out = capture_io(fn -> Render.card(card(%{"bar" => "Tests pass"})) end)
    assert out =~ "Bar"
    assert out =~ "not locked yet"
    assert out =~ "Tests pass"

    out =
      capture_io(fn ->
        Render.card(card(%{"bar" => "Tests pass", "bar_locked_at" => "2026-11-02T10:00:00Z"}))
      end)

    assert out =~ "locked"
    refute out =~ "not locked"

    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Bar"
  end
end
