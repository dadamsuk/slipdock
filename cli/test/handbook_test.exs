defmodule SlipdockCLI.HandbookTest do
  @moduledoc """
  The handbook in the CLI (#1265): `slipdock card` shows a card's suggested
  sections with the command that reads each, and `slipdock handbook` prints
  a board's index or a card's reading.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  @handbook %{
    "board" => "proj",
    "index_page" => "W-1",
    "more" => 0,
    "index" => [
      %{
        "code" => "W-4",
        "title" => "UX & UI",
        "summary" => "Patterns",
        "read_when" => "building a screen"
      }
    ],
    "suggested" => [
      %{
        "page" => "W-4",
        "title" => "UX & UI",
        "section" => "UX & UI/Patterns",
        "why" => "shares words"
      },
      %{"page" => "W-2", "title" => "Architecture", "section" => nil, "why" => "covers lib/a.ex"}
    ]
  }

  @card %{
    "id" => 7,
    "title" => "Build the menu",
    "column" => "To Do",
    "priority" => "none",
    "flags" => [],
    "tags" => [],
    "checklist" => %{"done" => 0, "total" => 0},
    "comments" => []
  }

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-hb-#{System.unique_integer([:positive])}")
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

  defp serve(body), do: System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))

  test "slipdock card shows the suggested sections and how to read each" do
    out = capture_io(fn -> Render.card(Map.put(@card, "handbook", @handbook)) end)

    assert out =~ "Handbook"
    assert out =~ "close with a Handbook: line"
    assert out =~ "W-4 UX & UI §Patterns"
    assert out =~ ~s(slipdock page section W-4 "UX & UI/Patterns")
    assert out =~ "W-2 Architecture"
    assert out =~ "covers lib/a.ex · slipdock page read W-2"
    assert out =~ "index: slipdock handbook proj (W-1)"
  end

  test "a card with no handbook shows no block" do
    refute capture_io(fn -> Render.card(@card) end) =~ "Handbook"
  end

  test "slipdock handbook <card> asks for the card and prints its reading" do
    serve(JSON.encode!(%{"card" => Map.put(@card, "handbook", @handbook)}))
    out = capture_io(fn -> Boards.run("handbook", ["#7"], []) end)

    assert_received {:request, "GET", "/api/cards/7", _}
    assert out =~ "#7 Build the menu"
    assert out =~ "W-4 UX & UI §Patterns"
  end

  test "slipdock handbook <card> on a board without one says how to install it" do
    serve(JSON.encode!(%{"card" => @card}))
    out = capture_io(fn -> Boards.run("handbook", ["7"], []) end)
    assert out =~ "keeps no handbook"
    assert out =~ "install-board handbook"
  end

  test "slipdock handbook <board> prints the index and decisions" do
    body =
      Map.merge(@handbook, %{
        "more" => 3,
        "decisions" => [%{"code" => "W-9", "title" => "Decision: soft gate"}]
      })

    serve(JSON.encode!(%{"board" => %{"code" => "proj"}, "handbook" => body}))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], []) end)

    assert_received {:request, "GET", "/api/boards/proj/handbook", _}
    assert out =~ "W-4 UX & UI — Patterns"
    assert out =~ "read when: building a screen"
    assert out =~ "and 3 more pages"
    assert out =~ "W-9 Decision: soft gate"
  end

  test "slipdock handbook <board> without one says so" do
    serve(JSON.encode!(%{"board" => %{"code" => "proj"}, "handbook" => nil}))
    out = capture_io(fn -> Boards.run("handbook", ["proj"], []) end)
    assert out =~ "proj keeps no handbook"
  end
end
