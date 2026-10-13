defmodule SlipdockCLI.SyncTest do
  @moduledoc """
  `slipdock sync` as a command: binding a folder, what it asks the server,
  what it prints, the state it leaves, the HTTP answers the engine is given,
  and the lock that keeps two passes off one folder. The refusals end in
  `System.halt/1`, so they are covered as the values the command halts on.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Sync}
  alias SlipdockCLI.Sync.{Import, Remote, State}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-sync-cmd-#{System.unique_integer([:positive])}")
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

  @vault ~s({"vault":{"id":3,"name":"Brain","mappings":[{"id":1,"path":"/","board":{"id":1,"code":"kb","name":"KnowledgeBase"},"folder":null}]}})
  @hash :crypto.hash(:sha256, "Back off.\n") |> Base.encode16(case: :lower)
  @listing ~s({"cursor":12,"entries":[{"kind":"page","id":7,"path":"Ops/Retry.md","hash":"#{@hash}"}]})
  @page ~s({"page":{"kind":"page","id":7,"path":"Ops/Retry.md","hash":"#{@hash}","content":"Back off.\\n"}})

  test "init binds a folder to a vault, records where, and brings the vault down", %{home: home} do
    url = FakeServer.start([{200, @vault}, {200, @listing}, {200, @page}])
    System.put_env("SLIPDOCK_URL", url)
    dir = Path.join(home, "Brain")

    out = capture_io(fn -> Sync.run("sync", ["init", dir], vault: "Brain") end)

    assert_received {:request, "GET", "/api/vaults/Brain", _}
    assert_received {:request, "GET", "/api/vaults/3/sync", _}
    assert_received {:request, "GET", "/api/vaults/3/sync/pages/7", _}

    assert out =~ "bound #{dir} to the vault"
    assert out =~ "↓ Ops/Retry.md"
    assert out =~ "received 1"
    assert File.read!(Path.join(dir, "Ops/Retry.md")) == "Back off.\n"

    {:ok, state} = State.load(dir)
    assert state["url"] == url
    assert state["vault"] == %{"id" => 3, "name" => "Brain"}
    assert state["cursor"] == 12
    assert state["entries"]["Ops/Retry.md"] == %{"id" => 7, "kind" => "page", "hash" => @hash}
    assert state["last_run"]
    # The lock is gone once the pass is over.
    refute File.exists?(Path.join([dir, ".slipdock", "lock"]))
  end

  test "init on a folder `vault import` sent up adopts it, then lets the record go",
       %{home: home} do
    url = FakeServer.start([{200, @vault}, {200, @listing}])
    System.put_env("SLIPDOCK_URL", url)
    dir = Path.join(home, "Obsidian")
    File.mkdir_p!(Path.join(dir, "Ops"))
    File.write!(Path.join(dir, "Ops/Retry.md"), "Back off.\n")

    Import.save_record(dir, %{
      "vault" => %{"id" => 3, "name" => "Brain"},
      "entries" => %{
        "Ops/Retry.md" => %{"kind" => "page", "id" => 7, "sha" => @hash, "hash" => @hash}
      }
    })

    out = capture_io(fn -> Sync.run("sync", ["init", dir], vault: "Brain") end)

    assert out =~ "adopting the 1 files"
    assert out =~ "sent 0, received 0"
    # Only the vault and its listing were asked for: nothing sent, nothing fetched.
    assert_received {:request, "GET", "/api/vaults/Brain", _}
    assert_received {:request, "GET", "/api/vaults/3/sync", _}
    refute_received {:request, _, _, _}
    {:ok, state} = State.load(dir)
    assert state["entries"]["Ops/Retry.md"]["id"] == 7
    refute File.exists?(Import.record_path(dir))
  end

  test "init refuses a folder that is already a mirror unless --force is given", %{home: home} do
    dir = Path.join(home, "Brain")
    refute Sync.refuse_reinit?(dir, vault: "Brain")

    State.save(dir, State.new("http://x", %{"id" => 3, "name" => "Brain"}, "host"))

    # --force left out entirely is nil: this used to raise on `not nil`.
    assert Sync.refuse_reinit?(dir, vault: "Brain")
    assert Sync.refuse_reinit?(dir, vault: "Brain", force: false)
    refute Sync.refuse_reinit?(dir, vault: "Brain", force: true)
  end

  test "init warns when the folder was imported into another vault", %{home: home} do
    System.put_env(
      "SLIPDOCK_URL",
      FakeServer.start([{200, @vault}, {200, @listing}, {200, @page}])
    )

    dir = Path.join(home, "Obsidian")
    Import.save_record(dir, %{"vault" => %{"id" => 99, "name" => "Old"}, "entries" => %{}})

    err =
      capture_io(:stderr, fn ->
        capture_io(fn -> Sync.run("sync", ["init", dir], vault: "Brain") end)
      end)

    assert err =~ "imported into Old, not Brain"
    # Another vault's record is not this one's to spend.
    assert File.exists?(Import.record_path(dir))
  end

  test "the import record is spent only by a pass with no errors", %{home: home} do
    dir = Path.join(home, "Obsidian")
    record = %{"vault" => %{"id" => 3}, "entries" => %{}}

    Import.save_record(dir, record)
    assert Import.spent(dir, %{}, [%{path: "A.md", error: "boom"}]) == :kept
    assert Import.spent(dir, nil, []) == :kept
    assert File.exists?(Import.record_path(dir))

    assert Import.spent(dir, %{}, []) == :dropped
    refute File.exists?(Import.record_path(dir))
  end

  test "a pass from a folder inside the mirror finds the mirror, and talks to its own server",
       %{home: home} do
    url = FakeServer.start([{200, @listing}])
    dir = Path.join(home, "Brain")
    File.mkdir_p!(Path.join(dir, "Ops"))
    File.write!(Path.join(dir, "Ops/Retry.md"), "Back off.\n")

    State.save(dir, %{
      State.new(url, %{"id" => 3, "name" => "Brain"}, "host")
      | "entries" => %{"Ops/Retry.md" => %{"id" => 7, "kind" => "page", "hash" => @hash}}
    })

    out = capture_io(fn -> Sync.run("sync", [Path.join(dir, "Ops")], json: true) end)

    assert_received {:request, "GET", "/api/vaults/3/sync", _}
    assert System.get_env("SLIPDOCK_URL") == url
    assert out =~ ~s("cursor": 12)
    assert out =~ ~s("sent": [])
  end

  test "a folder deleted on the server is removed here, and said so", %{home: home} do
    url = FakeServer.start([{200, ~s({"cursor":13,"entries":[],"folders":[]})}])
    dir = Path.join(home, "Brain")
    File.mkdir_p!(Path.join(dir, "Old"))

    State.save(
      dir,
      Map.put(State.new(url, %{"id" => 3, "name" => "Brain"}, "host"), "folders", ["Old"])
    )

    out = capture_io(fn -> Sync.run("sync", [dir], []) end)

    assert out =~ "✕ Old/"
    assert out =~ "deleted elsewhere, removed here"
    assert out =~ "removed 1"
    refute File.exists?(Path.join(dir, "Old"))
    {:ok, state} = State.load(dir)
    assert state["folders"] == []
  end

  test "State.find_root looks upwards, and says when there is no mirror", %{home: home} do
    dir = Path.join(home, "Brain")
    State.save(dir, State.new("http://x", %{"id" => 1, "name" => "B"}, "h"))
    File.mkdir_p!(Path.join(dir, "a/b"))

    assert State.find_root(Path.join(dir, "a/b")) == {:ok, dir}
    assert State.find_root(Path.join(home, "elsewhere")) == :error
  end

  test "a state file that can't be read says so rather than starting afresh", %{home: home} do
    dir = Path.join(home, "Broken")
    File.mkdir_p!(Path.join(dir, ".slipdock"))
    File.write!(State.path(dir), "{not json")
    assert State.load(dir) == {:error, :corrupt}
  end

  test "one pass at a time: a held lock refuses, a stale one is taken over", %{home: home} do
    lock = Path.join([home, ".slipdock", "lock"])
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "123")

    assert {:fail, msg} = Sync.with_lock(home, fn -> :ran end)
    assert msg =~ "another sync is running"

    File.touch!(lock, System.os_time(:second) - 3600)
    assert Sync.with_lock(home, fn -> :ran end) == :ran
    refute File.exists?(lock)
  end

  describe "the HTTP remote" do
    test "a 409 is a conflict carrying the file as it stands" do
      current = ~s({"error":"conflict","current":{"id":7,"path":"A.md","hash":"h","content":"c"}})
      System.put_env("SLIPDOCK_URL", FakeServer.start([{409, current}]))

      assert {:conflict, %{"id" => 7, "content" => "c"}} =
               Remote.write(3, 7, %{"path" => "A.md", "content" => "x", "base" => "old"})

      assert_received {:request, "PUT", "/api/vaults/3/sync/pages/7", body}
      assert body =~ ~s("base":"old")
    end

    test "a new page is a PUT with no id; an archive sends its base in the query" do
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([{200, @page}, {200, ~s({"page":{"id":7,"archived":true}})}])
      )

      assert {:ok, %{"id" => 7}} =
               Remote.write(3, nil, %{"path" => "Ops/Retry.md", "content" => "x"})

      assert_received {:request, "PUT", "/api/vaults/3/sync/pages", _}

      assert {:ok, %{"archived" => true}} = Remote.archive(3, 7, "abc")
      assert_received {:request, "DELETE", "/api/vaults/3/sync/pages/7?base=abc", _}
    end

    test "a file's bytes stream to disk and come back as their hash; a 404 is an error",
         %{home: home} do
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([
          {200, "raw bytes"},
          {404, ~s({"error":"file 9 in this vault not found"})}
        ])
      )

      dest = Path.join(home, "dl")

      assert {:ok, hash} = Remote.read_file(3, 8, dest)
      assert File.read!(dest) == "raw bytes"
      assert hash == :crypto.hash(:sha256, "raw bytes") |> Base.encode16(case: :lower)
      assert_received {:request, "GET", "/api/vaults/3/sync/files/8", _}

      assert {:error, "file 9 in this vault not found (HTTP 404)"} = Remote.read_file(3, 9, dest)
    end

    test "a file goes up as multipart with its path and base; a move is a PATCH", %{home: home} do
      src = Path.join(home, "pic.png")
      File.write!(src, "PNGDATA")
      file = ~s({"file":{"kind":"file","id":4,"path":"Img/pic.png","hash":"h"}})

      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([{200, file}, {200, file}, {200, ~s({"file":{"id":4,"archived":true}})}])
      )

      assert {:ok, %{"id" => 4}} =
               Remote.write_file(3, 4, %{"path" => "Img/pic.png", "base" => "old"}, src)

      assert_received {:request, "POST", "/api/vaults/3/sync/files/4", body}
      assert body =~ ~s(name="path")
      assert body =~ "Img/pic.png"
      assert body =~ ~s(name="base")
      assert body =~ ~s(name="file"; filename="pic.png")
      assert body =~ "PNGDATA"

      assert {:ok, _} = Remote.move_file(3, 4, %{"path" => "b.png", "base" => "h"})
      assert_received {:request, "PATCH", "/api/vaults/3/sync/files/4", _}

      assert {:ok, %{"archived" => true}} = Remote.archive_file(3, 4, "h")
      assert_received {:request, "DELETE", "/api/vaults/3/sync/files/4?base=h", _}
    end

    test "errors come back as messages, and a 401 as :unauthorized" do
      System.put_env(
        "SLIPDOCK_URL",
        FakeServer.start([
          {422, ~s({"error":"nothing in the vault is mapped at /Other"})},
          {401, ~s({"error":"unauthorized"})}
        ])
      )

      assert {:error, "nothing in the vault is mapped at /Other (HTTP 422)"} =
               Remote.write(3, nil, %{"path" => "Other/x.md", "content" => "x"})

      assert {:error, :unauthorized} = Remote.list(3)
    end
  end
end
