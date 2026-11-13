defmodule SlipdockCLI.WaitRoutesTest do
  @moduledoc """
  Who gets asked (#1949): `set-board --route` / `--no-route` send the board's
  `wait_routes`, `wait --kind` sends the question's kind, and `slipdock card`
  shows a wait's kind.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-routes-#{System.unique_integer([:positive])}")
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

  test "set-board --route and --no-route send wait_routes, by kind" do
    serve([{200, JSON.encode!(@board)}])

    out =
      capture_io(fn ->
        SlipdockCLI.main([
          "set-board",
          "slipdock",
          "--route",
          "product=pat@example.com, lee@example.com",
          "--route",
          "release=sam@example.com",
          "--no-route",
          "ux"
        ])
      end)

    assert_received {:request, "PATCH", "/api/boards/slipdock", body}

    assert JSON.decode!(body)["wait_routes"] == %{
             "product" => ["pat@example.com", "lee@example.com"],
             "release" => ["sam@example.com"],
             "ux" => []
           }

    assert out =~ "updated board #3"
  end

  test "without --route, set-board sends no wait_routes" do
    serve([{200, JSON.encode!(@board)}])
    capture_io(fn -> SlipdockCLI.main(["set-board", "slipdock", "--name", "Slipdock"]) end)
    assert_received {:request, "PATCH", _, body}
    refute Map.has_key?(JSON.decode!(body), "wait_routes")
  end

  test "wait_routes/1 reads the switches; nothing given is nil" do
    assert Boards.wait_routes([]) == nil
    assert Boards.wait_routes(no_route: "other") == %{"other" => []}

    assert Boards.wait_routes(route: "ux=a@example.com,,b@example.com") == %{
             "ux" => ["a@example.com", "b@example.com"]
           }
  end

  test "wait --kind sends the question's kind" do
    wait = %{"needs" => "Which tier?", "on" => %{"name" => "Pat"}, "question" => "product"}
    serve([{201, JSON.encode!(%{"wait" => wait})}])

    out =
      capture_io(fn -> SlipdockCLI.main(["wait", "12", "Which tier?", "--kind", "product"]) end)

    assert_received {:request, "POST", "/api/cards/12/wait", body}
    assert JSON.decode!(body) == %{"needs" => "Which tier?", "question" => "product"}
    assert out =~ "#12 waits on Pat (product): Which tier?"
  end

  test "a wait without --kind sends none, and a line without one shows none" do
    serve([{201, JSON.encode!(%{"wait" => %{"needs" => "?"}})}])
    capture_io(fn -> SlipdockCLI.main(["wait", "12", "?"]) end)
    assert_received {:request, "POST", _, body}
    refute Map.has_key?(JSON.decode!(body), "question")
    assert Render.wait_line(%{"needs" => "?"}) == "waits on anyone: ?"
  end

  test "--help describes --route and --kind" do
    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    assert help =~ "[--route KIND=EMAIL[,EMAIL]]... [--no-route KIND]..."
    assert help =~ "--kind is what kind of question it is (product,"
  end
end
