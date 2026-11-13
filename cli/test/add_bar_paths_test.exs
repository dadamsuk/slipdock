defmodule SlipdockCLI.AddBarPathsTest do
  @moduledoc """
  `slipdock add --bar … --paths …` (#1757): a planned card is made with its
  bar and paths in the one request, the paths as written (the server splits
  and checks them, as it does for `edit --paths`), and neither is sent when
  it isn't asked for. The refusals themselves are the server's
  (`SlipdockWeb.API.CardControllerTest`).
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-addbar-#{System.unique_integer([:positive])}")
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

  @card ~s({"card":{"id":7,"title":"Planned","column":"To Do","priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0}}})

  defp add(argv) do
    {opts, _args, []} = OptionParser.parse(argv, strict: SlipdockCLI.switches())
    System.put_env("SLIPDOCK_URL", FakeServer.start([{201, @card}]))
    output = capture_io(fn -> Boards.run("add", ["b", "Planned"], opts) end)
    assert_received {:request, "POST", "/api/boards/b/cards", body}
    {JSON.decode!(body), output}
  end

  test "--bar and --paths go in the one create, the paths as written" do
    {body, output} =
      add(["--bar", "The API takes it; tests for each.", "--paths", "lib/x/**,docs/{a,b}.md"])

    assert body["title"] == "Planned"
    assert body["bar"] == "The API takes it; tests for each."
    assert body["paths"] == "lib/x/**,docs/{a,b}.md"
    assert output =~ "created"
  end

  test "each goes alone" do
    {body, _} = add(["--bar", "Done when it ships."])
    assert body["bar"] == "Done when it ships."
    refute Map.has_key?(body, "paths")

    {body, _} = add(["--paths", "lib/y.ex"])
    assert body["paths"] == "lib/y.ex"
    refute Map.has_key?(body, "bar")
  end

  test "without them neither is sent" do
    {body, _} = add([])
    refute Map.has_key?(body, "bar")
    refute Map.has_key?(body, "paths")
  end

  test "--help lists them under add" do
    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)
    [_, add] = String.split(help, "\n  add <board> <title>", parts: 2)
    [add | _] = String.split(add, "\n  edit <id>", parts: 2)
    assert add =~ "--bar TEXT"
    assert add =~ "--paths"
  end
end
