defmodule SlipdockCLI.OpTest do
  @moduledoc """
  `slipdock move` built from the server's definition of
  `move_card` (`priv/ops.json`): the words and flags become that definition's
  params, and the request is what REST and MCP take.
  """
  # Sync: the end-to-end test sets HOME and the SLIPDOCK_* variables, which are
  # one environment for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Op}

  test "words fill the positional params, the last taking the rest" do
    assert Op.request("move", ~w(57 In Progress), []) ==
             {:post, "/cards/57/move", %{"column" => "In Progress"}}
  end

  test "flags map onto params by the definition" do
    assert {:post, _, %{"index" => "top"}} = Op.request("move", ~w(57 Doing), top: true)
    assert {:post, _, %{"index" => 2}} = Op.request("move", ~w(57 Doing), index: 2)

    assert {:post, "/cards/57/move", %{"board" => "errands", "column" => "To Do"}} =
             Op.request("move", ~w(57 To Do), board: "errands")
  end

  test "a flag left false sends nothing: the server's default (bottom) holds" do
    assert {:post, _, body} = Op.request("move", ~w(57 Doing), top: false)
    refute Map.has_key?(body, "index")
  end

  test "archive and restore are the one archive_card request (#3187)" do
    assert Op.request("archive", ["57"], []) == {:post, "/cards/57/archive", %{}}

    assert Op.request("archive", ["57"], restore: true) ==
             {:post, "/cards/57/archive", %{"restore" => true}}
  end

  test "delete is delete_card's request, with no confirm: REST never asks for one" do
    assert Op.request("delete", ["57"], []) == {:delete, "/cards/57", %{}}
  end

  test "verify is verify_card's request: --evidence-commit is commit, --check checks" do
    assert Op.request("verify", ~w(12 reject),
             reason: "No test",
             evidence_commit: "abc123",
             check: ["bar:1=fail"]
           ) ==
             {:post, "/cards/12/verify",
              %{
                "decision" => "reject",
                "reason" => "No test",
                "commit" => "abc123",
                "checks" => ["bar:1=fail"]
              }}
  end

  describe "slipdock move, end to end against a fake server" do
    setup do
      home = Path.join(System.tmp_dir!(), "slipdock-op-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)

      saved =
        Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})

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

    test "sends the definition's request and says what moved" do
      card =
        ~s({"card":{"id":57,"title":"Ship it","column":"Doing","completed":false,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, card}]))
      out = capture_io(fn -> Boards.run("move", ~w(57 Doing), top: true) end)

      assert_received {:request, "POST", "/api/cards/57/move", body}
      assert JSON.decode!(body) == %{"column" => "Doing", "index" => "top"}
      assert out =~ "moved"
    end

    test "restore asks archive_card with restore, and says so" do
      card =
        ~s({"card":{"id":57,"title":"Ship it","column":"Doing","completed":false,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, card}]))
      out = capture_io(fn -> Boards.run("restore", ["57"], []) end)

      assert_received {:request, "POST", "/api/cards/57/archive", body}
      assert JSON.decode!(body) == %{"restore" => true}
      assert out =~ "restored"
    end
  end
end
