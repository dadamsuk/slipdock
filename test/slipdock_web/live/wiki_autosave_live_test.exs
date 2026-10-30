defmodule SlipdockWeb.WikiAutosaveLiveTest do
  @moduledoc "The wiki's editor keeps unsaved work, and takes images on new pages (#1532)."
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, Wiki}
  alias Slipdock.Wiki.{Autosave, AutosaveFile, Autosaves}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup %{user: user} do
    uploads = Path.join(System.tmp_dir!(), "autosave-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(uploads)
    previous = Application.get_env(:slipdock, :uploads_dir)
    Application.put_env(:slipdock, :uploads_dir, uploads)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :uploads_dir, previous),
        else: Application.delete_env(:slipdock, :uploads_dir)

      File.rm_rf!(uploads)
    end)

    %{board: board_fixture(%{"name" => "Notes", "code" => "autosave9"}, owner: user)}
  end

  defp type(view, page), do: view |> form("#page-form", page: page) |> render_change()

  defp tick(view) do
    send(view.pid, :autosave)
    render(view)
  end

  defp paste(view, name \\ "shot.png") do
    view
    |> file_input("#page-form", :page_image, [
      %{name: name, content: @png, type: "image/png"}
    ])
    |> render_upload(name)

    render(view)
  end

  defp pasted_markdown(view) do
    assert_push_event(view, "image_uploaded", %{markdown: markdown})
    markdown
  end

  describe "a new page" do
    test "takes an image before it has been saved, and keeps it on Save", ctx do
      %{conn: conn, board: board, user: user} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")

      paste(view)
      markdown = pasted_markdown(view)
      assert markdown =~ "/autosave-files/"
      refute render(view) =~ "Save the page before"

      html = type(view, %{title: "Trip", body: "Look\n\n#{markdown}"})
      assert html =~ "/autosave-files/", "the preview shows the held image"

      view
      |> form("#page-form", page: %{title: "Trip", body: "Look\n\n#{markdown}"})
      |> render_submit()

      {:ok, page} = Wiki.find_page(board, "trip")
      assert [attachment] = Wiki.attachments(page)
      assert page.body =~ Slipdock.Boards.attachment_url(attachment)
      refute page.body =~ "/autosave-files/"
      assert Autosaves.on_board(user, board) == []
      assert Repo.aggregate(AutosaveFile, :count) == 0
    end

    test "comes back from the front of the wiki, where it was started", ctx do
      %{conn: conn, board: board} = ctx
      column = hd(Slipdock.Boards.get_board!(board.id).columns)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new?column=#{column.id}")
      type(view, %{title: "Half done", body: "Some words"})
      tick(view)
      assert has_element?(view, "#autosave-status", "Auto-saved")

      {:ok, index, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert has_element?(index, "#unsaved-pages a", "Half done")

      [autosave] = Repo.all(Autosave)
      {:ok, resumed, html} = live(conn, ~p"/boards/#{board}/wiki/new?autosave=#{autosave.id}")
      assert html =~ "Some words"
      assert has_element?(resumed, "#autosave-restored")
      assert html =~ column.name

      resumed
      |> form("#page-form", page: %{title: "Half done", body: "Finished"})
      |> render_submit()

      {:ok, page} = Wiki.find_page(board, "half-done")
      assert page.body == "Finished"
      assert Wiki.get_page!(page.id).column_id == column.id
      assert Repo.aggregate(Autosave, :count) == 0
    end

    test "someone else's auto-save opens as a blank page", ctx do
      %{conn: conn, board: board} = ctx
      other = user_fixture("someone@example.com")
      {:ok, theirs} = Autosaves.save(other, board, nil, nil, %{"body" => "secret words"}, nil)

      {:ok, view, html} = live(conn, ~p"/boards/#{board}/wiki/new?autosave=#{theirs.id}")

      refute html =~ "secret words"
      refute has_element?(view, "#autosave-restored")
    end

    test "a body typed before any title doesn't bring the editor down", ctx do
      %{conn: conn, board: board} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")

      assert type(view, %{title: "", body: "Words first"}) =~ "Words first"
      tick(view)

      assert [%Autosave{attrs: %{"body" => "Words first"}}] = Repo.all(Autosave)
    end

    test "a blank form leaves nothing behind", %{conn: conn, board: board} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")

      type(view, %{title: "", body: ""})
      tick(view)

      assert Repo.aggregate(Autosave, :count) == 0
    end

    test "Cancel throws it away, images too", ctx do
      %{conn: conn, board: board} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")
      paste(view)
      assert [file] = Repo.all(AutosaveFile)

      view |> element("button[phx-click=cancel_edit]") |> render_click()

      assert Repo.aggregate(Autosave, :count) == 0
      refute File.exists?(Autosaves.file_path(file))
    end

    test "Discard on the list lets one go", ctx do
      %{conn: conn, board: board, user: user} = ctx
      {:ok, autosave} = Autosaves.save(user, board, nil, nil, %{"title" => "Forget it"}, nil)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")

      view
      |> element("#unsaved-pages button[phx-value-id='#{autosave.id}']")
      |> render_click()

      refute has_element?(view, "#unsaved-pages")
      assert Repo.aggregate(Autosave, :count) == 0
    end

    test "a refused image says why and leaves the page writable", ctx do
      %{conn: conn, board: board} = ctx
      Application.put_env(:slipdock, :autosave_max_held_bytes, 1)
      on_exit(fn -> Application.delete_env(:slipdock, :autosave_max_held_bytes) end)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")

      assert paste(view) =~ "too many images"
      assert_push_event(view, "image_failed", %{upload: "page_image"})
      assert Repo.aggregate(AutosaveFile, :count) == 0
    end

    test "a held image lost before Save keeps the work and says so", ctx do
      %{conn: conn, board: board} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/new")
      paste(view)
      markdown = pasted_markdown(view)
      [file] = Repo.all(AutosaveFile)
      File.rm!(Autosaves.file_path(file))

      html =
        view
        |> form("#page-form", page: %{title: "Lost", body: markdown})
        |> render_submit()

      assert html =~ "couldn&#39;t be attached" or html =~ "couldn't be attached"
      assert {:error, :not_found, _} = Wiki.find_page(board, "lost")
      assert Repo.aggregate(Autosave, :count) == 1
    end
  end

  describe "editing a page" do
    setup %{board: board, user: user} do
      %{page: page_fixture(board, %{"title" => "Guide", "body" => "Original"}, user: user)}
    end

    test "comes back as it was left, and Save clears it", ctx do
      %{conn: conn, board: board, page: page} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      type(view, %{title: "Guide", body: "Original, and more"})
      tick(view)

      {:ok, again, html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      assert html =~ "Original, and more"
      assert has_element?(again, "#autosave-restored")

      again
      |> form("#page-form", page: %{title: "Guide", body: "Original, and more"})
      |> render_submit()

      assert Wiki.get_page!(page.id).body == "Original, and more"
      assert Repo.aggregate(Autosave, :count) == 0
    end

    test "typing nothing new writes nothing, and undoing the change clears it", ctx do
      %{conn: conn, board: board, page: page} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      type(view, %{title: "Guide", body: "Original"})
      tick(view)
      assert Repo.aggregate(Autosave, :count) == 0

      type(view, %{title: "Guide", body: "Changed"})
      tick(view)
      assert Repo.aggregate(Autosave, :count) == 1

      type(view, %{title: "Guide", body: "Original"})
      tick(view)
      assert Repo.aggregate(Autosave, :count) == 0
    end

    test "leaving for another page keeps what was waiting, on the right page", ctx do
      %{conn: conn, board: board, page: page, user: user} = ctx
      other = page_fixture(board, %{"title" => "Elsewhere"}, user: user)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      type(view, %{title: "Guide", body: "Not lost"})

      render_patch(view, ~p"/boards/#{board}/wiki/#{other.slug}")
      tick(view)

      assert Autosaves.for_page(user, page).attrs["body"] == "Not lost"
      refute Autosaves.for_page(user, other)
    end

    test "a restored edit still meets someone else's save", ctx do
      %{conn: conn, board: board, page: page, user: user} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      type(view, %{title: "Guide", body: "Mine"})
      tick(view)

      {:ok, _} = Wiki.update_page(Wiki.get_page!(page.id), %{"body" => "Theirs"}, user: user)

      {:ok, again, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      html =
        again
        |> form("#page-form", page: %{title: "Guide", body: "Mine"})
        |> render_submit()

      assert html =~ "This page changed while you were writing"
      assert Wiki.get_page!(page.id).body == "Theirs"
    end

    test "Discard starts again from the page", ctx do
      %{conn: conn, board: board, page: page} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      type(view, %{title: "Guide", body: "Second thoughts"})
      tick(view)
      {:ok, again, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      again |> element("#autosave-restored button") |> render_click()

      assert_redirect(again, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
      assert Repo.aggregate(Autosave, :count) == 0
    end

    test "a page's own images still attach at once", ctx do
      %{conn: conn, board: board, page: page} = ctx
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      paste(view)

      assert [_] = Wiki.attachments(page)
      assert Repo.aggregate(AutosaveFile, :count) == 0
    end
  end

  describe "the held file's address" do
    setup %{board: board, user: user} do
      {:ok, autosave} = Autosaves.save(user, board, nil, nil, %{}, nil)
      source = Path.join(System.tmp_dir!(), "held-#{System.unique_integer([:positive])}.png")
      File.write!(source, @png)
      on_exit(fn -> File.rm(source) end)
      meta = %{filename: "a.png", content_type: "image/png", size: byte_size(@png)}
      {:ok, file} = Autosaves.add_file(autosave, user, meta, source)
      %{held: file}
    end

    test "serves its writer, inline, unsniffed", %{conn: conn, held: file} do
      conn = get(conn, Autosaves.file_url(file))

      assert response(conn, 200) == @png
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["inline" <> _] = get_resp_header(conn, "content-disposition")
    end

    test "is a 404 to anyone else, and for nonsense", %{conn: conn, held: file} do
      assert conn |> get("/autosave-files/nonsense/a.png") |> response(404)

      other = user_fixture("reader@example.com")
      other_conn = log_in_user(Phoenix.ConnTest.build_conn(), other)
      assert other_conn |> get(Autosaves.file_url(file)) |> response(404)
    end

    test "is 404 once the file is gone", %{conn: conn, held: file} do
      File.rm!(Autosaves.file_path(file))
      assert conn |> get(Autosaves.file_url(file)) |> response(404)
    end
  end
end
