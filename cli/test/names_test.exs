defmodule SlipdockCLI.NamesTest do
  @moduledoc "`slipdock names`, and `--short-names` on `folder ls` (#1594)."
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Auth, FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-names-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(response) do
    body = response |> :json.encode() |> IO.iodata_to_binary()
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))
  end

  test "says the choice" do
    serve(%{"user" => %{"tree_names" => "short"}})
    assert capture_io(fn -> Auth.run("names", [], []) end) == "short\n"
  end

  test "sets it" do
    serve(%{"tree_names" => "full"})
    assert capture_io(fn -> Auth.run("names", ["full"], []) end) == "full\n"
  end

  describe "folder ls" do
    setup do
      serve(%{
        "pages" => [],
        "folders" => [
          %{
            "name" => "Parked jobs must be rele",
            "title" => "Parked jobs must be released",
            "short_name" => "Parked jobs",
            "slug" => "card-1",
            "pages" => [],
            "folders" => []
          },
          %{"name" => "Design", "title" => "Design", "slug" => "design"}
        ]
      })
    end

    test "says titles by default" do
      out = capture_io(fn -> Wiki.run("folder", ["ls", "kb"], []) end)
      assert out =~ "Parked jobs must be released/"
    end

    test "--short-names, falling back to the title" do
      out = capture_io(fn -> Wiki.run("folder", ["ls", "kb"], short_names: true) end)

      assert out =~ "Parked jobs/"
      refute out =~ "released"
      assert out =~ "Design/"
    end
  end
end
