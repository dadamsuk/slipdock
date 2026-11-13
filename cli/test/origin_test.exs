defmodule SlipdockCLI.OriginTest do
  @moduledoc """
  Origin on cards (#2778) from the CLI: `slipdock card` shows it with the
  job, `cards --origin` filters by it, `add --origin` sends a generator's
  name, and the help says so.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-origin-#{System.unique_integer([:positive])}")
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
        "comments" => []
      },
      extra
    )
  end

  test "card shows the origin, with its job, and nothing on an older card" do
    out = capture_io(fn -> Render.card(card(%{"origin" => "agent", "origin_job_id" => 41})) end)
    assert out =~ ~r/Origin:\s+agent \(job #41\)/
    out = capture_io(fn -> Render.card(card(%{"origin" => "sweep", "origin_job_id" => nil})) end)
    assert out =~ ~r/Origin:\s+sweep\n/
    refute capture_io(fn -> Render.card(card(%{})) end) =~ "Origin"
  end

  test "cards --origin sends the filter" do
    serve([{200, ~s({"cards":[]})}])
    capture_io(fn -> Boards.run("cards", ["b"], origin: "sweep") end)
    assert_received {:request, "GET", path, _}
    assert path =~ "origin=sweep"
  end

  test "add --origin sends the generator's name" do
    serve([
      {201,
       ~s({"card":{"id":5,"title":"Fix","column":"Housekeeping","tags":[],"assignees":[],"flags":[],"blocked_by":[],"blocks":[],"comments":[],"checklist":{"done":0,"total":0}}})}
    ])

    capture_io(fn -> Boards.run("add", ["b", "Fix"], origin: "sweep") end)
    assert_received {:request, "POST", "/api/boards/b/cards", body}
    assert JSON.decode!(body)["origin"] == "sweep"
  end

  test "the help gives both" do
    help = File.read!(Path.expand("../help.txt", __DIR__))
    assert help =~ "--origin person|sweep|findings"
    assert help =~ "--origin sweep|findings"
  end
end
