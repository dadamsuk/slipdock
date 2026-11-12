defmodule SlipdockWeb.WikiAutoOrganiseLiveTest do
  @moduledoc """
  A folder's Organise… in the wiki's tree (#791): the dialog's modes, its
  preview with a box per item, and filing what was left ticked.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.{Repo, Wiki}
  alias Slipdock.Wiki.{Folders, Page}

  # How long `render_async` waits for the AI call's task. Its default is
  # ExUnit's assert_receive_timeout, 1 s, which ran out once in a loaded full
  # run (#2870). Only a failure waits this long.
  @async_timeout 5_000

  setup %{user: user} do
    board = board_fixture(%{"name" => "Notes"}, owner: user)
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})
    {:ok, meetings} = Wiki.create_folder(board, %{"name" => "Meetings"})

    pages =
      for {title, iso} <- [{"Standup", "2026-10-12T09:00:00Z"}, {"Retro", "2026-09-30T09:00:00Z"}] do
        page = page_fixture(board, %{"title" => title})
        {:ok, page} = Wiki.file_page(page, inbox)
        {:ok, at, 0} = DateTime.from_iso8601(iso)
        Repo.update_all(from(p in Page, where: p.id == ^page.id), set: [inserted_at: at])
        page
      end

    %{board: board, inbox: inbox, meetings: meetings, pages: pages}
  end

  defp open_dialog(conn, board, folder) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    render_hook(view, "organise_folder", %{"id" => to_string(folder.id)})
    view
  end

  defp folder_of(page), do: Wiki.get_page!(page.id).folder_id

  test "by date, into a chosen parent, with the folders made", %{
    conn: conn,
    board: board,
    inbox: inbox,
    pages: [standup, retro]
  } do
    view = open_dialog(conn, board, inbox)
    assert has_element?(view, "#tree-prompt", "Organise “Inbox”")

    # The folder itself is the parent until another is picked.
    assert has_element?(view, "#organise-preview", "/Inbox/2026-10")

    view |> form("#organise-form", %{"mode" => "date", "parent" => "Meetings"}) |> render_change()
    assert has_element?(view, "#organise-preview li", "/Meetings/2026-10")
    assert has_element?(view, "#organise-preview li", "/Meetings/2026-09")
    assert has_element?(view, "#organise-confirm", "Organise 2 items")

    html = view |> element("#organise-confirm") |> render_click()
    assert html =~ "Organised 2 items, making 2 folders."
    refute has_element?(view, "#tree-prompt")

    {:ok, oct} = Folders.find(board, "Meetings/2026-10")
    {:ok, sept} = Folders.find(board, "Meetings/2026-09")
    assert folder_of(standup) == oct.id
    assert folder_of(retro) == sept.id
  end

  test "an unticked item stays where it is", %{
    conn: conn,
    board: board,
    inbox: inbox,
    pages: [standup, retro]
  } do
    view = open_dialog(conn, board, inbox)

    view
    |> form("#organise-preview", %{"include" => ["", "page:#{standup.id}"]})
    |> render_change()

    assert has_element?(view, "#organise-confirm", "Organise 1 item")
    view |> element("#organise-confirm") |> render_click()

    assert folder_of(standup) != inbox.id
    assert folder_of(retro) == inbox.id

    # Nothing ticked: the button is off.
    view = open_dialog(conn, board, inbox)
    view |> form("#organise-preview", %{"include" => [""]}) |> render_change()
    assert has_element?(view, "#organise-confirm[disabled]", "Organise 0 items")
  end

  test "an item that changed after the preview is left where it was, and said", %{
    conn: conn,
    board: board,
    inbox: inbox,
    pages: [standup, retro]
  } do
    view = open_dialog(conn, board, inbox)
    assert has_element?(view, "#organise-confirm", "Organise 2 items")

    {:ok, _} = Wiki.archive_page(retro)
    html = view |> element("#organise-confirm") |> render_click()

    assert html =~ "Organised 1 item"
    assert html =~ "Left where they were: “Retro” (it has changed since the plan was made)."
    assert folder_of(standup) != inbox.id
    assert folder_of(retro) == inbox.id
  end

  test "a bad parent is said, and a mode with nothing to do says so", %{
    conn: conn,
    board: board,
    inbox: inbox
  } do
    view = open_dialog(conn, board, inbox)

    view |> form("#organise-form", %{"parent" => "../up"}) |> render_change()
    assert has_element?(view, "#organise-error", "can't be called")
    assert has_element?(view, "#organise-confirm[disabled]")

    view |> form("#organise-form", %{"mode" => "tag"}) |> render_change()
    assert has_element?(view, "#organise-nothing", "Nothing here would move.")
  end

  test "AI suggestions wait for the button, then fill the preview", %{
    conn: conn,
    board: board,
    inbox: inbox,
    pages: [standup, retro]
  } do
    Slipdock.AIStub.reply_with(%{
      "moves" => [
        %{"id" => "p#{standup.id}", "folder" => "Meetings/Daily"},
        %{"id" => "p#{retro.id}", "folder" => "Retros"}
      ]
    })

    view = open_dialog(conn, board, inbox)
    view |> form("#organise-form", %{"mode" => "ai"}) |> render_change()
    refute has_element?(view, "#organise-preview")
    refute_received {:ai_request, _}

    view |> element("#organise-ask") |> render_click()
    render_async(view, @async_timeout)

    assert_received {:ai_request, %{"model" => "anthropic/claude-haiku-5.5"}}
    # "Retros" would be a new top-level folder, so it is not offered.
    assert has_element?(view, "#organise-preview li", "/Meetings/Daily")
    refute has_element?(view, "#organise-preview li", "/Retros")
    assert has_element?(view, "#organise-ask", "Ask again")

    view |> element("#organise-confirm") |> render_click()
    {:ok, daily} = Folders.find(board, "Meetings/Daily")
    assert folder_of(standup) == daily.id
    assert folder_of(retro) == inbox.id
  end

  test "the model's error is shown", %{conn: conn, board: board, inbox: inbox} do
    Slipdock.AIStub.reply_with("no json here")
    view = open_dialog(conn, board, inbox)
    view |> form("#organise-form", %{"mode" => "ai"}) |> render_change()
    view |> element("#organise-ask") |> render_click()
    render_async(view, @async_timeout)
    assert has_element?(view, "#organise-error", "JSON")
  end

  test "a folder that isn't there can't be organised", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
    assert render_hook(view, "organise_folder", %{"id" => "999999"}) =~ "can&#39;t be organised"
    refute has_element?(view, "#tree-prompt")
  end
end
