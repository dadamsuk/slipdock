defmodule SlipdockWeb.AttachmentsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  # The card panel is a LiveComponent; what it is pushed goes to it.
  defp card_panel(view), do: with_target(view, "#board-card")

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Files board"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Spec card"})
    %{board: reload(board), card: card}
  end

  test "attaching a file from the card modal lists it, and it can be deleted", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    assert html =~ "Drop files here"

    input =
      file_input(view, "#attach-form", :attachment, [
        %{name: "brief.pdf", content: "%PDF-1.4 fake", type: "application/pdf"}
      ])

    render_upload(input, "brief.pdf")

    [a] = Boards.get_card!(card.id).attachments
    assert a.filename == "brief.pdf"
    assert a.content_type == "application/pdf"
    assert File.exists?(Boards.attachment_path(a))

    html = render(view)

    assert has_element?(
             view,
             "#attachment-#{a.id} a[href='/attachments/#{a.id}/brief.pdf']",
             "brief.pdf"
           )

    assert html =~ "Attachments"
    assert html =~ "(1)"
    # The board tile shows a paperclip count.
    assert has_element?(view, "#card-#{card.id} span[title='Attachments']", "1")

    view |> element("#attachment-#{a.id} button[phx-click=delete_attachment]") |> render_click()
    assert Boards.get_card!(card.id).attachments == []
    refute File.exists?(Boards.attachment_path(a))
    refute has_element?(view, "#attachment-#{a.id}")
  end

  test "a file that is too large is refused with a message", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    input =
      file_input(view, "#attach-form", :attachment, [
        %{
          name: "huge.bin",
          content: :binary.copy(<<0>>, Slipdock.Boards.Attachment.max_size() + 1),
          type: "application/octet-stream"
        }
      ])

    assert {:error, [[_, :too_large]]} = render_upload(input, "huge.bin")
    # In the browser the file input's change event follows straight away.
    render_change(card_panel(view), "validate_attachments", %{})
    assert render(view) =~ "huge.bin is too large"
    assert Boards.get_card!(card.id).attachments == []
  end

  test "an image pasted into the description is stored and handed back as Markdown", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    # An empty description shows a prompt; clicking it opens the editor.
    view |> element("button", "Add more detail…") |> render_click()
    assert has_element?(view, "#card-description-paste[data-upload=desc_image]")

    input =
      file_input(view, "#card-form", :desc_image, [
        %{name: "pasted-2026-09-25.png", content: @png, type: "image/png"}
      ])

    render_upload(input, "pasted-2026-09-25.png")
    [a] = Boards.get_card!(card.id).attachments
    assert a.content_type == "image/png"

    assert_push_event(view, "image_uploaded", %{upload: "desc_image", markdown: markdown})
    assert markdown == "![pasted-2026-09-25.png](/attachments/#{a.id}/pasted-2026-09-25.png)"

    # The hook inserts the Markdown; the form change saves it (placeholder stripped).
    view
    |> form("#card-form", %{
      "card" => %{
        "title" => "Spec card",
        "description" => "Look:\n![Uploading image…]()\n#{markdown}\n"
      }
    })
    |> render_change()

    assert Boards.get_card!(card.id).description == "Look:\n#{markdown}\n"

    view |> element(~s(button[phx-click="stop_editing_description"])) |> render_click()

    assert has_element?(
             view,
             "#card-description-view img[src='/attachments/#{a.id}/pasted-2026-09-25.png']"
           )

    refute has_element?(view, "#card-description")
    assert render(view) =~ "Look:"

    # Clicking the rendered text reopens the editor with the saved Markdown.
    view |> element("#card-description-view") |> render_click()
    assert view |> element("#card-description") |> render() =~ markdown
  end

  test "a non-image pasted into the description is refused", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    view |> element("button", "Add more detail…") |> render_click()

    input =
      file_input(view, "#card-form", :desc_image, [
        %{name: "notes.txt", content: "hi", type: "text/plain"}
      ])

    assert {:error, [[_, :not_accepted]]} = render_upload(input, "notes.txt")

    render_change(card_panel(view), "card_change", %{"card" => %{"title" => "Spec card"}})
    assert render(view) =~ "notes.txt isn&#39;t an image"

    assert_push_event(view, "image_failed", %{upload: "desc_image"})
  end

  test "an image pasted into a comment renders inline once the comment is posted", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

    input =
      file_input(view, "#add-comment-0", :comment_image, [
        %{name: "clip.png", content: @png, type: "image/png"}
      ])

    render_upload(input, "clip.png")
    assert_push_event(view, "image_uploaded", %{upload: "comment_image", markdown: markdown})

    view
    |> form("#add-comment-0", %{"body" => "Here it is #{markdown} ![Uploading image…]()"})
    |> render_submit()

    [comment] = Boards.get_card!(card.id).comments
    assert comment.body == "Here it is #{markdown}"
    assert has_element?(view, "#comment-#{comment.id} img[alt='clip.png']")
    assert render(view) =~ "Here it is"
  end

  test "editing the description keeps the sidebar fields, and vice versa", %{
    conn: conn,
    board: board,
    card: card
  } do
    {:ok, _} = Boards.update_card(card, %{"due_date" => "2030-01-15", "description" => "keep"})
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    view |> element("button", "Edit") |> render_click()

    view
    |> form("#card-form", %{"card" => %{"title" => "Spec card", "description" => "changed"}})
    |> render_change()

    assert %{description: "changed", due_date: ~D[2030-01-15]} = Boards.get_card!(card.id)

    view |> form("#card-meta-form", %{"card" => %{"priority" => "high"}}) |> render_change()

    assert %{description: "changed", due_date: ~D[2030-01-15], priority: "high"} =
             Boards.get_card!(card.id)
  end

  test "a read-only user sees the description and attachments but cannot change them", %{
    board: board,
    card: card,
    user: owner
  } do
    {:ok, _} = Boards.update_card(card, %{"description" => "Read me ![i](/attachments/1/i.png)"})
    reader = user_fixture("reader@example.com")
    {:ok, _} = Slipdock.Access.grant(board, reader, "read", owner)

    {:ok, view, html} = live(conn_as(reader), ~p"/boards/#{board}/cards/#{card.id}")
    assert html =~ "Read me"
    assert has_element?(view, "#card-description-view img[src='/attachments/1/i.png']")
    refute has_element?(view, "#attach-form")
    refute has_element?(view, "#add-comment-0")
    refute has_element?(view, "button", "Edit")

    render_click(card_panel(view), "edit_description", %{})
    assert render(view) =~ "read-only access to this card"
    refute has_element?(view, "#card-description")
  end
end
