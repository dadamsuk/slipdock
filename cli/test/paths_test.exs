defmodule SlipdockCLI.PathsTest do
  @moduledoc """
  Card paths (#1628) on the CLI: `edit --paths` and the paths `card` shows.
  The lanes that held overlapping paths apart went in #3178, and with them
  `set-board --lanes`, `--lane-mode` and `--shared-paths`.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-paths-#{System.unique_integer([:positive])}")
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

  @card ~s({"card":{"id":12,"title":"Work","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

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

  test "set-board has no lane flags any more (#3178)" do
    for flag <- ~w(--lanes --no-lanes --lane-mode --shared-paths) do
      {_opts, _args, invalid} =
        OptionParser.parse([flag, "x"], strict: SlipdockCLI.switches())

      assert invalid != [], flag
    end
  end

  test "card shows its paths plainly: no shared, broad or overlap lines (#3178)" do
    card = %{
      "id" => 12,
      "title" => "Work",
      "column" => "In Progress",
      "board_id" => 3,
      "priority" => "none",
      "flags" => [],
      "tags" => [],
      "comments" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "paths" => ["docs/**", "lib/a.ex"],
      "paths_broad" => ["docs/**"],
      "lane_overlap" => %{"card" => 7, "title" => "Other", "mode" => "hold"}
    }

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ ~r/Paths\n\s+docs\/\*\*\n\s+lib\/a.ex/
    refute out =~ "broad"
    refute out =~ "overlaps"
  end
end
