defmodule SlipdockCLI.ListOrderTest do
  @moduledoc """
  `set-column` / `new-column` `--sort` and `--group`: how the web app draws a
  list. What they send, and how `columns` shows it back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-order-#{System.unique_integer([:positive])}")
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

  @columns ~s({"columns":[{"id":9,"name":"To Do"}]})
  @column ~s({"column":{"id":9,"name":"To Do"}})

  test "--sort with --descending sends the sort, desc, and the group" do
    serve([{200, @columns}, {200, @column}])

    capture_io(fn ->
      Boards.run("set-column", ["b", "To", "Do"],
        sort: "due_date",
        descending: true,
        group: "flag"
      )
    end)

    assert_received {:request, "GET", "/api/boards/b/columns", _}
    assert_received {:request, "PATCH", "/api/boards/b/columns/9", body}

    assert JSON.decode!(body) == %{
             "sort_by" => "due_date",
             "sort_dir" => "desc",
             "group_by" => "flag"
           }
  end

  test "--sort alone is ascending, and leaves the group alone" do
    serve([{200, @columns}, {200, @column}])

    capture_io(fn -> Boards.run("set-column", ["b", "To Do"], sort: "position") end)

    assert_received {:request, "PATCH", "/api/boards/b/columns/9", body}
    assert JSON.decode!(body) == %{"sort_by" => "position", "sort_dir" => "asc"}
  end

  test "--group alone sends no sort, so the list keeps the one it has" do
    serve([{200, @columns}, {200, @column}])

    capture_io(fn -> Boards.run("set-column", ["b", "To Do"], group: "none") end)

    assert_received {:request, "PATCH", "/api/boards/b/columns/9", body}
    assert JSON.decode!(body) == %{"group_by" => "none"}
  end

  test "new-column carries them too" do
    serve([{201, @column}])

    capture_io(fn -> Boards.run("new-column", ["b", "Later"], sort: "priority", group: "tag") end)

    assert_received {:request, "POST", "/api/boards/b/columns", body}

    assert JSON.decode!(body) == %{
             "name" => "Later",
             "sort_by" => "priority",
             "sort_dir" => "asc",
             "group_by" => "tag"
           }
  end

  test "columns shows each list's order, and - for board order" do
    out =
      capture_io(fn ->
        Render.columns([
          %{"id" => 1, "name" => "A", "cards" => 2},
          %{
            "id" => 2,
            "name" => "B",
            "cards" => 0,
            "sort_by" => "due_date",
            "sort_dir" => "desc"
          },
          %{"id" => 3, "name" => "C", "cards" => 0, "sort_by" => "created", "group_by" => "tag"},
          %{"id" => 4, "name" => "D", "cards" => 0, "group_by" => "flag"}
        ])
      end)

    assert out =~ "ORDER"
    assert out =~ "due_date desc"
    assert out =~ "created, by tag"
    assert out =~ ~r/D\s+0\s+-\s+-\s+by flag/
    assert Render.list_order(%{"name" => "A"}) == "-"
  end
end
