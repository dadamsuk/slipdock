defmodule SlipdockWeb.SharedAutosaveLiveTest do
  @moduledoc "The shared-page editor keeps unsaved work, and takes images (#1534)."
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Settings, Wiki}
  alias Slipdock.Wiki.{Autosave, Autosaves}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup do
    uploads = Path.join(System.tmp_dir!(), "shared-auto-#{System.unique_integer([:positive])}")
    File.mkdir_p!(uploads)
    previous = Application.get_env(:slipdock, :uploads_dir)
    Application.put_env(:slipdock, :uploads_dir, uploads)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :uploads_dir, previous),
        else: Application.delete_env(:slipdock, :uploads_dir)

      File.rm_rf!(uploads)
    end)

    owner = user_fixture("autosave-owner@example.com")
    board = board_fixture(%{"name" => "Secret Board Name", "code" => "sharedauto"}, owner: owner)
    page = page_fixture(board, %{"title" => "Plan", "body" => "As it stands."}, user: owner)
    sharee = user_fixture("autosave-sharee@example.com")
    {:ok, _} = Access.grant(page, sharee, "write", owner)

    %{owner: owner, board: board, page: page, sharee: sharee, conn: conn_as(sharee)}
  end

  defp edit(c), do: live(c.conn, ~p"/shared/pages/#{c.page.id}/edit")

  defp type(view, title, body),
    do: view |> form("#shared-edit-form", page: %{title: title, body: body}) |> render_change()

  defp tick(view) do
    send(view.pid, :autosave)
    render(view)
  end

  defp save(view, title, body),
    do: view |> form("#shared-edit-form", page: %{title: title, body: body}) |> render_submit()

  defp autosave(c), do: Autosaves.for_page(c.sharee, c.page)

  describe "typing" do
    test "keeps the form, for this person only, and leaves the page alone", c do
      {:ok, view, _} = edit(c)
      refute has_element?(view, "#autosave-status")

      type(view, "Plan", "Half a thought")
      tick(view)

      assert has_element?(view, "#autosave-status", "Auto-saved")
      assert %Autosave{board_id: board_id} = saved = autosave(c)
      assert board_id == c.board.id
      assert saved.attrs["body"] == "Half a thought"
      assert saved.base_hash == c.page.content_hash
      assert Wiki.get_page!(c.page.id).body == "As it stands."
      assert Autosaves.for_page(c.owner, c.page) == nil
    end

    test "writes nothing for a form that still says what the page says", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "As it stands.")
      tick(view)

      assert autosave(c) == nil
      refute has_element?(view, "#autosave-status")
    end

    test "typed back to what the page says, the copy goes", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Other")
      tick(view)
      assert autosave(c)

      type(view, "Plan", "As it stands.")
      tick(view)
      assert autosave(c) == nil
    end

    test "is written on leaving the editor, before the timer", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Left in a hurry")

      render_patch(view, ~p"/shared/pages/#{c.page.id}")

      assert autosave(c).attrs["body"] == "Left in a hurry"
    end

    test "never keeps the upload placeholder", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Before\n![Uploading image…]()\nAfter")
      tick(view)

      assert autosave(c).attrs["body"] == "Before\nAfter"
    end

    test "keeps what the wiki's editor held in the same row", c do
      {:ok, _} =
        Autosaves.save(
          c.sharee,
          c.board,
          c.page,
          nil,
          %{"title" => "Plan", "summary" => "Kept"},
          c.page.content_hash
        )

      {:ok, view, _} = edit(c)
      type(view, "Plan", "New words")
      tick(view)

      assert %{"summary" => "Kept", "body" => "New words"} = autosave(c).attrs
    end

    test "a reader's form is ignored, even forged", c do
      reader = user_fixture("autosave-reader@example.com")
      {:ok, _} = Access.grant(c.page, reader, "read", c.owner)
      {:ok, view, _} = live(conn_as(reader), ~p"/shared/pages/#{c.page.id}")

      render_hook(view, "validate", %{"page" => %{"title" => "Plan", "body" => "Forged"}})
      send(view.pid, :autosave)
      render(view)

      assert Autosaves.for_page(reader, c.page) == nil
    end
  end

  describe "coming back" do
    test "restores the text, with a way to throw it away", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan renamed", "Half a thought")
      tick(view)

      {:ok, back, html} = edit(c)
      assert html =~ "Half a thought"
      assert html =~ "Plan renamed"
      assert has_element?(back, "#autosave-restored")

      {:ok, fresh, html} =
        back
        |> element("#autosave-restored button", "Discard it")
        |> render_click()
        |> follow_redirect(c.conn)

      assert html =~ "As it stands."
      refute html =~ "Half a thought"
      refute has_element?(fresh, "#autosave-restored")
      assert autosave(c) == nil
    end

    test "a change made since is still caught, and shown to merge", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "My version")
      tick(view)

      {:ok, _} = Wiki.update_page(c.page, %{"body" => "Their version"}, user: c.owner)

      {:ok, back, _} = edit(c)
      refute has_element?(back, "#shared-conflict")

      save(back, "Plan", "My version")
      assert has_element?(back, "#shared-conflict", "Their version")
      assert Wiki.get_page!(c.page.id).body == "Their version"
      assert autosave(c), "the work is kept until it is really saved"

      # Merged, and saved again: not a second conflict.
      save(back, "Plan", "Both versions")
      assert Wiki.get_page!(c.page.id).body == "Both versions"
      assert autosave(c) == nil
    end

    test "a conflict can be put away", c do
      {:ok, view, _} = edit(c)
      {:ok, _} = Wiki.update_page(c.page, %{"body" => "Their version"}, user: c.owner)
      save(view, "Plan", "Mine")

      view |> element("#shared-conflict button") |> render_click()
      refute has_element?(view, "#shared-conflict")
    end
  end

  describe "finishing" do
    test "Save writes the page and clears the copy", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Done now")
      tick(view)

      save(view, "Plan", "Done now")

      assert Wiki.get_page!(c.page.id).body == "Done now"
      assert autosave(c) == nil
    end

    test "Save with an upload still in the text leaves its placeholder out", c do
      {:ok, view, _} = edit(c)
      save(view, "Plan", "Words\n![Uploading image…]()\n")
      assert Wiki.get_page!(c.page.id).body == "Words\n"
    end

    test "Cancel throws it away, and what was waiting too", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Written")
      tick(view)
      type(view, "Plan", "Written and more")

      view |> element("button", "Cancel") |> render_click()
      assert_patch(view, ~p"/shared/pages/#{c.page.id}")

      assert autosave(c) == nil
      send(view.pid, :autosave)
      render(view)
      assert autosave(c) == nil
      assert Wiki.get_page!(c.page.id).body == "As it stands."
    end
  end

  describe "Unsaved work on Shared with me" do
    setup c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Half a thought")
      tick(view)
      :ok
    end

    test "lists it, and opens the shared editor, naming nothing of the board", c do
      {:ok, view, html} = live(c.conn, ~p"/shared")

      assert has_element?(view, "#unsaved-pages a", "Editing Plan")
      assert has_element?(view, ~s(#unsaved-pages a[href="/shared/pages/#{c.page.id}/edit"]))
      refute html =~ "Secret Board Name"
      refute html =~ "/boards/"
    end

    test "Discard takes it away", c do
      {:ok, view, _} = live(c.conn, ~p"/shared")
      view |> element("#unsaved-pages button", "Discard") |> render_click()

      refute has_element?(view, "#unsaved-pages")
      assert autosave(c) == nil
    end

    test "Discard can't reach anybody else's", c do
      {:ok, theirs} =
        Autosaves.save(c.owner, c.board, c.page, nil, %{"body" => "Theirs"}, "hash")

      {:ok, view, _} = live(c.conn, ~p"/shared")
      render_click(view, "discard_autosave", %{"id" => to_string(theirs.id)})

      assert Autosaves.for_page(c.owner, c.page)
      assert autosave(c)
    end

    test "goes live when the share does, and the copy is left for its expiry", c do
      {:ok, view, _} = live(c.conn, ~p"/shared")
      assert has_element?(view, "#unsaved-pages")

      [grant] = Access.list_grants(c.page)
      {:ok, _} = Access.revoke(grant)

      refute render(view) =~ "unsaved-pages"
      assert autosave(c)
    end

    test "leaves out a page cut to reading, or archived", c do
      {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
      assert Autosaves.shared_with(c.sharee) == []

      {:ok, _} = Access.grant(c.page, c.sharee, "write", c.owner)
      assert [_] = Autosaves.shared_with(c.sharee)

      {:ok, _} = Wiki.archive_page(c.page)
      assert Autosaves.shared_with(c.sharee) == []
    end

    test "a board's own writer finds theirs on the wiki, not here", c do
      {:ok, _} = Autosaves.save(c.owner, c.board, c.page, nil, %{"body" => "Mine"}, "hash")
      assert Autosaves.shared_with(c.owner) == []
    end
  end

  describe "a share changing under an open editor" do
    test "leaves what is being typed alone", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Still typing")
      tick(view)

      send(view.pid, {:shares_changed})
      render(view)

      refute has_element?(view, "#autosave-restored")
      assert has_element?(view, "#autosave-status")
    end

    test "cut to reading, it sends them to the page with the work kept", c do
      {:ok, view, _} = edit(c)
      type(view, "Plan", "Not lost")

      {:ok, _} = Access.grant(c.page, c.sharee, "read", c.owner)
      send(view.pid, {:shares_changed})

      assert_patch(view, ~p"/shared/pages/#{c.page.id}")
      assert autosave(c).attrs["body"] == "Not lost"
    end
  end

  describe "an image" do
    defp paste(view, content \\ @png) do
      view
      |> file_input("#shared-edit-form", :page_image, [
        %{name: "shot.png", content: content, type: "image/png"}
      ])
      |> render_upload("shot.png")
    end

    test "becomes an attachment its reader can open", c do
      {:ok, view, _} = edit(c)
      paste(view)

      assert_push_event(view, "image_uploaded", %{markdown: markdown, upload: "page_image"})
      assert [attachment] = Wiki.attachments(c.page)
      assert markdown =~ Slipdock.Boards.attachment_url(attachment)

      conn = get(c.conn, Slipdock.Boards.attachment_url(attachment))
      assert conn.status == 200
    end

    test "the board's storage being full says so, and takes its placeholder back", c do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
      {:ok, _} = Settings.update(%{"storage_limit_mb" => 1})
      {:ok, view, _} = edit(c)

      assert paste(view, :binary.copy("x", 2 * 1024 * 1024)) =~ "could not be stored"
      assert_push_event(view, "image_failed", %{upload: "page_image"})
      assert Wiki.attachments(c.page) == []
    end

    test "a file that isn't an image is dropped, so the page can still be saved", c do
      {:ok, view, _} = edit(c)

      view
      |> file_input("#shared-edit-form", :page_image, [
        %{name: "notes.txt", content: "words", type: "text/plain"}
      ])
      |> render_upload("notes.txt")

      type(view, "Plan", "Words")
      assert render(view) =~ "notes.txt"
      assert_push_event(view, "image_failed", %{upload: "page_image"})

      save(view, "Plan", "Words")
      assert Wiki.get_page!(c.page.id).body == "Words"
    end
  end
end
