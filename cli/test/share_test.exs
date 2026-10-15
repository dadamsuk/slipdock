defmodule SlipdockCLI.ShareTest do
  @moduledoc "`slipdock page share`, `folder share` and `shared` (#820)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Wiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-share-#{System.unique_integer([:positive])}")
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

  @grant ~s({"grant":{"id":1,"level":"write","user":{"email":"friend@example.com"},"group":null}})

  defp run(cmd, args, opts, responses) do
    System.put_env("SLIPDOCK_URL", FakeServer.start(responses))
    capture_io(fn -> Wiki.run(cmd, args, opts) end)
  end

  test "page share EMAIL --write shares it with that person, to edit" do
    out = run("page", ["share", "W-31", "friend@example.com"], [write: true], [{201, @grant}])

    assert_received {:request, "POST", "/api/pages/W-31/grants", body}
    assert JSON.decode!(body) == %{"email" => "friend@example.com", "level" => "write"}
    assert out =~ "shared with friend@example.com: can edit"
  end

  test "a name without an @ is a group, and read only is the default" do
    run("page", ["share", "W-31", "Ops"], [], [{201, @grant}])

    assert_received {:request, "POST", "/api/pages/W-31/grants", body}
    assert JSON.decode!(body) == %{"group" => "Ops", "level" => "read"}
  end

  test "--off takes the share back" do
    out =
      run("page", ["share", "W-31", "friend@example.com"], [off: true], [
        {200, ~s({"revoked":true})}
      ])

    assert_received {:request, "DELETE", path, _}
    assert path =~ "/api/pages/W-31/grants"
    assert path =~ "email=friend"
    assert out =~ "no longer shared with friend@example.com"
  end

  test "with nobody named, lists who has it" do
    grants =
      ~s({"grants":[{"level":"read","user":{"email":"a@example.com"},"group":null},{"level":"write","user":null,"group":{"name":"Ops"}}]})

    out = run("page", ["share", "W-31"], [], [{200, grants}])
    assert_received {:request, "GET", "/api/pages/W-31/grants", _}
    assert out =~ "read only a@example.com"
    assert out =~ "can edit  group Ops"
  end

  test "folder share finds the folder on its board, then shares it" do
    folder = ~s({"folder":{"id":7,"path":"Specs"}})

    run("folder", ["share", "kb", "Specs", "friend@example.com"], [write: true], [
      {200, folder},
      {201, @grant}
    ])

    assert_received {:request, "GET", "/api/boards/kb/folders/Specs", _}
    assert_received {:request, "POST", "/api/folders/7/grants", body}
    assert JSON.decode!(body)["level"] == "write"
  end

  test "shared lists what is shared with you, by owner, with codes" do
    shared =
      ~s({"shared":[{"owner":{"name":"Alice","email":"alice@example.com"},"items":[{"kind":"folder","name":"Specs","level":"read","folders":[],"pages":[{"kind":"page","code":"W-9","title":"Plan","level":"read"}],"files":[{"name":"chart.png"}]},{"kind":"page","code":"W-31","title":"Loose","level":"write"}]}]})

    out = run("shared", [], [], [{200, shared}])
    assert_received {:request, "GET", "/api/shared", _}
    assert out =~ "from Alice"
    assert out =~ "Specs/"
    assert out =~ "W-9"
    assert out =~ "chart.png"
    assert out =~ "Loose"
    assert out =~ "can edit"

    assert run("shared", [], [], [{200, ~s({"shared":[]})}]) =~ "nothing is shared with you"
  end
end
