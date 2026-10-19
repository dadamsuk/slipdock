defmodule SlipdockCLI.WorkTest do
  @moduledoc """
  `slipdock work` (#1118): asks `GET /api/work`, prints "Waiting on you"
  first in the server's order with why, how long and a wait's numbered
  choices, then the assigned cards by section; `--json` hands the answer on
  untouched. `whoami` says how many things are waiting.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Auth, Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-work-#{System.unique_integer([:positive])}")
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

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  # What the server answers (`SlipdockWeb.API.WorkController.index/2`).
  defp work do
    %{
      "waiting_count" => 2,
      "waiting" => [
        %{
          "reason" => "needs_owner",
          "text" => "In progress with nobody on it",
          "since" => ago(3 * 3600),
          "card" => %{"id" => 31, "title" => "Stuck one", "column" => "Doing", "flags" => []},
          "path" => ["Ops"],
          "wait" => nil,
          "job" => nil
        },
        %{
          "reason" => "wait",
          "text" => "Waiting on you: Which region?",
          "since" => ago(41 * 60),
          "card" => %{"id" => 7, "title" => "Deploy", "column" => "To Do", "flags" => ["waiting"]},
          "path" => ["Ops", "Release"],
          "wait" => %{"id" => 1, "needs" => "Which region?", "choices" => ["eu", "us"]},
          "job" => nil
        }
      ],
      "sections" => [
        %{
          "key" => "today",
          "label" => "Due today",
          "cards" => [
            %{
              "id" => 9,
              "title" => "Write notes",
              "column" => "To Do",
              "path" => ["Ops"],
              "due_date" => "2026-10-19"
            }
          ]
        }
      ]
    }
  end

  test "prints what is waiting on you first, in the server's order, then the sections" do
    serve(JSON.encode!(work()))

    out = capture_io(fn -> Boards.run("work", [], []) end)

    assert_received {:request, "GET", "/api/work", _}
    assert out =~ "Waiting on you (2)"
    assert out =~ ~r/#31 Stuck one  3h\n      In progress with nobody on it\n      Ops · Doing/
    assert out =~ ~r/#7 Deploy  41m\n      Waiting on you: Which region\?  \[1\] eu  \[2\] us/
    assert out =~ "Ops › Release · To Do"
    assert out =~ "Due today (1)\n  #9 Write notes  due 2026-10-19  Ops · To Do"

    {stuck, _} = :binary.match(out, "#31")
    {deploy, _} = :binary.match(out, "#7 ")
    {notes, _} = :binary.match(out, "#9 ")
    assert stuck < deploy and deploy < notes
  end

  test "--board and --done are passed on" do
    serve(JSON.encode!(%{work() | "waiting" => [], "waiting_count" => 0}))

    out = capture_io(fn -> Boards.run("work", [], board: "ops", done: true) end)

    assert_received {:request, "GET", path, _}
    assert path =~ "/api/work?"
    assert path =~ "board=ops"
    assert path =~ "done=true"
    refute out =~ "Waiting on you"
  end

  test "nothing at all says so" do
    serve(JSON.encode!(%{"waiting" => [], "waiting_count" => 0, "sections" => []}))
    out = capture_io(fn -> Boards.run("work", [], []) end)
    assert out =~ "nothing waiting on you, nothing assigned"
  end

  test "--json hands the answer on untouched" do
    answer = work()
    serve(JSON.encode!(answer))
    out = capture_io(fn -> Boards.run("work", [], json: true) end)
    assert JSON.decode!(out) == answer
  end

  describe "whoami" do
    @me %{
      "user" => %{"email" => "da@example.com", "name" => "David"},
      "limits" => nil
    }

    test "says how many things are waiting" do
      serve(JSON.encode!(Map.put(@me, "waiting_on_you", 3)))
      out = capture_io(fn -> Auth.run("whoami", [], []) end)
      assert out =~ "waiting on you: 3 (slipdock work)"
    end

    test "says nothing about it when nothing is" do
      serve(JSON.encode!(Map.put(@me, "waiting_on_you", 0)))
      out = capture_io(fn -> Auth.run("whoami", [], []) end)
      refute out =~ "waiting on you"
    end
  end
end
