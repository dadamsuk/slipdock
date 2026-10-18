defmodule SlipdockCLI.HotkeysTest do
  @moduledoc """
  `slipdock hotkeys` and `slipdock hotkey <board> <digit>` (#1101). The usage
  refusal ends in `System.halt/1`, so it is not run here; the server's own
  refusals are in SlipdockWeb.API.HotkeysTest.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  @two ~s({"hotkeys":[{"digit":1,"board":{"id":3,"name":"Plan","code":"plan"}},{"digit":0,"board":{"id":4,"name":"Ops","code":"ops"}}]})

  test "hotkeys lists each digit with its board" do
    serve([{200, @two}])
    out = capture_io(fn -> Boards.run("hotkeys", [], []) end)

    assert_received {:request, "GET", "/api/hotkeys", _}
    assert out =~ ~r/Ctrl\+Shift\+1\s+Plan\s+plan\s+3/
    assert out =~ ~r/Ctrl\+Shift\+0\s+Ops\s+ops\s+4/
  end

  test "none yet says how to set one" do
    serve([{200, ~s({"hotkeys":[]})}])
    assert capture_io(fn -> Boards.run("hotkeys", [], []) end) =~ "slipdock hotkey <board> 1"
  end

  test "hotkey puts the digit on the board and says what it opens" do
    serve([{200, ~s({"board_id":3,"digit":2,"hotkeys":[]})}])
    out = capture_io(fn -> Boards.run("hotkey", ["plan", "2"], []) end)

    assert_received {:request, "PUT", "/api/boards/plan/hotkey", body}
    assert JSON.decode!(body) == %{"digit" => "2"}
    assert out =~ "Ctrl+Shift+2 now opens board plan"
  end

  test "hotkey none says the board has none now" do
    serve([{200, ~s({"board_id":3,"digit":null,"hotkeys":[]})}])
    out = capture_io(fn -> Boards.run("hotkey", ["plan", "none"], []) end)

    assert_received {:request, "PUT", "/api/boards/plan/hotkey", body}
    assert JSON.decode!(body) == %{"digit" => "none"}
    assert out =~ "board plan has no hotkey now"
  end

  test "--json passes the answer through" do
    serve([{200, @two}])
    json = capture_io(fn -> Boards.run("hotkeys", [], json: true) end)
    assert %{"hotkeys" => [%{"digit" => 1}, %{"digit" => 0}]} = JSON.decode!(json)
  end
end
