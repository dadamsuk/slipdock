defmodule SlipdockCLI.MultiboardTest do
  @moduledoc """
  `slipdock multiboard` (#1479): asks `GET /api/multiboard` with the lists,
  top N and layout given, prints each section and its cards, and hands the
  answer on untouched with `--json`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-mb-#{System.unique_integer([:positive])}")
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

  defp card(id, title, board, column),
    do: %{"id" => id, "title" => title, "board" => board, "column" => column}

  # What the server answers (`SlipdockWeb.API.MultiboardController.index/2`).
  defp answer(by, sections), do: %{"top" => 5, "by" => by, "lists" => [], "sections" => sections}

  test "by board: a heading per board, each card naming its list" do
    serve(
      JSON.encode!(
        answer("board", [
          %{
            "key" => "board-1",
            "label" => "Ops",
            "cards" => [
              card(3, "Fix the pager", "ops", "To Do"),
              card(4, "Deploy", "ops", "Doing")
            ]
          },
          %{"key" => "board-2", "label" => "Web", "cards" => []}
        ])
      )
    )

    out = capture_io(fn -> Boards.run("multiboard", [], []) end)

    assert_received {:request, "GET", "/api/multiboard", _}
    assert out =~ ~r/Ops \(2\)\n  #3 Fix the pager  To Do\n  #4 Deploy  Doing/
    assert out =~ ~r/Web \(0\)\n  no cards/
  end

  test "--list repeats, and --limit and --by are passed on" do
    serve(
      JSON.encode!(
        answer("list", [
          %{
            "key" => "list-9",
            "label" => "Ops › To Do",
            "cards" => [card(3, "Fix", "ops", "To Do")]
          }
        ])
      )
    )

    out =
      capture_io(fn ->
        Boards.run("multiboard", [], list: "9", list: "web/To Do", limit: 3, by: "list")
      end)

    assert_received {:request, "GET", path, _}
    query = path |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query == %{"lists" => "9,web/To Do", "top" => "3", "by" => "list"}
    assert out =~ "Ops › To Do (1)\n  #3 Fix\n"
  end

  test "grid: no headings, each card says board › list" do
    serve(
      JSON.encode!(
        answer("grid", [
          %{"key" => "grid", "label" => nil, "cards" => [card(3, "Fix", "ops", "To Do")]}
        ])
      )
    )

    out = capture_io(fn -> Boards.run("multiboard", [], by: "grid") end)
    assert out =~ "  #3 Fix  ops › To Do"
    refute out =~ "(1)"
  end

  test "nothing chosen says how to choose" do
    serve(JSON.encode!(answer("board", [])))
    out = capture_io(fn -> Boards.run("multiboard", [], []) end)
    assert out =~ "no lists chosen"
  end

  test "--json hands the answer on untouched" do
    body = answer("board", [%{"key" => "board-1", "label" => "Ops", "cards" => []}])
    serve(JSON.encode!(body))
    out = capture_io(fn -> Boards.run("multiboard", [], json: true) end)
    assert JSON.decode!(out) == body
  end
end
