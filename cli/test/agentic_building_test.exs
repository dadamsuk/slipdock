defmodule SlipdockCLI.AgenticBuildingTest do
  @moduledoc """
  Agentic Building (#2011) on the CLI: `set-board --agentic-building on|off`
  sends the switch, and the warning the server gives when rules still hold
  is printed. A word that is neither ends in `System.halt/1` (`on_off!`, as
  `--profiles`), so it is not run here.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-agentic-#{System.unique_integer([:positive])}")
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

  test "on and off send the switch as a boolean" do
    serve([{200, @board}, {200, @board}])

    out =
      capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--agentic-building", "on"])) end)

    assert out =~ "updated board #3"
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"agentic_building" => true}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--agentic-building", "off"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"agentic_building" => false}
  end

  test "the server's warning about rules still holding goes to stderr" do
    serve([
      {200,
       ~s({"board":{"id":3,"name":"Docs"},"warnings":["Agentic Building is off, but these still hold: Lanes."]})}
    ])

    err =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          Boards.run("set-board", ["docs"], parse(["--agentic-building", "off"]))
        end)
      end)

    assert err =~ "warning: Agentic Building is off, but these still hold: Lanes."
  end

  test "the help names the flag" do
    assert File.read!(Path.expand("../help.txt", __DIR__)) =~ "[--agentic-building on|off]"
  end
end
