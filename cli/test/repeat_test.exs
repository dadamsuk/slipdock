defmodule SlipdockCLI.RepeatTest do
  @moduledoc "`slipdock repeat` and `slipdock recurring`: what they send, and what they show."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-repeat-#{System.unique_integer([:positive])}")
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

    :ok
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @series %{
    "id" => 3,
    "card_id" => 7,
    "kind" => "fixed",
    "rule" => "FREQ=WEEKLY;BYDAY=MO",
    "summary" => "Every week on Mon, 07:00 Europe/London",
    "starts_on" => "2027-01-11",
    "at" => "07:00",
    "timezone" => "Europe/London",
    "lead_days" => 0,
    "on_missed" => "bump",
    "ends" => "never",
    "made" => 1,
    "next_on" => "2027-01-18",
    "next_at" => "2027-01-18T07:00:00Z",
    "upcoming" => ["2027-01-18", "2027-01-25", "2027-02-01"],
    "paused" => false,
    "ended_at" => nil
  }

  defp body(series, extra \\ %{}),
    do: JSON.encode!(Map.merge(%{"card" => 7, "recurrence" => series, "current" => true}, extra))

  test "a rule and options PUT the series, and it's shown back" do
    serve([{200, body(@series)}])

    out =
      capture_io(fn ->
        Boards.run("repeat", ["7", "every", "mon"],
          at: "07:00",
          lead: 2,
          count: 5,
          on_missed: "stack",
          column: "To Do",
          tz: "Europe/London"
        )
      end)

    assert_received {:request, "PUT", "/api/cards/7/recurrence", sent}

    assert JSON.decode!(sent) == %{
             "rule" => "every mon",
             "at" => "07:00",
             "lead_days" => 2,
             "ends" => "after",
             "count" => 5,
             "on_missed" => "stack",
             "column" => "To Do",
             "timezone" => "Europe/London"
           }

    assert out =~ "#7 repeats: Every week on Mon, 07:00 Europe/London"
    assert out =~ "next due 2027-01-18"
    assert out =~ "2027-01-18, 2027-01-25, 2027-02-01"
  end

  test "--ends DATE, --ends never, --pause and --resume" do
    serve([
      {200, body(@series)},
      {200, body(@series)},
      {200, body(@series)},
      {200, body(@series)}
    ])

    capture_io(fn ->
      Boards.run("repeat", ["7"], ends: "2027-06-30")
      Boards.run("repeat", ["7"], ends: "never")
      Boards.run("repeat", ["7"], pause: true)
      Boards.run("repeat", ["7"], resume: true)
    end)

    assert_received {:request, "PUT", _, a}
    assert JSON.decode!(a) == %{"ends" => "on", "ends_on" => "2027-06-30"}
    assert_received {:request, "PUT", _, b}
    assert JSON.decode!(b) == %{"ends" => "never"}
    assert_received {:request, "PUT", _, c}
    assert JSON.decode!(c) == %{"paused" => true}
    assert_received {:request, "PUT", _, d}
    assert JSON.decode!(d) == %{"paused" => false}
  end

  test "alone it shows the series; an earlier instance says where the series is" do
    serve([{200, body(@series, %{"card" => 5, "current" => false})}])
    out = capture_io(fn -> Boards.run("repeat", ["5"], []) end)
    assert_received {:request, "GET", "/api/cards/5/recurrence", _}
    assert out =~ "#5 repeats"
    assert out =~ "the series is on #7 now"
  end

  test "a card that doesn't repeat says so" do
    serve([{200, ~s({"card":7,"recurrence":null,"current":false})}])
    out = capture_io(fn -> Boards.run("repeat", ["7"], []) end)
    assert out =~ "#7 doesn't repeat."
  end

  test "--off stops it and --skip skips one" do
    serve([
      {200, ~s({"card":7,"recurrence":null})},
      {200, body(%{@series | "next_on" => "2027-01-25"})}
    ])

    out =
      capture_io(fn ->
        Boards.run("repeat", ["7"], off: true)
        Boards.run("repeat", ["7"], skip: true)
      end)

    assert_received {:request, "DELETE", "/api/cards/7/recurrence", _}
    assert_received {:request, "POST", "/api/cards/7/recurrence/skip", _}
    assert out =~ "#7 no longer repeats"
    assert out =~ "next due 2027-01-25"
  end

  test "recurring lists a board's series" do
    row = Map.put(@series, "card", %{"id" => 7, "title" => "Review invoices"})
    serve([{200, JSON.encode!(%{"board" => 3, "recurring" => [row]})}])
    out = capture_io(fn -> Boards.run("recurring", ["ops"], []) end)
    assert_received {:request, "GET", "/api/boards/ops/recurring", _}
    assert out =~ "↻ Review invoices"
    assert out =~ "Every week on Mon"

    serve([{200, ~s({"board":3,"recurring":[]})}])

    assert capture_io(fn -> Boards.run("recurring", ["ops"], []) end) =~
             "nothing on this board repeats"
  end

  test "the card shows how it repeats, and a front marker" do
    card = %{
      "id" => 7,
      "title" => "Review invoices",
      "board_id" => 3,
      "column" => "To Do",
      "column_id" => 9,
      "position" => 0,
      "priority" => "none",
      "flags" => [],
      "tags" => [],
      "comments" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "assignees" => [],
      "blocked_by" => [],
      "blocks" => [],
      "attachments" => [],
      "urls" => [],
      "docs" => [],
      "recurrence" => %{@series | "paused" => true}
    }

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ "Repeats"
    assert out =~ "Every week on Mon, 07:00 Europe/London · paused"
    assert Render.card_line(card, true) =~ "↻"

    older = card |> Map.delete("recurrence") |> Map.put("series_id", 3)
    assert capture_io(fn -> Render.card(older) end) =~ "an earlier instance of series #3"
    refute Render.card_line(older, true) =~ "↻"
  end
end
