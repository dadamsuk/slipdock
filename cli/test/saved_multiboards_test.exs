defmodule SlipdockCLI.SavedMultiboardsTest do
  @moduledoc """
  Saved multiboards from the command line (#1482): `multiboards`,
  `multiboard <saved>`, `save-multiboard`, `set-multiboard` and
  `delete-multiboard`, each against `/api/multiboards`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-smb-#{System.unique_integer([:positive])}")
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

  defp serve(status \\ 200, body),
    do: System.put_env("SLIPDOCK_URL", FakeServer.start([{status, JSON.encode!(body)}]))

  defp mb(id, name, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "color" => "rose",
        "lists" => [1, 2],
        "top" => 5,
        "by" => "board"
      },
      extra
    )
  end

  test "multiboards lists each on one line" do
    serve(%{"multiboards" => [mb(4, "Queue"), mb(5, "Solo", %{"lists" => [9], "by" => "grid"})]})
    out = capture_io(fn -> Boards.run("multiboards", [], []) end)

    assert_received {:request, "GET", "/api/multiboards", _}
    assert out =~ ~r/#4 .*Queue.*rose · 2 lists · top 5 by board/
    assert out =~ ~r/#5 .*Solo.*1 list · top 5 by grid/
  end

  test "multiboards with none says how to save one" do
    serve(%{"multiboards" => []})
    assert capture_io(fn -> Boards.run("multiboards", [], []) end) =~ "no saved multiboards"
  end

  test "multiboard <saved> shows it by name, with its cards" do
    serve(%{
      "multiboard" => mb(4, "Queue"),
      "top" => 5,
      "by" => "board",
      "lists" => [],
      "sections" => [
        %{
          "key" => "board-1",
          "label" => "Ops",
          "cards" => [%{"id" => 3, "title" => "Fix", "column" => "To Do"}]
        }
      ]
    })

    out = capture_io(fn -> Boards.run("multiboard", ["My Queue"], []) end)
    assert_received {:request, "GET", "/api/multiboards/My%20Queue", _}
    assert out =~ ~r/Queue.*#4 · rose/
    assert out =~ "#3 Fix  To Do"
  end

  test "save-multiboard sends the name, lists, top, layout and colour" do
    serve(201, %{"multiboard" => mb(7, "Ops queue")})

    out =
      capture_io(fn ->
        Boards.run("save-multiboard", ["Ops", "queue"],
          list: "9",
          list: "web/To Do",
          limit: 3,
          by: "list",
          color: "rose"
        )
      end)

    assert_received {:request, "POST", "/api/multiboards", body}

    assert JSON.decode!(body) == %{
             "name" => "Ops queue",
             "lists" => "9,web/To Do",
             "top" => 3,
             "by" => "list",
             "color" => "rose"
           }

    assert out =~ "saved multiboard #7: Ops queue"
  end

  test "save-multiboard with only a name leaves the view to the server" do
    serve(201, %{"multiboard" => mb(7, "Plain")})
    capture_io(fn -> Boards.run("save-multiboard", ["Plain"], []) end)
    assert_received {:request, "POST", "/api/multiboards", body}
    assert JSON.decode!(body) == %{"name" => "Plain"}
  end

  test "set-multiboard sends only what was given" do
    serve(%{"multiboard" => mb(7, "Renamed")})

    out =
      capture_io(fn -> Boards.run("set-multiboard", ["7"], name: "Renamed", color: "teal") end)

    assert_received {:request, "PATCH", "/api/multiboards/7", body}
    assert JSON.decode!(body) == %{"name" => "Renamed", "color" => "teal"}
    assert out =~ "updated multiboard #7: Renamed"
  end

  test "delete-multiboard deletes it" do
    serve(%{"deleted" => mb(7, "Gone")})
    out = capture_io(fn -> Boards.run("delete-multiboard", ["7"], []) end)
    assert_received {:request, "DELETE", "/api/multiboards/7", _}
    assert out =~ "deleted multiboard Gone"
  end

  test "the CLI routes them and lists them in the help" do
    serve(%{"multiboards" => []})
    capture_io(fn -> SlipdockCLI.main(["multiboards"]) end)
    assert_received {:request, "GET", "/api/multiboards", _}

    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    assert help =~ "save-multiboard <name>"
    assert help =~ "set-multiboard <saved>"
    assert help =~ "delete-multiboard <saved>"
    assert help =~ "multiboard <saved>"
  end
end
