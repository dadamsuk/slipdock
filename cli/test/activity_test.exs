defmodule SlipdockCLI.ActivityTest do
  @moduledoc "`slipdock activity`: the board's log, or with `--card` one card's."
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-activity-#{System.unique_integer([:positive])}")
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
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, ~s({"activity":[]})}]))
    capture_io(fn -> Boards.run("activity", ["b"], opts) end)
    assert_received {:request, "GET", path, _}
    path
  end

  test "without --card asks for the whole board" do
    path = path_for(limit: 5)
    assert path =~ "/boards/b/activity"
    assert path =~ "limit=5"
    refute path =~ "card="
  end

  test "--card asks for that card's entries" do
    assert path_for(card: "129") =~ "card=129"
  end

  # #3189: each line says who did it, as the web UI's Activity panel does.
  test "each line names who did it" do
    entries = [
      %{actor: %{kind: "person", name: "Ash Person"}, message: "moved “A” to To Do"},
      %{actor: %{kind: "agent", name: "dedev loop"}, message: "moved “B” to Done"},
      %{actor: %{kind: "automation", name: "Triage"}, message: "flagged “C”"},
      %{actor: %{kind: "automation", name: "Automation"}, message: "tagged “D”"},
      %{actor: %{kind: "email", name: "Ash Person"}, message: "added “E”"},
      %{actor: %{kind: :null, name: "Someone"}, message: "moved “F” to To Do"},
      %{message: "moved “G” to To Do"}
    ]

    body =
      %{activity: Enum.map(entries, &Map.put(&1, :at, "2026-11-14T18:28:05Z"))}
      |> :json.encode()
      |> IO.iodata_to_binary()

    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))
    out = capture_io(fn -> Boards.run("activity", ["b"], []) end)
    lines = out |> String.split("\n", trim: true) |> Enum.map(&strip_ansi/1)

    assert lines == [
             "2026-11-14 18:28  Ash Person moved “A” to To Do",
             "2026-11-14 18:28  dedev loop moved “B” to Done",
             "2026-11-14 18:28  Automation: Triage flagged “C”",
             "2026-11-14 18:28  Automation tagged “D”",
             "2026-11-14 18:28  Email from Ash Person added “E”",
             "2026-11-14 18:28  Someone moved “F” to To Do",
             # A server from before #3189 sends no actor: the message alone.
             "2026-11-14 18:28  moved “G” to To Do"
           ]
  end

  defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*m/, "")
end
