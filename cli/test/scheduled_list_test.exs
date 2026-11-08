defmodule SlipdockCLI.ScheduledListTest do
  @moduledoc """
  The Scheduled list (#2100) from the CLI: `new-column` and `set-column`
  send the `scheduled` category, `board` marks the list as one nobody picks
  from, and the help says what the category is.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-sched-#{System.unique_integer([:positive])}")
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

  @column ~s({"column":{"id":9,"name":"Scheduled","category":"scheduled"}})

  test "new-column --category scheduled sends it" do
    serve([{201, @column}])

    out =
      capture_io(fn -> Boards.run("new-column", ["b", "Scheduled"], category: "scheduled") end)

    assert_received {:request, "POST", "/api/boards/b/columns", body}
    assert JSON.decode!(body) == %{"name" => "Scheduled", "category" => "scheduled"}
    assert out =~ "Scheduled"
  end

  test "set-column --category scheduled sends it, and says so" do
    serve([{200, ~s({"columns":[{"id":9,"name":"Scheduled"}]})}, {200, @column}])

    out =
      capture_io(fn -> Boards.run("set-column", ["b", "Scheduled"], category: "scheduled") end)

    assert_received {:request, "PATCH", "/api/boards/b/columns/9", body}
    assert JSON.decode!(body) == %{"category" => "scheduled"}
    assert out =~ "updated column #9: Scheduled [scheduled]"
  end

  test "board marks the Scheduled and Triage lists as ones nobody picks from" do
    board = %{
      "id" => 3,
      "name" => "Agents",
      "code" => "agents",
      "color" => "indigo",
      "tags" => [],
      "columns" => [
        %{"id" => 1, "name" => "To Do", "category" => "todo", "cards" => []},
        %{"id" => 2, "name" => "Scheduled", "category" => "scheduled", "cards" => []},
        %{"id" => 3, "name" => "Triage", "category" => "triage", "cards" => []}
      ]
    }

    out = capture_io(fn -> Render.board(board) end)
    [todo | _] = String.split(out, "\n") |> Enum.filter(&(&1 =~ "## To Do"))

    assert out =~ ~r/## Scheduled.*scheduled: worked by feed rules, never pick from it/
    assert out =~ ~r/## Triage.*triage: for a person, never pick from it/
    refute todo =~ "never pick"
  end

  test "the help gives the category and where a repeat lands" do
    help = File.read!(Path.expand("../help.txt", __DIR__))
    assert help =~ "dropped, triage (for a person), scheduled"
    assert help =~ "Scheduled list, else its ready list"
  end
end
