defmodule SlipdockCLI.IncidentsTest do
  @moduledoc """
  Incidents (#1946) at the CLI: `add`/`edit --caused-by N --missed-by L`
  send both fields, `--no-caused-by`/`--no-missed-by` clear them, and
  `card` shows both ends of the link. The refusals (an unknown layer, a card
  the person can't read) are the server's (`Slipdock.IncidentsTest`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-incident-#{System.unique_integer([:positive])}")
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

  @card ~s({"card":{"id":7,"title":"Broke","column":"To Do","priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0}}})

  defp run(command, args, argv, status) do
    {opts, _args, []} = OptionParser.parse(argv, strict: SlipdockCLI.switches())
    System.put_env("SLIPDOCK_URL", FakeServer.start([{status, @card}]))
    capture_io(fn -> Boards.run(command, args, opts) end)
  end

  test "add sends --caused-by and --missed-by in the one create" do
    run("add", ["b", "Broke"], ["--caused-by", "#12", "--missed-by", "ci"], 201)
    assert_received {:request, "POST", "/api/boards/b/cards", body}
    assert %{"caused_by" => "#12", "missed_by" => "ci"} = JSON.decode!(body)
  end

  test "add without them sends neither" do
    run("add", ["b", "Broke"], [], 201)
    assert_received {:request, "POST", "/api/boards/b/cards", body}
    body = JSON.decode!(body)
    refute Map.has_key?(body, "caused_by")
    refute Map.has_key?(body, "missed_by")
  end

  test "edit sets them, and --no-… clears each to null" do
    run("edit", ["7"], ["--caused-by", "12", "--missed-by", "verify"], 200)
    assert_received {:request, "PATCH", "/api/cards/7", body}
    assert %{"caused_by" => "12", "missed_by" => "verify"} = JSON.decode!(body)

    run("edit", ["7"], ["--no-caused-by", "--no-missed-by"], 200)
    assert_received {:request, "PATCH", "/api/cards/7", body}
    assert JSON.decode!(body) == %{"caused_by" => nil, "missed_by" => nil}
  end

  defp card(extra) do
    Map.merge(
      %{
        "id" => 7,
        "title" => "Broke",
        "board_id" => 3,
        "blocked_by" => [],
        "blocks" => [],
        "flags" => [],
        "tags" => [],
        "assignees" => [],
        "checklist" => %{"done" => 0, "total" => 0, "items" => []},
        "comments" => [],
        "attachments" => [],
        "urls" => [],
        "links" => []
      },
      extra
    )
  end

  test "card shows the incident's cause and the layer that missed it" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "caused_by" => 12,
            "missed_by" => "ci",
            "caused_by_card" => %{"id" => 12, "title" => "Shipped it"}
          })
        )
      end)

    assert out =~ ~r/Incident:\s+caused by #12 Shipped it · missed by ci/
  end

  test "a cause the reader can't read shows as its number alone" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{"caused_by" => 12, "caused_by_card" => %{"id" => 12, "hidden" => true}})
        )
      end)

    assert out =~ ~r/Incident:\s+caused by #12\n/
  end

  test "the causing card shows caused incident #N" do
    out =
      capture_io(fn ->
        Render.card(
          card(%{
            "incidents" => [%{"id" => 40, "title" => "Login broke", "missed_by" => "rules"}]
          })
        )
      end)

    assert out =~ ~r/Incidents:\s+caused incident #40 Login broke \(missed by rules\)/
  end

  test "a card with no incident shows no Incident line" do
    out = capture_io(fn -> Render.card(card(%{})) end)
    refute out =~ "Incident"
  end

  test "--help lists them under add and edit" do
    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    [_, add] = String.split(help, "\n  add <board> <title>", parts: 2)
    [add, edit] = String.split(add, "\n  edit <id>", parts: 2)
    assert add =~ "--caused-by N"
    assert edit =~ "--caused-by N | --no-caused-by"
    assert edit =~ "--missed-by L | --no-missed-by"
  end
end
