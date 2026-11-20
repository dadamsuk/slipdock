defmodule SlipdockCLI.SensitivityTest do
  @moduledoc """
  A tree's sensitivity (#3552): `set-board --sensitivity low|medium|high`
  sends it as given (the server judges it: `test/slipdock_web/sensitivity_web_test.exs`), and `--help` describes it.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.FakeServer

  setup do
    home =
      Path.join(System.tmp_dir!(), "slipdock-sensitivity-#{System.unique_integer([:positive])}")

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

  test "set-board --sensitivity sends the level; without it, none" do
    serve([{200, JSON.encode!(@board)}, {200, JSON.encode!(@board)}])

    capture_io(fn -> SlipdockCLI.main(["set-board", "slipdock", "--sensitivity", "high"]) end)
    assert_received {:request, "PATCH", "/api/boards/slipdock", body}
    assert JSON.decode!(body)["sensitivity"] == "high"

    capture_io(fn -> SlipdockCLI.main(["set-board", "slipdock", "--name", "S"]) end)
    assert_received {:request, "PATCH", _, body}
    refute Map.has_key?(JSON.decode!(body), "sensitivity")
  end

  test "--help describes it" do
    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    assert help =~ "[--sensitivity low|medium|high]"
    assert help =~ "--sensitivity low|medium|high: how carefully"
  end
end
