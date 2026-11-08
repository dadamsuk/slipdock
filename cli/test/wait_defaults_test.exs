defmodule SlipdockCLI.WaitDefaultsTest do
  @moduledoc """
  A moot wait clears itself (#2096): `set-board --wait-default-after` sends
  the board's setting, `wait … --default N` the choice it proposes (marked
  on the wait's line), and `wait <id> --withdraw --reason WHY` the reason
  an agent gives for withdrawing a wait it didn't open.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-defaults-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    saved =
      Map.new(
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN SLIPDOCK_JOB_ID),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN SLIPDOCK_JOB_ID), &System.delete_env/1)

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

  @board %{"board" => %{"id" => 3, "name" => "Slipdock"}}

  test "set-board --wait-default-after sends the time as given; off too" do
    serve([{200, JSON.encode!(@board)}, {200, JSON.encode!(@board)}])

    capture_io(fn ->
      SlipdockCLI.main(["set-board", "slipdock", "--wait-default-after", "4h"])
    end)

    assert_received {:request, "PATCH", "/api/boards/slipdock", body}
    assert JSON.decode!(body)["wait_default_after"] == "4h"

    capture_io(fn ->
      SlipdockCLI.main(["set-board", "slipdock", "--wait-default-after", "off"])
    end)

    assert_received {:request, "PATCH", _, body}
    assert JSON.decode!(body)["wait_default_after"] == "off"
  end

  test "without it, set-board sends none" do
    serve([{200, JSON.encode!(@board)}])
    capture_io(fn -> SlipdockCLI.main(["set-board", "slipdock", "--name", "Slipdock"]) end)
    assert_received {:request, "PATCH", _, body}
    refute Map.has_key?(JSON.decode!(body), "wait_default_after")
  end

  test "wait --default sends the proposed choice, and the line marks it" do
    wait = %{"needs" => "Ship it?", "choices" => ["Yes", "No"], "default_choice" => 1}
    serve([{201, JSON.encode!(%{"wait" => wait})}])

    out =
      capture_io(fn ->
        SlipdockCLI.main([
          "wait",
          "12",
          "Ship it?",
          "--choice",
          "Yes",
          "--choice",
          "No",
          "--default",
          "1"
        ])
      end)

    assert_received {:request, "POST", "/api/cards/12/wait", body}
    assert JSON.decode!(body)["default"] == 1
    assert out =~ "1. Yes (proposed)"
    refute out =~ "2. No (proposed)"
    refute Render.wait_line(%{"needs" => "?", "choices" => ["a"]}) =~ "(proposed)"
  end

  test "wait --withdraw --reason sends the reason; without it, none" do
    wait = %{"needs" => "Ship it?"}
    serve([{200, JSON.encode!(%{"wait" => wait})}, {200, JSON.encode!(%{"wait" => wait})}])

    out =
      capture_io(fn ->
        SlipdockCLI.main(["wait", "12", "--withdraw", "--reason", "Moot: W-31 settled it"])
      end)

    assert_received {:request, "DELETE", path, _}
    assert path == "/api/cards/12/wait?reason=Moot%3A+W-31+settled+it"
    assert out =~ "withdrew the wait on #12: Ship it?"

    capture_io(fn -> SlipdockCLI.main(["wait", "12", "--withdraw"]) end)
    assert_received {:request, "DELETE", "/api/cards/12/wait", _}
  end

  test "--help describes them" do
    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    assert help =~ "[--wait-default-after TIME|off]"
    assert help =~ "--default N names the choice you propose"
    assert help =~ "wait <id> --withdraw [--reason WHY]"
  end
end
