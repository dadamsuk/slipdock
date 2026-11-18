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

  test "new-tag is create_tag's request, the board in the path" do
    assert Op.request("new-tag", ~w(errands needs review), color: "red") ==
             {:post, "/boards/errands/tags", %{"name" => "needs review", "color" => "red"}}
  end

  test "note is quick_note's request, the words the text (#3188)" do
    assert Op.request("note", ~w(ring the printers), []) ==
             {:post, "/notes", %{"text" => "ring the printers"}}
  end

  test "page ai is page_tool's request, the page in the path" do
    assert Op.request("page ai", ~w(W-31 summarise), []) ==
             {:post, "/pages/W-31/ai", %{"tool" => "summarise"}}
  end

  test "job --keep-log is keep_job_log's request" do
    assert Op.request("job --keep", ["812"], keep_log: true) == {:post, "/jobs/812/keep", %{}}
  end

  test "tools install-board is install_tool's request, --name the board's name" do
    assert Op.request("tools install-board", ["triage"], name: "Mine", board: nil) ==
             {:post, "/tools/triage/install", %{"name" => "Mine"}}
  end

  test "activity is a GET: its params go in the query; ledger is its ledger view" do
    assert Op.request("activity", ["errands"], limit: 5, card: "12") ==
             {:get, "/boards/errands/activity", %{"limit" => 5, "card" => "12"}}

    assert Op.request("activity", ["errands"], view: "ledger", since: "7") ==
             {:get, "/boards/errands/activity", %{"view" => "ledger", "since" => "7"}}
  end

  test "garden apply|dismiss|undo is garden_decide's request, the decision in the path" do
    assert Op.request("garden", ~w(apply 42), keep: "#12") ==
             {:post, "/garden/suggestions/42/apply", %{"keep" => "#12"}}

    assert Op.request("garden", ~w(undo 42), []) == {:post, "/garden/suggestions/42/undo", %{}}
  end

  test "page revert is revert_page's request: --rev is the revision" do
    assert Op.request("page revert", ["W-31"], rev: "7", base_hash: "h1") ==
             {:post, "/pages/W-31/revert", %{"revision" => "7", "base_hash" => "h1"}}
  end

  test "page history and page diff are page_history's request: --against is diff" do
    assert Op.request("page history", ["W-31"], rev: "12", against: "previous") ==
             {:get, "/pages/W-31/revisions", %{"rev" => "12", "diff" => "previous"}}

    assert Op.request("page history", ["W-31"], limit: 5) ==
             {:get, "/pages/W-31/revisions", %{"limit" => 5}}
  end

  test "an operation the CLI has no command for (delete_board) is left out" do
    refute Map.has_key?(Op.ops(), nil)
    refute Enum.any?(Op.ops(), fn {_, op} -> op["name"] == "delete_board" end)
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

    test "new-tag says when the tag was there already" do
      tag = ~s({"tag":{"id":4,"name":"Infra","color":null},"created":false})
      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, tag}]))
      out = capture_io(fn -> Boards.run("new-tag", ~w(errands infra), []) end)

      assert_received {:request, "POST", "/api/boards/errands/tags", _}
      assert out =~ "already there: tag #4: Infra"
    end
  end

  describe "the flags a command takes come from its definition (#3191)" do
    test "a flag the definition names, or a global one, is taken" do
      assert :ok = Op.check("move", top: true, board: "errands", json: true, url: "x")
      assert :ok = Op.check("handoff", next: "x", file: "notes.md")
      assert :ok = Op.check("verify", reason: "-", check: "bar:1=ok", checks_file: "-")
    end

    test "any other is refused, naming the flags the command does take" do
      assert Op.check("move", column: "Doing", tree: true) ==
               {:error,
                "slipdock move does not take --column, --tree: it takes --board, --bottom, " <>
                  "--index, --top, and --json and --url, as every command does"}

      assert Op.check("page revert", base_hash: "h1", limit: 5) ==
               {:error,
                "slipdock page revert does not take --limit: it takes --base-hash, --message, " <>
                  "--rev, and --json and --url, as every command does"}
    end

    test "a command whose definition names no flag takes only the global ones" do
      assert Op.check("delete", force: true) ==
               {:error,
                "slipdock delete does not take --force: it takes only --json and --url, " <>
                  "as every command does"}
    end

    test "a usage takes only its own share of the definition's flags" do
      # archive_card's --restore is the restore command's, set by it.
      assert {:error, _} = Op.check("archive", restore: true)

      assert {:error, "slipdock ledger does not take --limit: it takes --since" <> _} =
               Op.check("ledger", limit: 5)

      assert {:error, _} = Op.check("activity", view: "ledger")
      assert :ok = Op.check("activity", card: "12", limit: 5, since: "7")
      assert {:error, _} = Op.check("page history", rev: "3")
      assert :ok = Op.check("page diff", rev: "3", against: "1")
      assert {:error, _} = Op.check("garden undo", keep: "1")
    end

    test "every usage's flags are its definition's, and its command a defined one" do
      for {usage, {command, only}} <- Op.usages() do
        flags = Map.keys(Op.ops()[command]["cli"]["flags"])
        assert only -- flags == [], "#{usage} takes #{inspect(only -- flags)}, not #{command}'s"
      end
    end

    test "a flag the command reads itself is taken but not sent as it was typed" do
      assert Op.request("handoff", ["5"], [next: "Ship", file: "notes.md"], body: "From the file") ==
               {:post, "/cards/5/handoff", %{"next_step" => "Ship", "body" => "From the file"}}

      assert Op.request("note", ["from stdin"], body: "-") ==
               {:post, "/notes", %{"text" => "from stdin"}}
    end

    test "what the command sets is sent over what was typed, and is not checked" do
      assert Op.request("ledger", ["errands"], [since: "7"], view: "ledger") ==
               {:get, "/boards/errands/activity", %{"view" => "ledger", "since" => "7"}}

      assert Op.request("restore", ["57"], [], restore: true) ==
               {:post, "/cards/57/archive", %{"restore" => true}}
    end
  end

  describe "a refused flag, run as a command" do
    # Each command made from a definition, as typed, with a flag none of
    # them takes. A refusal ends in `System.halt/1`, so each runs in an
    # `elixir` of its own; nothing listens on port 9, so a request made
    # before the refusal would fail with an error of its own instead.
    @refused [
      {"move", ~w(move 57 Doing)},
      {"archive", ~w(archive 57)},
      {"restore", ~w(restore 57)},
      {"delete", ~w(delete 57)},
      {"handoff", ~w(handoff 57 --next Ship)},
      {"verify", ~w(verify 57 accept)},
      {"verify", ~w(accept 57)},
      {"new-tag", ~w(new-tag errands infra)},
      {"note", ~w(note ring the printers)},
      {"page ai", ~w(page ai W-31 summarise)},
      {"page history", ~w(page history W-31)},
      {"page diff", ~w(page diff W-31)},
      {"page revert", ~w(page revert W-31 --rev 2)},
      {"job --keep", ~w(job 812 --keep)},
      {"tools install-board", ~w(tools install-board triage)},
      {"activity", ~w(activity errands)},
      {"ledger", ~w(ledger errands)},
      {"garden apply", ~w(garden apply 42)},
      {"garden dismiss", ~w(garden dismiss 42)},
      {"garden undo", ~w(garden undo 42)}
    ]

    test "every command made from a definition is in the list below" do
      named = MapSet.new(@refused, &elem(&1, 0))
      made = MapSet.new(Map.keys(Op.ops()) ++ Map.keys(Op.usages()))
      # garden's usages are its decisions: `garden` alone is the listing.
      assert MapSet.difference(made, named) == MapSet.new(["garden"])
    end

    test "exits 1 before any request, naming what the command takes" do
      home = Path.join(System.tmp_dir!(), "slipdock-op-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)

      @refused
      |> Task.async_stream(
        fn {usage, argv} -> {usage, argv, main(argv ++ ["--tree", "--json"], home)} end,
        timeout: 60_000
      )
      |> Enum.each(fn {:ok, {usage, argv, {out, status}}} ->
        assert status == 1, "#{Enum.join(argv, " ")}: #{out}"
        assert out =~ "error: slipdock #{usage} does not take --tree: it takes ", out
      end)
    end

    defp main(argv, home) do
      System.cmd(
        "elixir",
        ["-pa", Mix.Project.compile_path(), "-e", "SlipdockCLI.main(#{inspect(argv)})"],
        env: [
          {"HOME", home},
          {"SLIPDOCK_URL", "http://127.0.0.1:9"},
          {"SLIPDOCK_TOKEN", "test-token"}
        ],
        stderr_to_stdout: true
      )
    end
  end

  describe "the help names only flags a command takes" do
    @help Path.expand("../help.txt", __DIR__)

    # Each usage's entries in help.txt, by how they start.
    @entries %{
      "move" => ["move <id>"],
      "archive" => ["archive <id>"],
      "delete" => ["delete <id>"],
      "handoff" => ["handoff <id>"],
      "verify" => ["verify <id>", "accept <id>"],
      "new-tag" => ["new-tag <board>"],
      "note" => ["note <text"],
      "page ai" => ["page ai <page>"],
      "page history" => ["page history <page>"],
      "page diff" => ["page diff <page>"],
      "page revert" => ["page revert <page>"],
      "tools install-board" => ["tools install-board "],
      "activity" => ["activity <board>"],
      "ledger" => ["ledger <board>"],
      "garden apply" => ["garden apply <id>"],
      "garden dismiss" => ["garden dismiss|undo <id>"]
    }

    test "each flag on a defined command's help entry is one it takes" do
      entries = entries(File.read!(@help))

      for {usage, starts} <- @entries, start <- starts do
        text = Enum.filter(entries, &String.starts_with?(&1, start))
        assert text != [], "no help entry starts #{inspect(start)}"

        named =
          ~r/--([a-z][a-z-]*)/
          |> Regex.scan(Enum.join(text, "\n"))
          |> Enum.map(fn [_, f] -> String.replace(f, "-", "_") end)
          |> Enum.uniq()

        assert named -- (Op.takes(usage) ++ Op.global()) == [],
               "help names #{inspect(named -- Op.takes(usage))} for #{usage}"
      end
    end

    test "and job --keep is the one entry its flag only names" do
      assert Op.takes("job --keep") == []
      assert Enum.any?(entries(File.read!(@help)), &String.starts_with?(&1, "job <id> --keep "))
    end

    # An entry is a line at indent 2 and the lines indented deeper under it.
    defp entries(help) do
      help
      |> String.split("\n")
      |> Enum.chunk_while(
        nil,
        fn
          "  " <> <<c, _::binary>> = line, acc when c in ?a..?z ->
            if acc,
              do: {:cont, acc, String.trim_leading(line)},
              else: {:cont, String.trim_leading(line)}

          "    " <> _ = line, acc when is_binary(acc) ->
            {:cont, acc <> "\n" <> line}

          _line, nil ->
            {:cont, nil}

          _line, acc ->
            {:cont, acc, nil}
        end,
        fn
          nil -> {:cont, nil}
          acc -> {:cont, acc, nil}
        end
      )
    end
  end
end
