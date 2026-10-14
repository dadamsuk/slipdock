defmodule SlipdockWeb.MarkdownEditorLiveTest do
  @moduledoc """
  The Markdown editor (CodeMirror with a live preview) over a card's
  description, its comment box and a wiki page's body, from the server's
  side: each textarea sits in a `MarkdownEditor` wrapper LiveView leaves
  alone, keyed so another card or page starts a new editor, and the
  textarea is still the field the form sends. The browser's half is in
  assets/js/markdown_editor.test.js.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo, Wiki}

  defp card_panel(view), do: with_target(view, "#board-card")

  setup do
    board = board_fixture(%{"name" => "Editors"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Write it up"})
    %{board: reload(board), card: card}
  end

  describe "a card's description" do
    test "is edited in the Markdown editor, which LiveView leaves alone", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      refute has_element?(view, "[phx-hook=MarkdownEditor] #card-description")

      render_click(card_panel(view), "edit_description", %{})

      wrapper = "#card-description-editor-#{card.id}"
      assert has_element?(view, "#{wrapper}[phx-hook=MarkdownEditor][phx-update=ignore]")
      assert has_element?(view, "#{wrapper}[data-editor-class=md-editor-field]")
      # Escape still stops editing: the hook hands it back to this binding.
      assert has_element?(
               view,
               "#{wrapper} textarea#card-description[phx-keydown=stop_editing_description][phx-key=Escape]"
             )

      # Inside the paste and mention wrappers, which listen on themselves.
      assert has_element?(
               view,
               "#card-description-paste[phx-hook=PasteImage] #card-description-mention[phx-hook=Mention] #{wrapper}"
             )

      refute has_element?(view, "#card-description[phx-hook=AutoGrow]")
    end

    test "is still saved from the textarea the editor writes into", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      render_click(card_panel(view), "edit_description", %{})

      view
      |> form("#card-form", %{"card" => %{"description" => "## Plan\n\n- [ ] **ship** it"}})
      |> render_change()

      assert Boards.get_card!(card.id).description == "## Plan\n\n- [ ] **ship** it"
    end

    test "takes a photo over the old 10 MB limit", %{conn: conn, board: board, card: card} do
      Slipdock.TestConfig.own_uploads_dir()
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
      render_click(card_panel(view), "edit_description", %{})

      input =
        file_input(view, "#card-form", :desc_image, [
          %{name: "IMG_1234.jpg", content: :binary.copy("x", 11_000_000), type: "image/jpeg"}
        ])

      render_upload(input, "IMG_1234.jpg")

      assert_push_event(view, "image_uploaded", %{upload: "desc_image"})
      assert [%{size: 11_000_000}] = Boards.get_card!(card.id).attachments
    end

    test "is not given an editor for a reader", %{board: board, card: card, user: owner} do
      reader = user_fixture("reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", owner)

      {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board}/cards/#{card.id}")
      render_click(card_panel(view), "edit_description", %{})

      refute has_element?(view, "[phx-hook=MarkdownEditor]")
    end
  end

  describe "a card's comment box" do
    test "is a Markdown editor over a required textarea", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

      assert has_element?(
               view,
               "#add-comment-0 #comment-editor-0[phx-hook=MarkdownEditor][phx-update=ignore] textarea[name=body][required]"
             )
    end

    test "starts a fresh editor once a comment is posted", %{conn: conn, board: board, card: card} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

      view |> form("#add-comment-0", %{"body" => "Looks **good**"}) |> render_submit()

      assert [%{body: "Looks **good**"}] = Boards.get_card!(card.id).comments
      # The ignored wrapper would keep the posted text; a new id replaces it.
      refute has_element?(view, "#comment-editor-0")
      assert has_element?(view, "#comment-editor-1[phx-hook=MarkdownEditor] textarea[name=body]")
    end

    test "on a wiki page is keyed on the page", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Runbook", "body" => "Steps"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}")

      assert has_element?(
               view,
               "#comment-editor-0-page-#{page.id}[phx-hook=MarkdownEditor][phx-update=ignore] textarea[name=body]"
             )
    end
  end

  describe "a wiki page's body" do
    test "is edited in the Markdown editor, keyed on the page", %{conn: conn, board: board} do
      page = page_fixture(board, %{"title" => "Notes", "body" => "# Notes\n\nplain"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      wrapper = "#page-body-editor-#{page.id}"
      assert has_element?(view, "#{wrapper}[phx-hook=MarkdownEditor][phx-update=ignore]")
      assert has_element?(view, "#{wrapper}[data-editor-class=md-editor-page]")

      assert has_element?(
               view,
               "#page-body-paste[phx-hook=PasteImage] #{wrapper} textarea#page_body"
             )

      assert view |> element("#page_body") |> render() =~ "# Notes\n\nplain"
      # Meld's tools still find the body by its id.
      assert has_element?(view, "#meld-tools[data-textarea=page_body]")
    end

    test "a new page has an editor of its own, and saves what was written", %{
      conn: conn,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/new")

      assert has_element?(
               view,
               "#page-body-editor-new[phx-hook=MarkdownEditor] textarea#page_body"
             )

      view
      |> form("#page-form", page: %{title: "Deploys", body: "**Friday** _never_"})
      |> render_submit()

      assert {:ok, %{body: "**Friday** _never_"}} = Wiki.find_page(board, "deploys")
    end

    # LiveView won't submit a form whose upload holds an error, so an image
    # left there refused made the page impossible to save.
    for {kind, file, said} <- [
          {:too_large, %{name: "holiday photo.png", size: 1001, type: "image/png"},
           "holiday photo.png is too large"},
          {:not_accepted, %{name: "notes.txt", size: 2, type: "text/plain"},
           "notes.txt isn&#39;t an image"}
        ] do
      test "an image dropped in and refused (#{kind}) is taken out, and the page still saves",
           %{conn: conn, board: board, user: user} do
        Slipdock.TestConfig.own_uploads_dir()
        # The real limit is 50 MB; a small one shows the same refusal.
        Slipdock.TestConfig.put(:image_max_size, 1000)
        page = page_fixture(board, %{"title" => "Notes", "body" => "plain"}, user: user)
        {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")
        file = unquote(Macro.escape(file))

        input =
          file_input(view, "#page-form", :page_image, [
            %{name: file.name, content: :binary.copy("x", file.size), type: file.type}
          ])

        assert {:error, [[_, unquote(kind)]]} = render_upload(input, file.name)

        # In the browser the file input's change event follows straight away.
        view
        |> form("#page-form")
        |> render_change(page: %{title: "Notes", body: "plain ![Uploading image…]()"})

        # The flash comes by message, after the event: render again for it.
        assert render(view) =~ unquote(said)
        assert_push_event(view, "image_failed", %{upload: "page_image"})
        # Nothing is left in the upload for LiveView to hold the form back on.
        assert has_element?(view, "#page-form input[type=file][data-phx-active-refs='']")

        view
        |> form("#page-form", page: %{title: "Notes", body: "plain, and more"})
        |> render_submit()

        assert {:ok, %{body: "plain, and more"}} = Wiki.find_page(board, page.slug)
        assert Repo.all(Slipdock.Boards.Attachment) == []
      end
    end

    test "a photo over the old 10 MB limit is taken", %{conn: conn, board: board, user: user} do
      Slipdock.TestConfig.own_uploads_dir()
      page = page_fixture(board, %{"title" => "Trip", "body" => "photos"}, user: user)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/edit")

      input =
        file_input(view, "#page-form", :page_image, [
          %{name: "IMG_1234.jpg", content: :binary.copy("x", 11_000_000), type: "image/jpeg"}
        ])

      render_upload(input, "IMG_1234.jpg")

      assert_push_event(view, "image_uploaded", %{upload: "page_image", markdown: markdown})
      assert markdown =~ "IMG_1234.jpg"
      assert [%{size: 11_000_000}] = Wiki.attachments(page)
    end

    test "editing another page starts another editor", %{conn: conn, board: board} do
      one = page_fixture(board, %{"title" => "One", "body" => "first"})
      two = page_fixture(board, %{"title" => "Two", "body" => "second"})

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{one.slug}/edit")
      assert has_element?(view, "#page-body-editor-#{one.id}")

      # In place, as the tree does it: the ignored wrapper would otherwise
      # keep the first page's text under the second page's form.
      render_patch(view, ~p"/boards/#{board}/wiki/#{two.slug}/edit")
      refute has_element?(view, "#page-body-editor-#{one.id}")
      assert view |> element("#page-body-editor-#{two.id} textarea") |> render() =~ "second"
    end
  end
end
