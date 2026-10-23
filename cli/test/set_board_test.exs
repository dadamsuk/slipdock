defmodule SlipdockCLI.SetBoardTest do
  @moduledoc "`set-board --[no-]page-card-features`: what it parses and sends."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-setboard-#{System.unique_integer([:positive])}")
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

  @updated ~s({"board":{"id":3,"name":"Docs"}})

  test "--no-page-card-features parses as a boolean switch" do
    {opts, ["set-board", "docs"], []} =
      OptionParser.parse(["set-board", "docs", "--no-page-card-features"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:page_card_features] == false
  end

  test "--no-page-card-features sends false for the board" do
    serve([{200, @updated}])

    out = capture_io(fn -> Boards.run("set-board", ["docs"], page_card_features: false) end)

    assert out =~ "updated board #3: Docs"
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"page_card_features" => false}
  end

  test "--page-card-features turns them back on" do
    serve([{200, @updated}])

    capture_io(fn -> Boards.run("set-board", ["docs"], page_card_features: true) end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"page_card_features" => true}
  end

  test "--default-view parses as a string and sends it" do
    {opts, ["set-board", "docs"], []} =
      OptionParser.parse(["set-board", "docs", "--default-view", "wiki"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:default_view] == "wiki"

    serve([{200, @updated}])
    capture_io(fn -> Boards.run("set-board", ["docs"], default_view: "wiki") end)

    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"default_view" => "wiki"}
  end

  test "the board heading says what a board opens on, unless it is the board" do
    board = %{
      "id" => 3,
      "name" => "Docs",
      "code" => "docs",
      "color" => "indigo",
      "columns" => [],
      "tags" => []
    }

    out = capture_io(fn -> SlipdockCLI.Render.board(Map.put(board, "default_view", "wiki")) end)
    assert out =~ "opens on wiki"

    out = capture_io(fn -> SlipdockCLI.Render.board(Map.put(board, "default_view", "board")) end)
    refute out =~ "opens on"
  end

  test "--[no-]delivery-metrics parses as a switch and sends it (#1134)" do
    {opts, ["set-board", "docs"], []} =
      OptionParser.parse(["set-board", "docs", "--no-delivery-metrics"],
        strict: SlipdockCLI.switches()
      )

    assert opts[:delivery_metrics] == false

    serve([{200, @updated}, {200, @updated}])
    capture_io(fn -> Boards.run("set-board", ["docs"], delivery_metrics: true) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"delivery_metrics" => true}

    capture_io(fn -> Boards.run("set-board", ["docs"], delivery_metrics: false) end)
    assert_received {:request, "PATCH", "/api/boards/docs", body}
    assert JSON.decode!(body) == %{"delivery_metrics" => false}
  end

  describe "handoff settings (#1212)" do
    test "--handoff-label and --handoff-prompt parse as strings and are sent" do
      {opts, ["set-board", "docs"], []} =
        OptionParser.parse(
          ["set-board", "docs", "--handoff-label", "Parked", "--handoff-prompt", "Be brief."],
          strict: SlipdockCLI.switches()
        )

      serve([{200, @updated}])
      capture_io(fn -> Boards.run("set-board", ["docs"], opts) end)

      assert_received {:request, "PATCH", "/api/boards/docs", body}
      assert JSON.decode!(body) == %{"handoff_label" => "Parked", "handoff_prompt" => "Be brief."}
    end

    test "an empty value is sent, so the board goes back to the default" do
      serve([{200, @updated}])
      capture_io(fn -> Boards.run("set-board", ["docs"], handoff_label: "") end)

      assert_received {:request, "PATCH", "/api/boards/docs", body}
      assert JSON.decode!(body) == %{"handoff_label" => ""}
    end

    test "--handoff-prompt-file sends the file's text, over --handoff-prompt" do
      path = Path.join(System.get_env("HOME"), "prompt.txt")
      File.write!(path, "Write the next step first.\nThen the rest.\n")

      serve([{200, @updated}])

      capture_io(fn ->
        Boards.run("set-board", ["docs"], handoff_prompt: "ignored", handoff_prompt_file: path)
      end)

      assert_received {:request, "PATCH", "/api/boards/docs", body}

      assert JSON.decode!(body) == %{
               "handoff_prompt" => "Write the next step first.\nThen the rest.\n"
             }
    end
  end
end
