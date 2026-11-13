defmodule SlipdockWeb.WikiGrantLoweredLiveTest do
  @moduledoc """
  The wiki's editor, used after its reader's grant is lowered, keeps
  nothing (#2998).

  `WikiLive.Drafts` gates the auto-save and a pasted image on `can_write`,
  and the page's Save on the same assign. The wiki reads its reader's level
  again before every event (`SlipdockWeb.LiveAccess`) and before it keeps a
  finished upload, which is no event. The grant is lowered told
  (`Access.grant/4`) and untold (the grant's row, telling nobody), as in
  `PagesGrantLoweredLiveTest`; the wiki doesn't listen for a board's
  grants, so it hears of neither.
  """
  # Sync: points the app's :uploads_dir at a temporary directory with
  # Application.put_env, which is the whole node's.
  use SlipdockWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Repo, Wiki}
  alias Slipdock.Access.Grant
  alias Slipdock.Wiki.{Autosave, AutosaveFile}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup %{user: owner} do
    uploads = Path.join(System.tmp_dir!(), "wiki-lowered-#{System.unique_integer([:positive])}")
    File.mkdir_p!(uploads)
    previous = Application.get_env(:slipdock, :uploads_dir)
    Application.put_env(:slipdock, :uploads_dir, uploads)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:slipdock, :uploads_dir, previous),
        else: Application.delete_env(:slipdock, :uploads_dir)

      File.rm_rf!(uploads)
    end)

    board = board_fixture(%{"name" => "Notes"}, owner: owner)
    writer = user_fixture("writer@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)
    page = page_fixture(board, %{"title" => "Guide", "body" => "Original"}, user: owner)

    %{board: board, owner: owner, writer: writer, page: page}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp grants(ctx),
    do: from(g in Grant, where: g.board_id == ^ctx.board.id and g.user_id == ^ctx.writer.id)

  defp lower(:told, ctx) do
    {:ok, _} = Access.grant(ctx.board, ctx.writer, "read", ctx.owner)
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp lower(:untold, ctx) do
    assert {1, _} = Repo.update_all(grants(ctx), set: [level: "read"])
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp edit(ctx) do
    {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}/edit")
    view
  end

  defp type(view, page), do: render_hook(view, "validate", %{"page" => page})

  defp tick(view) do
    send(view.pid, :autosave)
    render(view)
  end

  defp paste(view) do
    view
    |> file_input("#page-form", :page_image, [
      %{name: "shot.png", content: @png, type: "image/png"}
    ])
    |> render_upload("shot.png")
  end

  for how <- [:told, :untold] do
    describe "the grant lowered to read, the board #{how}:" do
      test "what is typed is not kept as an auto-save", ctx do
        view = edit(ctx)

        lower(unquote(how), ctx)
        type(view, %{"title" => "Guide", "body" => "Typed by a reader"})
        tick(view)

        assert Repo.aggregate(Autosave, :count) == 0
      end

      test "Save is refused and the page is as it was", ctx do
        view = edit(ctx)

        lower(unquote(how), ctx)

        assert render_hook(view, "save", %{
                 "page" => %{"title" => "Guide", "body" => "Saved by a reader"}
               }) =~ "You can&#39;t write on this board."

        assert Wiki.get_page!(ctx.page.id).body == "Original"
      end

      test "a pasted image is not kept on the page", ctx do
        view = edit(ctx)

        lower(unquote(how), ctx)
        paste(view)

        assert_push_event(view, "image_failed", %{upload: "page_image"})
        assert render(view) =~ "You can&#39;t write on this board."
        assert Wiki.attachments(ctx.page) == []
        assert Repo.aggregate(AutosaveFile, :count) == 0
      end
    end
  end

  test "the grant removed, nobody told: an event sends the reader away", ctx do
    # The view stops when it sends its reader away.
    Process.flag(:trap_exit, true)
    view = edit(ctx)

    assert {1, _} = Repo.delete_all(grants(ctx))

    assert {:error, {:live_redirect, %{to: "/"}}} =
             type(view, %{"title" => "Guide", "body" => "Typed by nobody"})

    assert Repo.aggregate(Autosave, :count) == 0
  end

  test "the grant removed, nobody told: a pasted image is not kept", ctx do
    view = edit(ctx)

    assert {1, _} = Repo.delete_all(grants(ctx))
    paste(view)

    assert_push_event(view, "image_failed", %{upload: "page_image"})
    assert Wiki.attachments(ctx.page) == []
  end

  test "a share on the open page keeps its reader commenting", ctx do
    {:ok, _} = Access.grant(ctx.page, ctx.writer, "comment", ctx.owner)
    view = edit(ctx)

    lower(:untold, ctx)
    type(view, %{"title" => "Guide", "body" => "Typed by a reader"})

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.perm == :read
    refute assigns.can_write
    assert assigns.can_comment
  end

  test "the board handed to another owner, nobody told: the wiki stops managing", ctx do
    successor = user_fixture("successor@example.com")
    {:ok, _} = Access.grant(ctx.board, ctx.owner, "write", ctx.owner)
    {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}/edit")
    assert :sys.get_state(view.pid).socket.assigns.can_manage

    assert {1, _} =
             Repo.update_all(from(b in Slipdock.Boards.Board, where: b.id == ^ctx.board.id),
               set: [owner_id: successor.id]
             )

    render_hook(view, "validate", %{"page" => %{"title" => "Guide", "body" => "Original"}})

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.perm == :write
    assert assigns.can_write
    refute assigns.can_manage
  end

  test "a writer who was never lowered still has it all kept", ctx do
    view = edit(ctx)

    type(view, %{"title" => "Guide", "body" => "Typed by a writer"})
    tick(view)
    assert Repo.aggregate(Autosave, :count) == 1

    paste(view)
    assert_push_event(view, "image_uploaded", %{markdown: _})
    assert [_] = Wiki.attachments(ctx.page)
  end
end
