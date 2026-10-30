defmodule Slipdock.Wiki.AutosavesTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Wiki.{Autosave, AutosaveFile, Autosaves}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup do
    uploads = Path.join(System.tmp_dir!(), "autosaves-#{System.unique_integer([:positive])}")
    File.mkdir_p!(uploads)
    source = Path.join(uploads, "source.png")
    File.write!(source, @png)
    previous = Application.get_env(:slipdock, :uploads_dir)
    Application.put_env(:slipdock, :uploads_dir, uploads)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :uploads_dir, previous),
        else: Application.delete_env(:slipdock, :uploads_dir)

      File.rm_rf!(uploads)
    end)

    user = user_fixture()
    board = board_fixture(%{"name" => "Autosaves", "code" => "autosaves1"}, owner: user)
    %{user: user, board: board, source: source}
  end

  defp meta(name \\ "shot.png", type \\ "image/png"),
    do: %{filename: name, content_type: type, size: byte_size(@png)}

  defp new_autosave(user, board, attrs \\ %{"title" => "Draft"}) do
    {:ok, autosave} = Autosaves.save(user, board, nil, nil, attrs, nil)
    autosave
  end

  defp other_user, do: user_fixture("other#{System.unique_integer([:positive])}@example.com")

  describe "save/6" do
    test "an edit keeps one row a page, whatever the number of saves", %{user: user, board: board} do
      page = page_fixture(board, %{"title" => "One"})

      {:ok, first} = Autosaves.save(user, board, page, nil, %{"body" => "a"}, "hash1")
      {:ok, second} = Autosaves.save(user, board, page, nil, %{"body" => "b"}, "hash2")

      assert first.id == second.id

      assert %Autosave{attrs: %{"body" => "b"}, base_hash: "hash2"} =
               Autosaves.for_page(user, page)

      assert Repo.aggregate(Autosave, :count) == 1
    end

    test "two people's edits of a page stay apart", %{user: user, board: board} do
      page = page_fixture(board, %{"title" => "One"})
      other = other_user()

      {:ok, _} = Autosaves.save(user, board, page, nil, %{"body" => "mine"}, "h")
      {:ok, _} = Autosaves.save(other, board, page, nil, %{"body" => "theirs"}, "h")

      assert Autosaves.for_page(user, page).attrs["body"] == "mine"
      assert Autosaves.for_page(other, page).attrs["body"] == "theirs"
    end

    test "a new page's row is updated, and made again if it was discarded", ctx do
      %{user: user, board: board} = ctx
      autosave = new_autosave(user, board)

      {:ok, same} = Autosaves.save(user, board, nil, autosave, %{"title" => "Later"}, nil)
      assert same.id == autosave.id

      Autosaves.discard(same)
      {:ok, again} = Autosaves.save(user, board, nil, same, %{"title" => "Still typing"}, nil)
      assert Autosaves.get_new(user, board, again.id).attrs["title"] == "Still typing"
    end

    test "a page deleted under the editor answers an error, it doesn't raise", ctx do
      %{user: user, board: board} = ctx
      page = page_fixture(board, %{"title" => "Going"})
      Repo.delete!(page)

      assert {:error, _} = Autosaves.save(user, board, page, nil, %{"body" => "x"}, "h")
    end
  end

  describe "reading" do
    test "get_new/3 finds only your own, on that board, and only new pages", ctx do
      %{user: user, board: board} = ctx
      autosave = new_autosave(user, board)
      page = page_fixture(board, %{"title" => "One"})
      {:ok, edit} = Autosaves.save(user, board, page, nil, %{}, "h")
      elsewhere = board_fixture(%{"name" => "Else", "code" => "autosaves2"}, owner: user)

      assert Autosaves.get_new(user, board, autosave.id).id == autosave.id
      assert Autosaves.get_new(user, board, to_string(autosave.id))
      refute Autosaves.get_new(other_user(), board, autosave.id)
      refute Autosaves.get_new(user, elsewhere, autosave.id)
      refute Autosaves.get_new(user, board, edit.id)
      refute Autosaves.get_new(user, board, "nonsense")
    end

    test "on_board/2 lists one person's work on one board", ctx do
      %{user: user, board: board} = ctx
      autosave = new_autosave(user, board)
      new_autosave(other_user(), board)

      assert [%Autosave{id: id}] = Autosaves.on_board(user, board)
      assert id == autosave.id
    end
  end

  describe "held files" do
    test "are stored under autosaves/, and only their writer can reach them", ctx do
      %{user: user, board: board, source: source} = ctx
      autosave = new_autosave(user, board)

      {:ok, file} = Autosaves.add_file(autosave, user, meta(), source)

      assert String.starts_with?(file.key, "autosaves/#{autosave.id}/")
      assert File.read!(Autosaves.file_path(file)) == @png
      assert Autosaves.get_file(user, file.id).id == file.id
      refute Autosaves.get_file(other_user(), file.id)
      # Not an attachment, so nothing that reads attachments sees it.
      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "must be images: they are served inline", ctx do
      %{user: user, board: board, source: source} = ctx
      autosave = new_autosave(user, board)

      assert {:error, "That image could not be stored."} =
               Autosaves.add_file(autosave, user, meta("x.html", "text/html"), source)

      assert Repo.aggregate(AutosaveFile, :count) == 0
    end

    test "stop at what one person may hold", ctx do
      %{user: user, board: board, source: source} = ctx
      autosave = new_autosave(user, board)
      Application.put_env(:slipdock, :autosave_max_held_bytes, byte_size(@png))
      on_exit(fn -> Application.delete_env(:slipdock, :autosave_max_held_bytes) end)

      assert {:ok, _} = Autosaves.add_file(autosave, user, meta(), source)
      assert {:error, message} = Autosaves.add_file(autosave, user, meta(), source)
      assert message =~ "too many images"
    end

    test "discard/1 takes the row and the bytes", ctx do
      %{user: user, board: board, source: source} = ctx
      autosave = new_autosave(user, board)
      {:ok, file} = Autosaves.add_file(autosave, user, meta(), source)

      assert :ok = Autosaves.discard(autosave)

      refute File.exists?(Autosaves.file_path(file))
      assert Repo.aggregate(Autosave, :count) == 0
      assert :ok = Autosaves.discard(nil)
    end
  end

  describe "adopting into a new page" do
    test "attaches what the body shows, repoints it, and the first revision agrees", ctx do
      %{user: user, board: board, source: source} = ctx
      autosave = new_autosave(user, board)
      {:ok, kept} = Autosaves.add_file(autosave, user, meta("kept.png"), source)
      {:ok, dropped} = Autosaves.add_file(autosave, user, meta("dropped.png"), source)
      body = "Before ![kept](#{Autosaves.file_url(kept)}) after"

      {:ok, page} =
        Wiki.create_page(board, %{"title" => "With image", "body" => body},
          user: user,
          finish_body: &Autosaves.adopt(autosave, &1, &1.body)
        )

      assert [%Attachment{filename: "kept.png"} = attachment] = Wiki.attachments(page)
      assert page.body == "Before ![kept](#{Boards.attachment_url(attachment)}) after"
      refute page.body =~ "autosave-files"
      assert page.content_hash == Slipdock.Wiki.Page.hash(page.body)
      assert [revision] = Wiki.list_revisions(page)
      assert revision.body == page.body
      assert File.exists?(Boards.attachment_path(attachment))
      assert dropped.filename == "dropped.png"
    end

    test "a failure writes no page at all", ctx do
      %{user: user, board: board} = ctx
      before = Repo.aggregate(Slipdock.Wiki.Page, :count)

      assert {:error, {:finish_body, "no"}} =
               Wiki.create_page(board, %{"title" => "Refused", "body" => "x"},
                 user: user,
                 finish_body: fn _page -> {:error, "no"} end
               )

      assert Repo.aggregate(Slipdock.Wiki.Page, :count) == before
    end

    test "a held file that vanished refuses the save and leaves the work", ctx do
      %{user: user, board: board, source: source} = ctx
      autosave = new_autosave(user, board)
      {:ok, file} = Autosaves.add_file(autosave, user, meta(), source)
      File.rm!(Autosaves.file_path(file))

      assert {:error, {:finish_body, message}} =
               Wiki.create_page(
                 board,
                 %{"title" => "Lost", "body" => "![x](#{Autosaves.file_url(file)})"},
                 user: user,
                 finish_body: &Autosaves.adopt(autosave, &1, &1.body)
               )

      assert message =~ "shot.png"
      assert Autosaves.get_new(user, board, autosave.id)
    end
  end

  describe "letting go" do
    test "prune/1 takes what is older than the window, bytes and all", ctx do
      %{user: user, board: board, source: source} = ctx
      old = new_autosave(user, board)
      fresh = new_autosave(user, board)
      {:ok, file} = Autosaves.add_file(old, user, meta(), source)

      later = DateTime.add(DateTime.utc_now(), Autosaves.ttl_days() + 1, :day)
      future_fresh = DateTime.truncate(later, :second)
      Repo.update_all(Ecto.Query.where(Autosave, id: ^fresh.id), set: [updated_at: future_fresh])

      assert Autosaves.prune(later) == 1
      refute Autosaves.get_new(user, board, old.id)
      assert Autosaves.get_new(user, board, fresh.id)
      refute File.exists?(Autosaves.file_path(file))
    end

    test "deleting the board takes held files with it", ctx do
      %{user: user, source: source} = ctx
      board = board_fixture(%{"name" => "Gone", "code" => "autosaves3"}, owner: user)
      autosave = new_autosave(user, board)
      {:ok, file} = Autosaves.add_file(autosave, user, meta(), source)

      {:ok, _} = Boards.delete_board(board)

      refute File.exists?(Autosaves.file_path(file))
      assert Repo.aggregate(AutosaveFile, :count) == 0
    end

    test "deleting the account takes what they held on someone else's board", ctx do
      %{user: owner, board: board, source: source} = ctx
      writer = other_user()
      autosave = new_autosave(writer, board)
      {:ok, file} = Autosaves.add_file(autosave, writer, meta(), source)
      assert owner.id != writer.id

      assert Autosaves.user_keys(writer) == [file.key]
      assert {:ok, _} = Accounts.delete_user(writer)

      refute File.exists?(Autosaves.file_path(file))
    end
  end
end
