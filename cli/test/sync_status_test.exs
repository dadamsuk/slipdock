defmodule SlipdockCLI.SyncStatusTest do
  @moduledoc """
  `slipdock sync status` (W-103 R2.13): the last run, what is waiting on
  each side, the conflicts left to resolve — and the warning when another
  sync tool is looking after the same folder.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Sync}
  alias SlipdockCLI.Sync.{State, Status, Watch}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-status-#{System.unique_integer([:positive])}")
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

    %{home: home}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp entry(id, content), do: %{"id" => id, "kind" => "page", "hash" => sha(content)}

  test "pending tells new, changed, deleted and renamed files apart, offline", %{home: root} do
    write(root, "Changed.md", "edited")
    write(root, "New.md", "new")
    write(root, "Moved/There.md", "moved")
    write(root, "Same.md", "same")

    state = %{
      "entries" => %{
        "Changed.md" => entry(1, "original"),
        "Gone.md" => entry(2, "gone"),
        "Here.md" => entry(3, "moved"),
        "Same.md" => entry(4, "same")
      }
    }

    pending = Status.pending(state, Status.local(root))

    assert pending == %{
             new: ["New.md"],
             changed: ["Changed.md"],
             deleted: ["Gone.md"],
             renamed: [{"Here.md", "Moved/There.md"}]
           }

    assert Status.count(pending) == 4
  end

  describe "other sync tools" do
    test "Obsidian Sync, by its settings file or its core plugin switched on", %{home: root} do
      assert Status.other_tools(root) == []

      write(root, ".obsidian/core-plugins.json", ~s({"sync": false, "graph": true}))
      assert Status.other_tools(root) == []

      write(root, ".obsidian/core-plugins.json", ~s({"sync": true}))
      assert [{"Obsidian Sync", why}] = Status.other_tools(root)
      assert why =~ "core-plugins.json"

      write(root, ".obsidian/core-plugins.json", ~s(["file-explorer", "sync", "search"]))
      assert [{"Obsidian Sync", _}] = Status.other_tools(root)

      File.rm!(Path.join(root, ".obsidian/core-plugins.json"))
      write(root, ".obsidian/sync.json", "{}")
      assert [{"Obsidian Sync", ".obsidian/sync.json is there"}] = Status.other_tools(root)
    end

    test "Syncthing's marker above the folder, and Dropbox, iCloud and OneDrive by where it is",
         %{home: home} do
      write(home, ".stfolder/.keep", "")
      root = Path.join(home, "Vault")
      File.mkdir_p!(root)
      assert [{"Syncthing", _}] = Status.other_tools(root)

      dropbox = Path.join(home, "x/Dropbox/Notes")
      File.mkdir_p!(dropbox)
      assert {"Dropbox", _} = dropbox |> Status.other_tools() |> List.keyfind("Dropbox", 0)

      icloud = Path.join(home, "Library/Mobile Documents/iCloud~md~obsidian/Documents/V")
      File.mkdir_p!(icloud)
      assert List.keyfind(Status.other_tools(icloud), "iCloud Drive", 0)

      onedrive = Path.join(home, "OneDrive - Acme/Notes")
      File.mkdir_p!(onedrive)
      assert List.keyfind(Status.other_tools(onedrive), "OneDrive", 0)
    end

    test "the warning names them and says what to do" do
      assert Status.warning([]) == nil

      warning = Status.warning([{"Obsidian Sync", ".obsidian/sync.json is there"}])
      assert warning =~ "Obsidian Sync seems to be syncing this folder too"
      assert warning =~ "turn the other one off"
    end

    test "a pass says so on stderr, and still runs", %{home: home} do
      root = Path.join(home, "Vault")
      write(root, ".obsidian/sync.json", "{}")
      url = FakeServer.start([{200, ~s({"cursor":1,"entries":[]})}])
      State.save(root, State.new(url, %{"id" => 3, "name" => "Brain"}, "h"))

      err = capture_io(:stderr, fn -> capture_io(fn -> Sync.run("sync", [root], []) end) end)
      assert err =~ "Obsidian Sync seems to be syncing this folder too"
      assert_received {:request, "GET", "/api/vaults/3/sync?stubs=1", _}
    end
  end

  describe "the status command" do
    setup %{home: home} do
      root = Path.join(home, "Vault")
      write(root, "Note.md", "edited here")
      write(root, "Plan (conflict 2026-10-12 laptop).md", "mine")

      state = %{
        State.new("http://placeholder", %{"id" => 3, "name" => "Brain"}, "h")
        | "entries" => %{"Note.md" => entry(1, "as synced")},
          "conflicts" => [
            "Plan (conflict 2026-10-12 laptop).md",
            "Resolved (conflict 2026-10-11 laptop).md"
          ],
          "errors" => [
            %{"path" => "Other/x.md", "error" => "nothing in the vault is mapped at /Other"}
          ],
          "last_run" => DateTime.utc_now() |> DateTime.add(-300) |> DateTime.to_iso8601(),
          "last_result" => %{"sent" => 2, "received" => 0},
          "cursor" => 40
      }

      %{root: root, state: state}
    end

    test "reads the last run, both sides' waiting changes, conflicts and errors",
         %{root: root, state: state} do
      url =
        FakeServer.start([
          {200, ~s({"changes":[{"cursor":41},{"cursor":42}],"cursor":42,"more":false})}
        ])

      State.save(root, %{state | "url" => url})

      {out, err} =
        with_io(:stderr, fn -> capture_io(fn -> Sync.run("sync", ["status", root], []) end) end)

      assert_received {:request, "GET", "/api/vaults/3/changes?since=40", _}
      assert out =~ "Brain"
      assert out =~ "(5 min ago) — sent 2"
      # The conflict copy is new here too, so it is on its way up.
      assert out =~ "here: 2 changes waiting to be sent"
      assert out =~ "+ Plan (conflict 2026-10-12 laptop).md"
      assert out =~ "~ Note.md"
      assert out =~ "there: 2 changes waiting to come down"
      assert out =~ "conflicts: 1 unresolved"
      assert out =~ "! Plan (conflict 2026-10-12 laptop).md"
      refute out =~ "Resolved"
      assert err =~ "error last time: Other/x.md"
    end

    test "says when the server can't be asked, and when the cursor is too old",
         %{root: root, state: state} do
      url = FakeServer.start([{200, ~s({"changes":[],"cursor":90,"more":false,"resync":true})}])
      State.save(root, %{state | "url" => url})
      out = capture_io(fn -> Sync.run("sync", ["status", root], []) end)
      assert out =~ "lists the vault afresh"

      State.save(root, %{state | "url" => "http://127.0.0.1:1"})
      System.delete_env("SLIPDOCK_URL")
      out = capture_io(fn -> Sync.run("sync", ["status", root], []) end)
      assert out =~ "there: couldn't ask"
    end

    test "--json has it all for a program", %{root: root, state: state} do
      url = FakeServer.start([{200, ~s({"changes":[],"cursor":40,"more":false})}])
      State.save(root, %{state | "url" => url})
      out = capture_io(fn -> Sync.run("sync", ["status", root], json: true) end)
      {json, _, ""} = :json.decode(String.trim(out), :ok, %{null: nil})

      assert json["pending_here"]["changed"] == ["Note.md"]
      assert json["pending_there"] == %{"changes" => 0, "more" => false}
      assert json["conflicts"] == ["Plan (conflict 2026-10-12 laptop).md"]
      assert json["other_sync_tools"] == []
    end
  end

  test "a pass that wrote moves its cursor past its own writes", %{home: home} do
    root = Path.join(home, "Vault")
    write(root, "Note.md", "new")
    hash = sha("new")

    url =
      FakeServer.start([
        {200, ~s({"cursor":10,"entries":[]})},
        {200,
         ~s({"page":{"kind":"page","id":5,"path":"Note.md","hash":"#{hash}","content":"new"}})},
        {200, ~s({"changes":[],"cursor":11,"more":false})}
      ])

    State.save(root, State.new(url, %{"id" => 3, "name" => "Brain"}, "h"))
    capture_io(fn -> Sync.run("sync", [root], []) end)

    assert_received {:request, "PUT", "/api/vaults/3/sync/pages", _}
    assert_received {:request, "GET", "/api/vaults/3/changes", _}
    {:ok, state} = State.load(root)
    assert state["cursor"] == 11
  end

  test "the watcher runs a pass every ten minutes even with nothing to say" do
    w = Watch.new(%{}, 0)
    assert {:poll, w} = Watch.tick(w, %{}, 10_000)
    assert {:pass, w} = Watch.tick(w, %{}, 600_000)
    w = Watch.passed(w, %{}, 600_000)
    assert {:idle, _} = Watch.tick(w, %{}, 605_000)
  end
end
