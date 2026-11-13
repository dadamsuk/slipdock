defmodule SlipdockWeb.PanelGrantLoweredLiveTest do
  @moduledoc """
  A panel open while its reader's grant is lowered refuses the write (#2771).

  The tags, archive, sprint, page and card panels each work out what their
  reader may do when the board hands them their assigns. Each test opens a
  panel as a writer, lowers the grant to read, and sends the panel's writes:
  whatever the panel still shows, nothing is stored.

  The grant is lowered two ways. `:told` is `Access.grant/4`, which tells the
  board. `:untold` changes the grant's row and tells nobody: it stands for a
  lowering the open board never hears of (a group's membership, a grant on
  the card a sub-board hangs from) and for an event that arrives before the
  board has taken the news in.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo, Sprints, Wiki}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.{Card, Tag}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Lowered"}, owner: owner)
    writer = user_fixture("writer@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)

    %{board: board, column: hd(board.columns), owner: owner, writer: writer}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp lower(how, ctx, board \\ nil, level \\ "read")

  defp lower(:told, ctx, board, level) do
    board = board || ctx.board
    {:ok, _} = Access.grant(board, ctx.writer, level, ctx.owner)
    assert Access.board_permission(ctx.writer, board) == String.to_existing_atom(level)
  end

  defp lower(:untold, ctx, board, level) do
    board = board || ctx.board

    assert {1, _} =
             Repo.update_all(
               from(g in Grant, where: g.board_id == ^board.id and g.user_id == ^ctx.writer.id),
               set: [level: level]
             )

    assert Access.board_permission(ctx.writer, board) == String.to_existing_atom(level)
  end

  for how <- [:told, :untold] do
    describe "the grant lowered to read, the board #{how}:" do
      test "the tags panel makes, renames, recolours and deletes nothing", ctx do
        tag = tag_fixture(ctx.board, "keep", "sky")
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/tags")
        assert has_element?(view, "#board-tags")

        lower(unquote(how), ctx)
        panel = with_target(view, "#board-tags")

        render_hook(panel, "create_tag", %{"tag" => %{"name" => "sneaked"}})
        render_hook(panel, "rename_tag", %{"tag_id" => "#{tag.id}", "name" => "renamed"})
        render_hook(panel, "set_tag_color", %{"id" => "#{tag.id}", "color" => "rose"})
        render_hook(panel, "delete_tag", %{"id" => "#{tag.id}"})

        assert [%Tag{name: "keep", color: "sky"}] = Repo.all(Tag)
        assert render(view) =~ "You have read-only access to this board."
      end

      test "the archive panel restores and deletes nothing", ctx do
        {:ok, gone} = Boards.Cards.archive_card(card_fixture(ctx.column, %{"title" => "Gone"}))

        {:ok, doomed} =
          Boards.Cards.archive_card(card_fixture(ctx.column, %{"title" => "Doomed"}))

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/archive")
        assert has_element?(view, "#archived-#{gone.id}")

        lower(unquote(how), ctx)
        panel = with_target(view, "#board-archive")

        render_hook(panel, "restore_card", %{"id" => "#{gone.id}"})
        assert Repo.get!(Card, gone.id).archived_at

        html = render_hook(panel, "delete_archived", %{"id" => "#{doomed.id}"})
        assert Repo.get!(Card, doomed.id).archived_at
        assert html =~ "You have read-only access to this board."

        # Looking is still reading.
        view |> element("#archive-search") |> render_change(%{"q" => "Doomed"})
        assert has_element?(view, "#archived-#{doomed.id}")
        refute has_element?(view, "#archived-#{gone.id}")
      end

      test "the sprint panel makes no sprint", ctx do
        sprints = sprint_board(ctx)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{sprints}")
        view |> element("#new-sprint") |> render_click()
        assert has_element?(view, "#new-sprint-form")

        lower(unquote(how), ctx, sprints)

        view
        |> with_target("#board-sprints")
        |> render_hook("create_sprint", %{"sprint" => %{"name" => "Sprint 1", "days" => "10"}})

        # A flash is the board's to show, so it is there on the next render.
        assert render(view) =~ "You have read-only access to this board."
        assert Repo.all(from(c in Card, where: c.board_id == ^sprints.id)) == []

        # Nor does it offer the form again.
        view |> with_target("#board-sprints") |> render_hook("close_new_sprint", %{})
        view |> with_target("#board-sprints") |> render_hook("open_new_sprint", %{})
        refute has_element?(view, "#new-sprint-form")
      end

      test "the sprint panel's open picker adds no card to the sprint", ctx do
        sprints = sprint_board(ctx)
        {:ok, sprint} = Sprints.create_sprint(sprints)

        # A board of the writer's own, so the card stays theirs to move.
        own = board_fixture(%{"name" => "Own work"}, owner: ctx.writer)
        mine = card_fixture(hd(own.columns), %{"title" => "Mine to move"})

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{sprints}")
        panel = with_target(view, "#board-sprints")
        render_hook(panel, "open_sprint_picker", %{"id" => "#{sprint.id}"})
        render_hook(panel, "plan_mode", %{"mode" => "browse"})
        render_hook(panel, "sprint_source", %{"id" => "#{own.id}"})
        view |> element("#sprint-pick-#{mine.id}") |> render_click()
        assert render(view) =~ "1 card ticked"

        lower(unquote(how), ctx, sprints)

        render_hook(panel, "sprint_add", %{})
        assert render(view) =~ "You have read-only access to that sprint."
        assert Repo.get!(Card, mine.id).board_id == own.id
      end

      test "the page panel changes nothing on the page", ctx do
        tag = tag_fixture(ctx.board, "keep")
        page = page_fixture(ctx.board, %{"title" => "Placed page"}, user: ctx.owner)
        {:ok, _} = Wiki.place(page, ctx.column)

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}?#{[page: page.id]}")
        assert has_element?(view, "#page-panel", "Placed page")

        lower(unquote(how), ctx)
        panel = with_target(view, "#board-page")

        html = render_hook(panel, "page_change", %{"page" => %{"title" => "Changed"}})
        assert html =~ "You have read-only access to that page."
        render_hook(panel, "page_toggle_flag", %{"flag" => "blocked"})
        render_hook(panel, "page_toggle_tag", %{"id" => "#{tag.id}"})
        render_hook(panel, "unplace_page", %{"id" => "#{page.id}"})
        # One of the events it shares with the card panel.
        render_hook(panel, "add_comment", %{"body" => "sneaked"})

        after_ = Repo.preload(Wiki.get_page!(page.id), :comments)
        assert after_.title == "Placed page"
        assert after_.flags == []
        assert after_.column_id == ctx.column.id
        assert after_.comments == []
        assert Wiki.tags(after_) == []
      end

      test "the card panel changes nothing on the card", ctx do
        card = card_fixture(ctx.column, %{"title" => "Open card"})
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/cards/#{card}")
        assert has_element?(view, "#card-modal", "Open card")

        lower(unquote(how), ctx)
        panel = with_target(view, "#board-card")

        html = render_hook(panel, "card_change", %{"card" => %{"title" => "Changed"}})
        assert html =~ "You have read-only access to this card."
        render_hook(panel, "toggle_flag", %{"flag" => "blocked"})
        render_hook(panel, "add_comment", %{"body" => "sneaked"})
        render_hook(panel, "share", %{"share" => %{"email" => "friend@example.com"}})
        render_hook(panel, "archive_card", %{})
        render_hook(panel, "delete_card", %{})

        after_ = Repo.preload(Repo.get!(Card, card.id), :comments)
        assert after_.title == "Open card"
        assert after_.flags == []
        assert after_.comments == []
        assert is_nil(after_.archived_at)
        assert Access.list_grants(after_) == []
      end

      test "the card panel stores no file that finishes uploading", ctx do
        card = card_fixture(ctx.column, %{"title" => "Open card"})
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/cards/#{card}")

        input =
          file_input(view, "#attach-form", :attachment, [
            %{name: "brief.pdf", content: "%PDF-1.4 fake", type: "application/pdf"}
          ])

        lower(unquote(how), ctx)
        render_upload(input, "brief.pdf")

        assert Boards.Cards.get_card!(card.id).attachments == []
      end
    end
  end

  describe "the grant lowered to comment, the board untold:" do
    test "the card panel still takes a comment, and no change to the card", ctx do
      card = card_fixture(ctx.column, %{"title" => "Open card"})
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/cards/#{card}")

      lower(:untold, ctx, ctx.board, "comment")
      panel = with_target(view, "#board-card")

      html = render_hook(panel, "card_change", %{"card" => %{"title" => "Changed"}})
      assert html =~ "You can comment on this card, but not change it."
      render_hook(panel, "add_comment", %{"body" => "still allowed"})

      after_ = Repo.preload(Repo.get!(Card, card.id), :comments)
      assert after_.title == "Open card"
      assert [%{body: "still allowed"}] = after_.comments
    end

    test "the page panel still takes a comment, and no change to the page", ctx do
      page = page_fixture(ctx.board, %{"title" => "Placed page"}, user: ctx.owner)
      {:ok, _} = Wiki.place(page, ctx.column)
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}?#{[page: page.id]}")

      lower(:untold, ctx, ctx.board, "comment")
      panel = with_target(view, "#board-page")

      html = render_hook(panel, "page_change", %{"page" => %{"title" => "Changed"}})
      assert html =~ "You have read-only access to that page."
      render_hook(panel, "add_comment", %{"body" => "still allowed"})

      after_ = Repo.preload(Wiki.get_page!(page.id), :comments)
      assert after_.title == "Placed page"
      assert [%{body: "still allowed"}] = after_.comments
    end
  end

  describe "the grant taken away, the board untold:" do
    test "the card panel changes nothing and shows the card no more", ctx do
      card = card_fixture(ctx.column, %{"title" => "Open card"})
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/cards/#{card}")

      Repo.delete_all(from(g in Grant, where: g.user_id == ^ctx.writer.id))
      assert Access.board_permission(ctx.writer, ctx.board) == :none

      panel = with_target(view, "#board-card")
      render_hook(panel, "card_change", %{"card" => %{"title" => "Changed"}})
      render_hook(panel, "add_comment", %{"body" => "sneaked"})

      after_ = Repo.preload(Repo.get!(Card, card.id), :comments)
      assert after_.title == "Open card"
      assert after_.comments == []
      refute has_element?(view, "#card-modal")
    end

    test "the page panel changes nothing and shows the page no more", ctx do
      page = page_fixture(ctx.board, %{"title" => "Placed page"}, user: ctx.owner)
      {:ok, _} = Wiki.place(page, ctx.column)
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}?#{[page: page.id]}")

      Repo.delete_all(from(g in Grant, where: g.user_id == ^ctx.writer.id))

      panel = with_target(view, "#board-page")
      render_hook(panel, "page_change", %{"page" => %{"title" => "Changed"}})
      render_hook(panel, "add_comment", %{"body" => "sneaked"})

      after_ = Repo.preload(Wiki.get_page!(page.id), :comments)
      assert after_.title == "Placed page"
      assert after_.comments == []
      refute has_element?(view, "#page-panel")
    end

    test "the archive panel searches nothing", ctx do
      {:ok, gone} = Boards.Cards.archive_card(card_fixture(ctx.column, %{"title" => "Gone"}))
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/archive")
      assert has_element?(view, "#archived-#{gone.id}")

      Repo.delete_all(from(g in Grant, where: g.user_id == ^ctx.writer.id))

      view
      |> with_target("#board-archive")
      |> render_hook("filter_archived", %{"q" => "Gone"})

      assert render(view) =~ "You don&#39;t have access to this board&#39;s archive."
      refute has_element?(view, "#archived-#{gone.id}")
    end
  end

  describe "a grant raised while the panel is open" do
    test "the tags panel takes the write", ctx do
      lower(:untold, ctx)
      {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}/tags")

      lower(:untold, ctx, ctx.board, "write")

      view
      |> with_target("#board-tags")
      |> render_hook("create_tag", %{"tag" => %{"name" => "allowed"}})

      assert [%Tag{name: "allowed"}] = Repo.all(Tag)
    end
  end

  defp sprint_board(ctx) do
    {:ok, template} = Boards.Templates.find_template(nil, "Sprint planning")
    sprints = board_fixture(%{"name" => "Sprints"}, template: template, owner: ctx.owner)
    {:ok, _} = Access.grant(sprints, ctx.writer, "write", ctx.owner)
    sprints
  end
end
