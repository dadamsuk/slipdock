defmodule SlipdockCLI.LanesTest do
  @moduledoc """
  Lanes (#1628) on the CLI: `set-board --[no-]lanes`, `edit --paths`, and
  the paths `card` shows. The refusal itself is the server's
  (`Slipdock.LanesTest`); here a refused move's message reaches the user.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-lanes-#{System.unique_integer([:positive])}")
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

  test "set-board --lanes and --no-lanes send the switch" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--lanes"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"lanes" => true}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--no-lanes"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"lanes" => false}
  end

  test "edit --paths sends the globs as written, and \"\" to clear them" do
    serve([{200, @card}, {200, @card}])

    capture_io(fn ->
      Boards.run("edit", ["12"], parse(["--paths", "lib/runners/**,docs/{a,b}.md"]))
    end)

    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"paths" => "lib/runners/**,docs/{a,b}.md"}

    capture_io(fn -> Boards.run("edit", ["12"], parse(["--paths", ""])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"paths" => ""}
  end

  test "card shows the paths, one per line, and nothing when there are none" do
    card = %{
      "id" => 12,
      "title" => "Work",
      "column" => "To Do",
      "board_id" => 3,
      "priority" => "none",
      "flags" => [],
      "tags" => [],
      "comments" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []}
    }

    out =
      capture_io(fn -> Render.card(Map.put(card, "paths", ["lib/a/**", "test/a_test.exs"])) end)

    assert out =~ ~r/Paths\n\s+lib\/a\/\*\*\n\s+test\/a_test.exs/
    refute capture_io(fn -> Render.card(card) end) =~ "Paths"
  end

  test "set-board --shared-paths sends the globs as written, and \"\" to clear them (#1971)" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn ->
      Boards.run("set-board", ["docs"], parse(["--shared-paths", "docs/**,README.md"]))
    end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"shared_paths" => "docs/**,README.md"}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--shared-paths", ""])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"shared_paths" => ""}
  end

  test "card marks the paths shared on the board; board lists its shared paths (#1971)" do
    card =
      @card
      |> JSON.decode!()
      |> Map.fetch!("card")
      |> Map.merge(%{
        "paths" => ["lib/a/**", "docs/manual.md"],
        "shared_paths" => ["docs/**"],
        "paths_shared" => ["docs/manual.md"]
      })

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Paths\n\s+lib\/a\/\*\*\n\s+docs\/manual.md.*shared/
    refute out =~ ~r/lib\/a\/\*\*.*shared/

    board = %{"id" => 3, "name" => "Docs", "color" => "blue", "tags" => [], "columns" => []}

    assert capture_io(fn ->
             Render.board(Map.put(board, "shared_paths", ["docs/**", "README.md"]))
           end) =~
             "shared paths (hold no lane): docs/**, README.md"

    refute capture_io(fn -> Render.board(Map.put(board, "shared_paths", [])) end) =~
             "shared paths"
  end

  test "set-board --lane-mode sends the mode (#1972)" do
    serve([{200, @board}])
    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--lane-mode", "advise"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"lane_mode" => "advise"}
  end

  test "card says what its overlap does; board says when lanes advise (#1972)" do
    card =
      @card
      |> JSON.decode!()
      |> Map.fetch!("card")
      |> Map.put("paths", ["lib/a/**"])

    advised =
      Map.put(card, "lane_overlap", %{"card" => 9, "title" => "Other", "mode" => "advise"})

    held = Map.put(card, "lane_overlap", %{"card" => 9, "title" => "Other", "mode" => "hold"})

    assert capture_io(fn -> Render.card(advised) end) =~
             "overlaps #9 “Other” in progress, advisory: an agent may start"

    assert capture_io(fn -> Render.card(held) end) =~
             "overlaps #9 “Other” in progress: an agent can't start this"

    refute capture_io(fn -> Render.card(card) end) =~ "overlaps #"

    board = %{"id" => 3, "name" => "Docs", "color" => "blue", "tags" => [], "columns" => []}

    assert capture_io(fn -> Render.board(Map.put(board, "lane_mode", "advise")) end) =~
             "lanes: advise (overlaps are told, not held)"

    refute capture_io(fn -> Render.board(Map.put(board, "lane_mode", "hold")) end) =~ "advise"
  end
end
