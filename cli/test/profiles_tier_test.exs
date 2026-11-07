defmodule SlipdockCLI.ProfilesTierTest do
  @moduledoc """
  The human tier (#1952) on the CLI: `set-board --profile-tier P=TIER`
  (repeatable, `default` putting one back) and its loud warning for
  security set to none, a held card in `slipdock card` and a list's line,
  and a held card's ledger line saying who it waits for.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Ledger, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-tiers-#{System.unique_integer([:positive])}")
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

  @card %{
    "id" => 12,
    "title" => "Migrate",
    "column" => "Doing",
    "board_id" => 3,
    "priority" => "none",
    "flags" => ["review", "waiting"],
    "tags" => [],
    "comments" => [],
    "checklist" => %{"done" => 0, "total" => 0, "items" => []},
    "verify_state" => "held",
    "verify_by" => %{"kind" => "agent", "agent" => "checker"}
  }

  test "set-board --profile-tier sends each, and default puts one back" do
    board = ~s({"board":{"id":3,"name":"Docs","profile_tiers":{"schema":"none"}}})
    serve([{200, board}])

    out =
      capture_io(fn ->
        Boards.run(
          "set-board",
          ["docs"],
          parse(["--profile-tier", "schema=none", "--profile-tier", "spike = default"])
        )
      end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"profile_tiers" => %{"schema" => "none", "spike" => "default"}}
    assert out =~ "updated board #3"
  end

  test "security set to none is said loudly, on stderr" do
    board = ~s({"board":{"id":3,"name":"Docs","profile_tiers":{"security":"none"}}})
    serve([{200, board}])

    err =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          Boards.run("set-board", ["docs"], parse(["--profile-tier", "security=none"]))
        end)
      end)

    assert err =~ "warning: security is set to none"

    assert capture_io(:stderr, fn -> Boards.tier_warning(%{"profile_tiers" => %{}}) end) == ""
  end

  test "no --profile-tier sends no tiers" do
    assert Boards.profile_tiers(parse(["--profiles", "on"])) == nil
  end

  test "a held card says a person decides, in card and in a list's line" do
    out = capture_io(fn -> Render.card(@card) end)
    assert out =~ "held — accepted by agent “checker”"
    assert out =~ "slipdock verify 12 accept"

    line = capture_io(fn -> IO.puts(Render.card_line(@card, false)) end)
    assert line =~ "held for a person"
  end

  test "a held card's ledger line says who it waits for, and nothing once merged" do
    line = %{
      "card" => %{"id" => 12, "title" => "Migrate", "profile" => "schema"},
      "events" => ["accepted"],
      "waiting_for" => "Pat"
    }

    assert hd(Ledger.lines(line)) == "#12 Migrate  [accepted]  profile:schema  waiting for Pat"
    assert hd(Ledger.lines(Map.put(line, "waiting_for", nil))) =~ ~r/profile:schema$/
  end
end
