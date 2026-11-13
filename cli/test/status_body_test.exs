defmodule SlipdockCLI.StatusBodyTest do
  @moduledoc """
  A status note keeps its lines (#2700): `status` takes the note as words,
  which are joined into one line, or `--body`, `--file` or `--body -`
  (stdin), which arrive as written, as `comment` does. The help says so.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-status-#{System.unique_integer([:positive])}")
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

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @reported ~s({"card":{"id":7,"title":"Ship it","column":"Doing","priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0}}})
  @note "At risk: the export is slow.\n\n- 40 s on the big board\n- no index on `archived_at`\n"

  defp posted(path \\ "/api/cards/7/status") do
    assert_received {:request, "POST", ^path, body}
    JSON.decode!(body)
  end

  test "words are joined into one line, as before" do
    serve([{201, @reported}])
    out = capture_io(fn -> Boards.run("status", ["7", "at_risk", "stalled", "on", "SRE"], []) end)
    assert posted() == %{"health" => "at_risk", "body" => "stalled on SRE"}
    assert out =~ "reported at_risk on #7"
    assert out =~ "Ship it"
  end

  test "no note at all sends an empty one" do
    serve([{201, @reported}])
    capture_io(fn -> Boards.run("status", ["7", "on_track"], []) end)
    assert posted() == %{"health" => "on_track", "body" => ""}
  end

  test "--body - reads the note from stdin, line breaks and all" do
    serve([{201, @reported}])

    out =
      capture_io([input: @note], fn -> Boards.run("status", ["7", "at_risk"], body: "-") end)

    assert posted() == %{"health" => "at_risk", "body" => @note}
    assert out =~ "reported at_risk on"
  end

  test "--body TEXT keeps the line breaks" do
    serve([{201, @reported}])
    capture_io(fn -> Boards.run("status", ["7", "off_track"], body: @note) end)
    assert posted() == %{"health" => "off_track", "body" => @note}
  end

  test "--file reads the note from a file", %{home: home} do
    path = Path.join(home, "note.md")
    File.write!(path, @note)
    serve([{201, @reported}])
    capture_io(fn -> Boards.run("status", ["7", "at_risk"], file: path) end)
    assert posted() == %{"health" => "at_risk", "body" => @note}
  end

  test "--file - reads stdin too" do
    serve([{201, @reported}])
    capture_io([input: @note], fn -> Boards.run("status", ["7", "at_risk"], file: "-") end)
    assert posted()["body"] == @note
  end

  test "empty stdin sends an empty note" do
    serve([{201, @reported}])
    capture_io([input: ""], fn -> Boards.run("status", ["7", "at_risk"], body: "-") end)
    assert posted()["body"] == ""
  end

  test "words win over --body when both are given, as a comment's do" do
    serve([{201, @reported}])
    capture_io(fn -> Boards.run("status", ["7", "at_risk", "short"], body: "long\nnote") end)
    assert posted()["body"] == "short"
  end

  test "a page takes a note of several lines too" do
    serve([
      {201, ~s({"page":{"code":"W-31","title":"Runbook","url":"https://example.com/w/31"}})}
    ])

    out =
      capture_io([input: @note], fn -> Boards.run("status", ["W-31", "at_risk"], body: "-") end)

    assert posted("/api/pages/W-31/status") == %{"health" => "at_risk", "body" => @note}
    assert out =~ "reported at_risk on W-31 Runbook"
  end

  test "through the command line: --body - parses and the piped note arrives intact" do
    serve([{201, @reported}])

    capture_io([input: @note], fn ->
      SlipdockCLI.main(["status", "7", "at_risk", "--body", "-"])
    end)

    assert posted() == %{"health" => "at_risk", "body" => @note}
  end

  describe "the help" do
    @help File.read!(Path.expand("../help.txt", __DIR__))

    defp status_entry do
      [_, rest] = String.split(@help, "\n  status <id> <on_track|at_risk|off_track>", parts: 2)
      [entry, _] = String.split(rest, "\n  handoff <id>", parts: 2)
      entry |> String.split() |> Enum.join(" ")
    end

    test "status's entry gives --body -, --body TEXT and --file F" do
      entry = status_entry()
      assert entry =~ "--body - with a heredoc keeps the line breaks"
      assert entry =~ "--body TEXT"
      assert entry =~ "--file F"
    end

    test "and no longer sends a note of several lines to MCP" do
      refute status_entry() =~ "status_update"
      refute status_entry() =~ "MCP"
    end
  end
end
