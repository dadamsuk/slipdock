defmodule Slipdock.FileCleanupTest do
  @moduledoc """
  Deleting something deletes the files on disk that went with it — not only
  the rows. The database cascades take a card's subcards, a list's cards and
  a page's images by themselves; the bytes are left behind unless the delete
  gathers their keys first. Each case here also keeps a file that must stay.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Wiki}

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    src = Path.join(System.tmp_dir!(), "cleanup-#{System.unique_integer([:positive])}")
    File.write!(src, "bytes")
    on_exit(fn -> File.rm(src) end)

    board = board_fixture(%{"name" => "Cleanup"})
    {:ok, template} = Boards.Templates.find_template(nil, "Simple")
    %{board: board, column: hd(board.columns), src: src, template: template}
  end

  defp attach(%Slipdock.Wiki.Page{} = page, src, name) do
    {:ok, a} = Wiki.add_attachment(page, %{filename: name, content_type: "image/png"}, src)
    a
  end

  defp attach(card, src, name) do
    {:ok, a} =
      Boards.Attachments.add_attachment(card, %{filename: name, content_type: "text/plain"}, src)

    a
  end

  defp on_disk?(a), do: File.exists?(Boards.Attachments.attachment_path(a))

  # epic → its sub-board (a card, a page) → a deeper sub-board (a card).
  defp tree(%{column: column, src: src, template: t}) do
    epic = card_fixture(column, %{"title" => "Epic"})
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    child = card_fixture(hd(sub.columns), %{"title" => "Child"})
    page = page_fixture(sub, %{"title" => "Sub page"})
    {:ok, deeper} = sub_board(child, t)
    deeper = Boards.get_board!(deeper.id)
    grandchild = card_fixture(hd(deeper.columns), %{"title" => "Grandchild"})

    %{
      epic: epic,
      files: [
        attach(epic, src, "epic.txt"),
        attach(child, src, "child.txt"),
        attach(page, src, "page.png"),
        attach(grandchild, src, "grandchild.txt")
      ]
    }
  end

  test "deleting a card deletes its files and every file beneath it", ctx do
    %{epic: epic, files: files} = tree(ctx)
    bystander = attach(card_fixture(ctx.column, %{"title" => "Other"}), ctx.src, "keep.txt")
    assert Enum.all?(files, &on_disk?/1)

    {:ok, _} = Boards.Cards.delete_card(Boards.Cards.get_card!(epic.id))

    refute Enum.any?(files, &on_disk?/1)
    assert on_disk?(bystander)
  end

  test "deleting a list deletes its cards' files, archived ones and subtrees too", ctx do
    %{epic: _epic, files: files} = tree(ctx)
    archived = card_fixture(ctx.column, %{"title" => "Archived"})
    archived_file = attach(archived, ctx.src, "archived.txt")
    {:ok, _} = Boards.Cards.archive_card(archived)

    [_, other_column | _] = ctx.board.columns
    bystander = attach(card_fixture(other_column, %{"title" => "Elsewhere"}), ctx.src, "keep.txt")

    {:ok, _} = Boards.Columns.delete_column(ctx.column)

    refute Enum.any?([archived_file | files], &on_disk?/1)
    assert on_disk?(bystander)
  end

  test "deleting an empty list removes nothing", ctx do
    [_, other_column | _] = ctx.board.columns
    keep = attach(card_fixture(ctx.column, %{"title" => "Stays"}), ctx.src, "keep.txt")

    {:ok, _} = Boards.Columns.delete_column(other_column)
    assert on_disk?(keep)
  end

  test "deleting a page deletes its images, and no other page's", ctx do
    page = page_fixture(ctx.board, %{"title" => "Runbook"})
    other = page_fixture(ctx.board, %{"title" => "Other"})
    image = attach(page, ctx.src, "diagram.png")
    keep = attach(other, ctx.src, "keep.png")

    {:ok, _} = Wiki.delete_page(page)

    refute on_disk?(image)
    assert on_disk?(keep)
  end

  test "purging a folder deletes its pages' images", ctx do
    {:ok, folder} = Wiki.create_folder(ctx.board, %{"name" => "Old"})
    page = page_fixture(ctx.board, %{"title" => "Filed"})
    {:ok, _} = Wiki.file_page(page, folder)
    image = attach(page, ctx.src, "diagram.png")

    {:ok, _} = Wiki.delete_folder(folder, :purge)

    refute on_disk?(image)
  end

  test "card_file_keys/1 of no cards is nothing" do
    assert Boards.Attachments.card_file_keys([]) == []
  end

  test "storing a file survives another removal emptying the folder it goes in", %{src: src} do
    # Recordings share one folder, and removing the last one in it removes the
    # folder too; one stored at that moment must still land (#1102). The two
    # can't overlap since they share a lock (#2831; the lock's own tests are
    # below), so this checks the whole round trip rather than hunting the race
    # with a great many tries: each try is a turn at the lock, slow on a busy
    # machine.
    failures =
      1..8
      |> Enum.map(fn n ->
        Task.async(fn ->
          for i <- 1..25, key = "captures/race-#{n}-#{i}.wav", reduce: [] do
            acc ->
              case Boards.Attachments.put_file(src, key) do
                :ok ->
                  stored? = File.regular?(Path.join(Boards.Attachments.uploads_dir(), key))
                  Boards.Attachments.remove_files([key])
                  if stored?, do: acc, else: [{key, :missing} | acc]

                error ->
                  [{key, error} | acc]
              end
          end
        end)
      end)
      |> Enum.flat_map(&Task.await(&1, :infinity))

    assert failures == []
  end

  # Holds the folders' lock until it is let go, so the test can see what
  # waits for it. The function the lock runs waits in the lock's own
  # process. `release` lets it go and checks it went; `let_go` only lets it
  # go, and does nothing once it has, since a second `{:release, ref}` would
  # reach the lock after its function returned and be logged as an
  # unexpected message (#2968). A test that fails first still lets it go
  # when it exits, so the lock isn't left held for every store after it.
  defp hold_folders_lock do
    test = self()
    ref = make_ref()

    holder =
      Task.async(fn ->
        Boards.Attachments.Folders.run(fn ->
          send(test, {:held, ref, self()})

          receive do
            {:release, ^ref} -> :ok
          end
        end)
      end)

    assert_receive {:held, ^ref, lock}
    released = :atomics.new(1, [])

    let_go = fn ->
      if :atomics.compare_exchange(released, 1, 0, 1) == :ok, do: send(lock, {:release, ref})
      :ok
    end

    on_exit(let_go)

    release = fn ->
      let_go.()
      assert Task.await(holder) == :ok
    end

    %{lock: lock, release: release, let_go: let_go}
  end

  # Starts `fun` in a task and waits until it has asked for the lock `lock`
  # holds: its call is then in the lock's mailbox, behind the function
  # holding it, and can't go on until the lock is let go. It watches the
  # task's sends rather than sleeping a fixed while, so the lock is held
  # only as long as it takes to get there: every other async test's store
  # or removal waits for it meanwhile.
  defp queue_for_lock(lock, fun) do
    task =
      Task.async(fn ->
        receive do
          :go -> fun.()
        end
      end)

    pid = task.pid
    1 = :erlang.trace(pid, true, [:send])
    send(pid, :go)
    assert_receive {:trace, ^pid, :send, {:"$gen_call", _, {:run, _}}, ^lock}, 5_000
    task
  end

  test "a removal waits for the lock before taking an empty folder", %{src: src} do
    :ok = Boards.Attachments.put_file(src, "captures/last.wav")
    folder = Path.join(Boards.Attachments.uploads_dir(), "captures")
    %{lock: lock, release: release} = hold_folders_lock()

    removal =
      queue_for_lock(lock, fn -> Boards.Attachments.remove_files(["captures/last.wav"]) end)

    assert File.dir?(folder)

    release.()
    assert Task.await(removal) == :ok
    refute File.exists?(folder)
  end

  test "a store waits for the lock before making its folder", %{src: src} do
    folder = Path.join(Boards.Attachments.uploads_dir(), "captures")
    %{lock: lock, release: release} = hold_folders_lock()

    store = queue_for_lock(lock, fn -> Boards.Attachments.put_file(src, "captures/next.wav") end)
    refute File.exists?(folder)

    release.()
    assert Task.await(store) == :ok
    assert File.read!(Path.join(folder, "next.wav")) == "bytes"
  end

  test "a lock let go, and let go again as the test exits, gets one release" do
    %{release: release, let_go: let_go} = hold_folders_lock()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        release.()
        # What the test's exit does: nothing reaches the lock this time.
        let_go.()
        # A turn at the lock, so anything sent to it has been handled.
        assert Boards.Attachments.Folders.run(fn -> :done end) == :done
      end)

    refute log =~ "unexpected message"
  end

  test "a test's uploads folder can't be one a killed run left behind" do
    # The numbers start again in every run, so the folder is named for this
    # OS process too: a leftover of the same number belongs to another one.
    name = Path.basename(Boards.Attachments.uploads_dir())
    assert name =~ ~r/^slipdock-uploads-#{System.pid()}-\d+$/
  end

  test "a store leaves its file and nothing else in the folder", %{src: src} do
    folder = Path.join(Boards.Attachments.uploads_dir(), "captures")
    assert Boards.Attachments.put_file(src, "captures/one.wav") == :ok
    assert File.ls!(folder) == ["one.wav"]

    missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
    assert Boards.Attachments.put_file(missing, "captures/two.wav") == {:error, :enoent}
    assert File.ls!(folder) == ["one.wav"]
  end

  test "a store that can't be renamed into place says why and leaves no placeholder",
       %{src: src} do
    folder = Path.join(Boards.Attachments.uploads_dir(), "captures")
    # A folder standing where the file goes, with something in it.
    File.mkdir_p!(Path.join(folder, "taken.wav/inside"))

    assert {:error, _} = Boards.Attachments.put_file(src, "captures/taken.wav")
    assert File.ls!(folder) == ["taken.wav"]
  end

  test "storing a file that isn't there is still an error, not retried into success" do
    missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
    assert Boards.Attachments.put_file(missing, "captures/never.wav") == {:error, :enoent}
    refute File.exists?(Path.join(Boards.Attachments.uploads_dir(), "captures/never.wav"))
  end

  test "storing over a folder that is a file fails with the reason", %{src: src} do
    File.mkdir_p!(Boards.Attachments.uploads_dir())
    File.write!(Path.join(Boards.Attachments.uploads_dir(), "captures"), "not a folder")
    assert Boards.Attachments.put_file(src, "captures/x.wav") == {:error, :enotdir}
  end

  test "a file further up the path fails at once too, and is left alone", %{src: src} do
    blocker = Path.join(Boards.Attachments.uploads_dir(), "captures/2026")
    File.mkdir_p!(Path.dirname(blocker))
    File.write!(blocker, "not a folder")

    assert Boards.Attachments.put_file(src, "captures/2026/11/x.wav") == {:error, :enotdir}
    assert File.read!(blocker) == "not a folder"
  end

  test "a file at the top of the uploads folder needs no folder made", %{src: src} do
    assert Boards.Attachments.put_file(src, "top.wav") == :ok
    assert File.read!(Path.join(Boards.Attachments.uploads_dir(), "top.wav")) == "bytes"

    missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
    assert Boards.Attachments.put_file(missing, "gone.wav") == {:error, :enoent}
  end
end
