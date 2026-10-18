defmodule SlipdockCLI.SnoozeTest do
  @moduledoc "`slipdock snooze`, `wake` and `cards --snoozed`: what they send, and what they show."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-snooze-#{System.unique_integer([:positive])}")
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

  @card %{
    "id" => 7,
    "title" => "Chase the quote",
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
    "snoozed_until" => "2027-01-18T00:00:00Z",
    "snooze" => %{"until" => "2027-01-18T00:00:00Z", "note" => "vendor's quote"}
  }

  defp body(card), do: JSON.encode!(%{"card" => card})

  test "snooze posts the moment, the note and notify, for each card" do
    serve([{200, body(@card)}, {200, body(%{@card | "id" => 8})}])

    out =
      capture_io(fn ->
        Boards.run("snooze", ["7", "#8", "next", "week"], note: "vendor's quote", notify: true)
      end)

    assert_received {:request, "POST", "/api/cards/7/snooze", a}
    assert_received {:request, "POST", "/api/cards/8/snooze", b}

    assert JSON.decode!(a) == %{
             "until" => "next week",
             "note" => "vendor's quote",
             "notify" => true
           }

    assert a == b
    assert out =~ "snoozed #7"
    assert out =~ "💤2027-01-18"
  end

  test "without a note or notify it sends only the moment" do
    serve([{200, body(@card)}])
    capture_io(fn -> Boards.run("snooze", ["7", "2027-01-18"], []) end)
    assert_received {:request, "POST", "/api/cards/7/snooze", sent}
    assert JSON.decode!(sent) == %{"until" => "2027-01-18"}
  end

  test "the arguments: ids first, then the moment" do
    assert Boards.snooze_args(["7", "#8", "in", "3", "days"]) == {:ok, ["7", "8"], "in 3 days"}
    assert {:error, "usage: " <> _} = Boards.snooze_args(["tomorrow"])
    assert {:error, "snooze until when?" <> _} = Boards.snooze_args(["7", "8"])
    assert {:error, "usage: " <> _} = Boards.snooze_args([])
  end

  test "wake deletes the snooze of each card" do
    awake = Map.drop(@card, ["snoozed_until", "snooze"])
    serve([{200, body(awake)}, {200, body(%{awake | "id" => 8})}])
    out = capture_io(fn -> Boards.run("wake", ["7", "8"], []) end)
    assert_received {:request, "DELETE", "/api/cards/7/snooze", _}
    assert_received {:request, "DELETE", "/api/cards/8/snooze", _}
    assert out =~ "woke #7"
    refute out =~ "💤"
  end

  test "cards --snoozed passes the filter on" do
    serve([{200, JSON.encode!(%{"cards" => [@card]})}])
    out = capture_io(fn -> Boards.run("cards", ["ops"], snoozed: "only") end)
    assert_received {:request, "GET", path, _}
    assert path =~ "/api/boards/ops/cards"
    assert path =~ "snoozed=only"
    assert out =~ "💤2027-01-18"
  end

  test "the card shows its snooze" do
    out = capture_io(fn -> Render.card(@card) end)
    assert out =~ "Snoozed"
    assert out =~ "until 2027-01-18 00:00 UTC — vendor's quote"

    refute capture_io(fn -> Render.card(Map.drop(@card, ["snooze", "snoozed_until"])) end) =~
             "Snoozed"
  end
end
