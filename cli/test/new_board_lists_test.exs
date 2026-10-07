defmodule SlipdockCLI.NewBoardListsTest do
  @moduledoc "`new-board --list ... --save-template NAME`: what it sends."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-lists-#{System.unique_integer([:positive])}")
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

  @created ~s({"board":{"id":7,"name":"Hiring"}})

  test "--list sends the lists in order, with wip and colour, and --save-template the name" do
    serve([{201, @created}])

    out =
      capture_io(fn ->
        Boards.run("new-board", ["Hiring"],
          list: "Applied",
          list: "Interview:2",
          list: "Done:0:emerald",
          save_template: "Hiring flow"
        )
      end)

    assert out =~ "created board #7: Hiring"
    assert_received {:request, "POST", "/api/boards", body}

    assert JSON.decode!(body) == %{
             "name" => "Hiring",
             "columns" => [
               %{"name" => "Applied"},
               %{"name" => "Interview", "wip_limit" => "2"},
               %{"name" => "Done", "wip_limit" => "0", "color" => "emerald"}
             ],
             "save_template" => "Hiring flow"
           }
  end

  test "without --list it sends no columns, so the template or the defaults apply" do
    serve([{201, @created}])

    capture_io(fn -> Boards.run("new-board", ["Hiring"], template: "Simple") end)

    assert_received {:request, "POST", "/api/boards", body}
    assert JSON.decode!(body) == %{"name" => "Hiring", "template" => "Simple"}
  end

  test "new-template still reads --list the same way" do
    serve([{201, ~s({"template":{"id":3,"name":"Flow"}})}])

    capture_io(fn -> Boards.run("new-template", ["Flow"], list: "A:3", list: "B") end)

    assert_received {:request, "POST", "/api/templates", body}

    assert JSON.decode!(body)["columns"] == [
             %{"name" => "A", "wip_limit" => "3"},
             %{"name" => "B"}
           ]
  end
end
