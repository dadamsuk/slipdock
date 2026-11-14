defmodule SlipdockWeb.RemainingGrantLoweredLiveTest do
  @moduledoc """
  The pages and components #2998 left unprobed, each sent one gated event
  after its reader's level is lowered: nothing is stored (#2999).

  The assistant's chat, the inbound addresses dialog, Shared with me, the
  drawing editor, a Tool's page, My work, the skill registry, the list of
  boards, a job's log, the move-to-another-board picker and the wiki's page
  tools. `PublicLive.Show` has no case: it has no event that writes.

  The level is lowered two ways, as in `PanelGrantLoweredLiveTest`. `:told`
  is `Access.grant/4`, which tells whoever listens. `:untold` changes the
  row (`Repo.update_all`) and tells nobody: a lowering the open page never
  hears of, or an event that arrives before it has taken the news in.

  What gates on write is lowered on the grant's row. What gates on owner is
  lowered on `boards.owner_id`: a grant stops at write, and the struct an
  open page kept goes on naming its old owner.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Access, AIStub, Boards, Repo, Runners, SkillRegistry, TestConfig, Tools, Wiki}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Inbound.Token
  alias Slipdock.Runners.{Job, Transcript}
  alias Slipdock.SkillRegistry.Enablement
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.BoardLive.JobLogComponent

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Lowered"}, owner: owner)
    writer = user_fixture("writer@example.com")
    successor = user_fixture("successor@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)

    %{board: board, column: hd(board.columns), owner: owner, writer: writer, successor: successor}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp lower(how, ctx, board \\ nil)

  defp lower(:told, ctx, board) do
    board = board || ctx.board
    {:ok, _} = Access.grant(board, ctx.writer, "read", ctx.owner)
    assert Access.board_permission(ctx.writer, board) == :read
  end

  defp lower(:untold, ctx, board) do
    board = board || ctx.board

    assert {1, _} =
             Repo.update_all(
               from(g in Grant, where: g.board_id == ^board.id and g.user_id == ^ctx.writer.id),
               set: [level: "read"]
             )

    assert Access.board_permission(ctx.writer, board) == :read
  end

  # The board is somebody else's: its row names the successor. Told, the
  # board's open pages hear of it.
  defp hand_over(how, ctx, board \\ nil) do
    board = board || ctx.board

    assert {1, _} =
             Repo.update_all(from(b in Board, where: b.id == ^board.id),
               set: [owner_id: ctx.successor.id]
             )

    if how == :told, do: Boards.PubSub.broadcast(board.id)
    assert Access.board_permission(ctx.owner, Repo.get!(Board, board.id)) == :none
  end

  # An event for a component, by its button when the page still draws one
  # and to the component itself when it doesn't: told, a page takes the
  # button away, and an event can be sent without one.
  defp push(view, target, event, params) do
    view |> with_target(target) |> render_hook(event, params)
    render(view)
  end

  defp cards(board),
    do: Repo.all(from(c in Card, where: c.board_id == ^board.id, order_by: c.id))

  for how <- [:told, :untold] do
    describe "the grant lowered to read, #{how}:" do
      test "the assistant's chat applies no proposal made while a writer", ctx do
        AIStub.reply_with(%{
          "reply" => "One card.",
          "actions" => [%{"type" => "create", "title" => "Sneaked"}]
        })

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")
        view |> element("#board-chat") |> render_click()
        view |> element("#page-ai button[phx-value-mode=edit]") |> render_click()
        view |> form("#page-ai-form-0", %{"message" => "Add a card"}) |> render_submit()
        assert render_async(view) =~ "Create “Sneaked”"

        [id] =
          view
          |> element("#page-ai button[phx-click=apply]")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("phx-value-id")

        lower(unquote(how), ctx)
        html = push(view, "#page-ai", "apply", %{"id" => id})

        assert cards(ctx.board) == []
        assert html =~ "read-only access"
      end

      test "the inbound addresses dialog rotates nothing", ctx do
        TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s"])
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")
        view |> element("#board-share-inbound") |> render_click()
        assert has_element?(view, "#board-inbound-rotate")
        before = Repo.all(from(t in Token, order_by: t.id))
        assert before != []

        lower(unquote(how), ctx)
        push(view, "#board-inbound", "rotate", %{})

        assert Repo.all(from(t in Token, order_by: t.id)) == before
      end

      test "a job's log is kept by nobody who only reads the card", ctx do
        card = card_fixture(ctx.column, %{"title" => "Fix it"})

        {:ok, runner, _} =
          Runners.create_runner(ctx.board, %{"name" => "laptop", "pool" => "dev"})

        {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
        Runners.claim(runner)

        {:ok, 1} =
          Transcript.append(
            runner,
            job.id,
            0,
            ~s({"type":"user","timestamp":"2026-11-06T12:13:05Z","message":{"content":"Work"}}\n)
          )

        {:ok, _} = Runners.finish(runner, job.id, %{exit: "0", status: "done"})

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/cards/#{card}")
        id = JobLogComponent.id("card", job.id)
        assert has_element?(view, "##{id}-keep")

        lower(unquote(how), ctx)
        html = push(view, "##{id}", "keep", %{})

        assert Repo.get!(Job, job.id).transcript_page_id == nil
        assert Repo.aggregate(Page, :count) == 0
        assert html =~ "Only someone who can edit the card can keep its log."
        refute has_element?(view, "##{id}-keep")
      end

      test "the move picker, open, moves no card off the board", ctx do
        to = board_fixture(%{"name" => "Errands"}, owner: ctx.owner)
        {:ok, _} = Access.grant(to, ctx.writer, "write", ctx.owner)
        card = card_fixture(ctx.column, %{"title" => "Call the printers"})

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")

        view
        |> element("#move-menu-#{card.id} button[phx-click=open_move_board]")
        |> render_click()

        view
        |> element("button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
        |> render_click()

        lower(unquote(how), ctx)
        html = push(view, "#board-move", "move_card_board", %{"column" => "#{hd(to.columns).id}"})

        assert Repo.get!(Card, card.id).board_id == ctx.board.id
        assert html =~ "You have read-only access to that card."
      end

      test "the wiki's page tools make no card", ctx do
        {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Launch", "body" => "Ring them."})
        AIStub.reply_with(%{"actions" => ["Book the hall"]})

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/wiki/#{page.slug}")
        view |> element("#page-tools-toggle") |> render_click()
        view |> element("#page-tool-actions") |> render_click()
        render_async(view)
        assert has_element?(view, "#page-tools-card-0")

        lower(unquote(how), ctx)
        push(view, "#page-tools-#{page.id}", "make_card", %{"index" => "0"})

        assert cards(ctx.board) == []
        refute Wiki.get_page!(page.id).body =~ "Book the hall"
      end

      test "My work completes no card", ctx do
        card = card_fixture(ctx.column, %{"title" => "Mine"})
        {:ok, view, _} = live(as(ctx.writer), ~p"/work")

        lower(unquote(how), ctx)
        html = render_hook(view, "toggle_complete", %{"id" => "#{card.id}"})

        refute Repo.get!(Card, card.id).completed
        assert html =~ "You have read-only access to that card."
      end

      test "the skill registry enables nothing on the board", ctx do
        %{entry: entry} = skill_entry(ctx.writer)
        {:ok, view, _} = live(as(ctx.writer), ~p"/skills/entries/#{entry.id}")
        assert has_element?(view, "#skill-enable-board option", "Lowered")

        lower(unquote(how), ctx)

        html =
          render_hook(view, "enable", %{
            "board_id" => "#{ctx.board.id}",
            "hash" => entry.content_hash
          })

        assert Repo.aggregate(Enablement, :count) == 0
        assert html =~ "Only somebody who can write to Lowered changes its skills."
      end

      test "the drawing editor saves no stroke", ctx do
        drawing = drawing_fixture(ctx)
        {:ok, view, _} = live(as(ctx.writer), ~p"/drawings/page/#{drawing.id}")
        before = Repo.get!(Page, drawing.id).body

        lower(unquote(how), ctx)

        render_hook(view, "delta", %{
          "elements" => [
            %{"id" => "sneaked", "type" => "rectangle", "version" => 9, "versionNonce" => 7}
          ],
          "flush" => true
        })

        assert Repo.get!(Page, drawing.id).body == before
      end
    end

    describe "the board handed to somebody else, #{how}:" do
      test "the list of boards deletes and archives nothing", ctx do
        {:ok, view, _} = live(as(ctx.owner), ~p"/")

        hand_over(unquote(how), ctx)
        render_hook(view, "archive", %{"id" => "#{ctx.board.id}"})
        html = render_hook(view, "delete", %{"id" => "#{ctx.board.id}"})

        assert %Board{archived_at: nil} = Repo.get(Board, ctx.board.id)
        assert html =~ "Only the board&#39;s owner can do that."
      end

      test "the inbound addresses dialog rotates nothing", ctx do
        TestConfig.put(:inbound, domain: "in.example.com", secrets: ["s"])
        {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}")
        view |> element("#board-share-inbound") |> render_click()
        before = Repo.all(from(t in Token, order_by: t.id))
        assert before != []

        # Told, the board sends away a reader with no access left, and the
        # event finds no page to land on.
        Process.flag(:trap_exit, true)
        hand_over(unquote(how), ctx)

        try do
          view |> with_target("#board-inbound") |> render_hook("rotate", %{})
        catch
          :exit, _ -> :sent_away
        end

        assert Repo.all(from(t in Token, order_by: t.id)) == before
      end

      test "the skill registry enables nothing on the board", ctx do
        %{entry: entry} = skill_entry(ctx.owner)
        {:ok, view, _} = live(as(ctx.owner), ~p"/skills/entries/#{entry.id}")
        assert has_element?(view, "#skill-enable-board option", "Lowered")

        hand_over(unquote(how), ctx)

        render_hook(view, "enable", %{
          "board_id" => "#{ctx.board.id}",
          "hash" => entry.content_hash
        })

        assert Repo.aggregate(Enablement, :count) == 0
      end
    end

    describe "a share lowered to read, #{how}:" do
      setup ctx do
        {:ok, folder} = Wiki.create_folder(ctx.board, %{"name" => "Shared folder"})

        page =
          page_fixture(
            ctx.board,
            %{"title" => "Shared plan", "body" => "Nothing yet.", "folder_id" => folder.id},
            user: ctx.owner
          )

        %{folder: folder, page: page, sharee: user_fixture("sharee@example.com")}
      end

      defp lower_share(:told, ctx, item) do
        {:ok, _} = Access.grant(item, ctx.sharee, "read", ctx.owner)
      end

      defp lower_share(:untold, ctx, item) do
        field = if match?(%Page{}, item), do: :page_id, else: :folder_id

        assert {1, _} =
                 Repo.update_all(
                   from(g in Grant,
                     where: field(g, ^field) == ^item.id and g.user_id == ^ctx.sharee.id
                   ),
                   set: [level: "read"]
                 )
      end

      test "Shared with me saves nothing to the page", ctx do
        {:ok, _} = Access.grant(ctx.page, ctx.sharee, "write", ctx.owner)
        {:ok, view, _} = live(as(ctx.sharee), ~p"/shared/pages/#{ctx.page.id}/edit")
        assert has_element?(view, "#shared-edit-form")

        lower_share(unquote(how), ctx, ctx.page)
        assert Access.page_permission(ctx.sharee, Wiki.get_page!(ctx.page.id)) == :read
        render_hook(view, "save", %{"page" => %{"title" => "Sneaked", "body" => "Sneaked."}})

        assert %Page{title: "Shared plan", body: "Nothing yet."} = Wiki.get_page!(ctx.page.id)
        assert render(view) =~ "shared with you to read, not to change"
      end

      test "Shared with me stores no image that finishes uploading", ctx do
        TestConfig.own_uploads_dir()
        {:ok, _} = Access.grant(ctx.page, ctx.sharee, "write", ctx.owner)
        {:ok, view, _} = live(as(ctx.sharee), ~p"/shared/pages/#{ctx.page.id}/edit")

        input =
          file_input(view, "#shared-edit-form", :page_image, [
            %{name: "shot.png", content: <<137, 80, 78, 71, 13, 10, 26, 10>>, type: "image/png"}
          ])

        lower_share(unquote(how), ctx, ctx.page)

        # Told, the editor has gone with the write, and its input with it.
        if has_element?(view, "#shared-edit-form"), do: render_upload(input, "shot.png")

        assert Repo.aggregate(Slipdock.Boards.Attachment, :count) == 0
      end

      test "Shared with me makes nothing in the folder", ctx do
        {:ok, _} = Access.grant(ctx.folder, ctx.sharee, "write", ctx.owner)
        {:ok, view, _} = live(as(ctx.sharee), ~p"/shared/folders/#{ctx.folder.id}")
        assert has_element?(view, "#shared-new-page")
        pages = Repo.aggregate(Page, :count)
        folders = Repo.aggregate(Wiki.Folder, :count)

        lower_share(unquote(how), ctx, ctx.folder)
        render_hook(view, "new_page", %{"title" => "Sneaked"})
        render_hook(view, "new_folder", %{"name" => "Sneaked"})
        render_hook(view, "new_drawing", %{})

        assert Repo.aggregate(Page, :count) == pages
        assert Repo.aggregate(Wiki.Folder, :count) == folders
      end
    end
  end

  describe "a share taken away, untold:" do
    test "Shared with me makes nothing in the folder", ctx do
      {:ok, folder} = Wiki.create_folder(ctx.board, %{"name" => "Shared folder"})
      sharee = user_fixture("sharee@example.com")
      {:ok, _} = Access.grant(folder, sharee, "write", ctx.owner)
      # A view for each event: the first one sends its reader away.
      [one, two, three] =
        for _ <- 1..3 do
          {:ok, view, _} = live(as(sharee), ~p"/shared/folders/#{folder.id}")
          view
        end

      pages = Repo.aggregate(Page, :count)
      folders = Repo.aggregate(Wiki.Folder, :count)

      assert {1, _} = Repo.delete_all(from(g in Grant, where: g.folder_id == ^folder.id))

      for {view, event, params} <- [
            {one, "new_page", %{"title" => "Sneaked"}},
            {two, "new_folder", %{"name" => "Sneaked"}},
            {three, "new_drawing", %{}}
          ] do
        assert {:error, {:live_redirect, %{to: "/shared"}}} = render_hook(view, event, params)
      end

      assert Repo.aggregate(Page, :count) == pages
      assert Repo.aggregate(Wiki.Folder, :count) == folders
    end

    # Still a reader of the board, so not sent away, and no sharee any more,
    # so `Wiki.Sharing` has no rule for them: the page's own guard is all
    # there is.
    test "Shared with me makes nothing in the folder for somebody left reading its board", ctx do
      {:ok, folder} = Wiki.create_folder(ctx.board, %{"name" => "Shared folder"})
      sharee = user_fixture("sharee@example.com")
      {:ok, _} = Access.grant(ctx.board, sharee, "read", ctx.owner)
      {:ok, _} = Access.grant(folder, sharee, "write", ctx.owner)
      {:ok, view, _} = live(as(sharee), ~p"/shared/folders/#{folder.id}")
      assert has_element?(view, "#shared-new-page")
      pages = Repo.aggregate(Page, :count)
      folders = Repo.aggregate(Wiki.Folder, :count)

      assert {1, _} = Repo.delete_all(from(g in Grant, where: g.folder_id == ^folder.id))
      assert render_hook(view, "new_page", %{"title" => "Sneaked"}) =~ "to read, not to change"
      assert Repo.aggregate(Page, :count) == pages
      render_hook(view, "new_drawing", %{})
      assert Repo.aggregate(Page, :count) == pages
      render_hook(view, "new_folder", %{"name" => "Sneaked"})
      assert Repo.aggregate(Wiki.Folder, :count) == folders
    end

    test "Shared with me saves nothing to a page no longer shared, and shows it no more", ctx do
      page = page_fixture(ctx.board, %{"title" => "Shared plan", "body" => "Nothing yet."})
      sharee = user_fixture("sharee@example.com")
      {:ok, _} = Access.grant(page, sharee, "write", ctx.owner)
      {:ok, view, _} = live(as(sharee), ~p"/shared/pages/#{page.id}/edit")

      assert {1, _} = Repo.delete_all(from(g in Grant, where: g.page_id == ^page.id))

      # Sent away told why: gone's flash, not the save's refusal after it.
      assert {:error, {:live_redirect, %{to: "/shared"}}} =
               render_hook(view, "save", %{
                 "page" => %{"title" => "Sneaked", "body" => "Sneaked."}
               })

      assert assert_redirect(view, "/shared") == %{
               "error" => "That isn't shared with you, or not any more."
             }

      assert %Page{title: "Shared plan", body: "Nothing yet."} = Wiki.get_page!(page.id)
    end

    test "Shared with me stores no image that finishes uploading to a page no longer shared",
         ctx do
      TestConfig.own_uploads_dir()
      page = page_fixture(ctx.board, %{"title" => "Shared plan", "body" => "Nothing yet."})
      sharee = user_fixture("sharee@example.com")
      {:ok, _} = Access.grant(page, sharee, "write", ctx.owner)
      {:ok, view, _} = live(as(sharee), ~p"/shared/pages/#{page.id}/edit")

      input =
        file_input(view, "#shared-edit-form", :page_image, [
          %{name: "shot.png", content: <<137, 80, 78, 71, 13, 10, 26, 10>>, type: "image/png"}
        ])

      assert {1, _} = Repo.delete_all(from(g in Grant, where: g.page_id == ^page.id))

      sent_away = render_upload(input, "shot.png")
      assert {:error, {:live_redirect, %{to: "/shared"}}} = sent_away

      # The flash is read from the redirect `render_upload` returns, not with
      # `assert_redirect` (#3054): the redirect comes from the upload's
      # progress callback, and the test client can stop on the view's exit
      # before it posts the redirect message `assert_redirect` waits for.
      {:ok, _shared, html} = follow_redirect(sent_away, as(sharee), "/shared")
      assert html =~ "That isn&#39;t shared with you, or not any more."

      assert Repo.aggregate(Slipdock.Boards.Attachment, :count) == 0
    end

    test "the move picker moves no card onto a board its reader owned when they picked it", ctx do
      to = board_fixture(%{"name" => "Errands"}, owner: ctx.owner)
      card = card_fixture(ctx.column, %{"title" => "Call the printers"})
      {:ok, view, _} = live(as(ctx.owner), ~p"/boards/#{ctx.board}")

      view
      |> element("#move-menu-#{card.id} button[phx-click=open_move_board]")
      |> render_click()

      view
      |> element("button[phx-click=move_board_pick][phx-value-id='#{to.id}']")
      |> render_click()

      hand_over(:untold, ctx, to)
      html = push(view, "#board-move", "move_card_board", %{"column" => "#{hd(to.columns).id}"})

      assert Repo.get!(Card, card.id).board_id == ctx.board.id
      assert html =~ "You have read-only access to that board."
    end

    test "a Tool's page installs nothing for somebody it is no longer shared with", ctx do
      TestConfig.own_uploads_dir()
      {:ok, version} = Tools.publish(ctx.owner, package(unique_name()))
      {:ok, _} = Tools.share(ctx.owner, version.tool, ctx.writer)
      {:ok, view, _} = live(as(ctx.writer), ~p"/tools/#{version.tool.slug}")
      boards = Repo.aggregate(Board, :count)

      assert {1, _} = Repo.delete_all(from(g in Grant, where: g.tool_id == ^version.tool.id))
      render_hook(view, "install", %{})
      render_hook(view, "share", %{"email" => ctx.successor.email})

      assert Repo.aggregate(Board, :count) == boards
      assert Repo.aggregate(from(g in Grant, where: g.tool_id == ^version.tool.id), :count) == 0
    end
  end

  defp skill_entry(user) do
    Slipdock.SkillRegistryStub.start(%{})

    Slipdock.SkillRegistryStub.put("octo/skills", %{
      files: %{
        "grilling/SKILL.md" => "---\nname: grilling\ndescription: Asks.\n---\n\nAsk one.\n"
      }
    })

    {:ok, %{entries: [entry]}} = SkillRegistry.add_source(user, "https://github.com/octo/skills")
    %{entry: entry}
  end

  defp drawing_fixture(ctx) do
    drawing =
      page_fixture(
        ctx.board,
        %{
          "title" => "Plan",
          "file_name" => "Plan.excalidraw",
          "front_matter" => "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n",
          "body" => File.read!("test/support/fixtures/excalidraw/Sketch.excalidraw.md")
        },
        user: ctx.owner
      )

    settle_drawing_sessions([{:page, drawing.id}])
    drawing
  end
end
