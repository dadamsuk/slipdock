defmodule SlipdockCLI.ProfilesTest do
  @moduledoc """
  Profiles 1 (#1951) on the CLI: `set-board --profiles on|off`, `add` and
  `edit --profile` (and `--no-profile`), and the profile shown by `card`
  and in a list's card line.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-profiles-#{System.unique_integer([:positive])}")
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

  test "set-board --profiles on sends true, off sends false" do
    serve([{200, @board}, {200, @board}])

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--profiles", "on"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"profiles" => true}

    capture_io(fn -> Boards.run("set-board", ["docs"], parse(["--profiles", "OFF"])) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"profiles" => false}
  end

  # A bad value fails before anything is sent, through `fail/1`'s
  # `System.halt/1`, so its parse is tested here rather than the halt.
  test "--profiles takes on or off in any case, and nothing else" do
    assert Boards.on_off("on") == true
    assert Boards.on_off(" On ") == true
    assert Boards.on_off("off") == false
    assert Boards.on_off("maybe") == :error
    assert Boards.on_off("") == :error
  end

  test "add --profile sends it with the card" do
    serve([{201, @card}])
    capture_io(fn -> Boards.run("add", ["docs", "Work"], parse(["--profile", "docs"])) end)
    assert_received {:request, "POST", "/api/boards/docs/cards", body}
    assert JSON.decode!(body)["profile"] == "docs"
  end

  test "edit --profile sets it, and --no-profile clears it" do
    serve([{200, @card}, {200, @card}])

    capture_io(fn -> Boards.run("edit", ["12"], parse(["--profile", "schema"])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"profile" => "schema"}

    capture_io(fn -> Boards.run("edit", ["12"], parse(["--no-profile"])) end)
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"profile" => ""}
  end

  test "card shows the profile, and nothing without one" do
    base = JSON.decode!(@card)["card"]
    out = capture_io(fn -> Render.card(Map.put(base, "profile", "security")) end)
    assert out =~ ~r/Profile:\s+security/
    refute capture_io(fn -> Render.card(base) end) =~ "Profile"
  end

  test "a list's card line shows the profile as one word" do
    base = JSON.decode!(@card)["card"]
    line = capture_io(fn -> IO.puts(Render.card_line(Map.put(base, "profile", "fix"), false)) end)
    assert line =~ "profile:fix"
    refute capture_io(fn -> IO.puts(Render.card_line(base, false)) end) =~ "profile:"
  end

  test "a ledger line shows the profile as one word, and nothing without one" do
    line = %{
      "card" => %{"id" => 7, "title" => "Move", "profile" => "schema"},
      "events" => ["merged"]
    }

    assert hd(SlipdockCLI.Ledger.lines(line)) == "#7 Move  [merged]  profile:schema"

    plain = put_in(line, ["card", "profile"], nil)
    assert hd(SlipdockCLI.Ledger.lines(plain)) == "#7 Move  [merged]"
  end
end
