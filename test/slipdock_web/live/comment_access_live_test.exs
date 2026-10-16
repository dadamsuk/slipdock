defmodule SlipdockWeb.CommentAccessLiveTest do
  @moduledoc """
  The comment level in the browser (#863): sharing offers it, and somebody
  holding it gets a card (or page) whose discussion — comments, status
  updates, votes — is live while everything else stays read-only, on the
  screen and in what the server will do.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Wiki}

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Talk", "code" => "talk863"}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Discuss me"})
    commenter = user_fixture("live.commenter@example.com")
    {:ok, _} = Access.grant(board, commenter, "read", owner)
    %{board: board, card: card, commenter: commenter}
  end

  defp card_panel(view), do: with_target(view, "#board-card")

  test "the card's share form offers View · Comment · Edit, and a comment grant says so", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    options =
      view
      |> element("form[id^=share-card] select[name=level]")
      |> render()
      |> then(&Regex.scan(~r/<option value="(\w+)"/, &1, capture: :all_but_first))
      |> List.flatten()

    assert options == ["read", "comment", "write"]

    view
    |> form("form[id^=share-card]", %{"email" => ctx.commenter.email, "level" => "comment"})
    |> render_submit()

    assert [%{level: "comment"} = grant] = Access.list_grants(ctx.card)
    assert has_element?(view, "#grant-card-#{grant.id}", "can comment")
    assert Access.card_permission(ctx.commenter, ctx.card) == :comment
  end

  describe "a card commenter" do
    setup ctx do
      {:ok, _} = Access.grant(ctx.card, ctx.commenter, "comment", ctx.user)

      {:ok, view, html} =
        live(conn_as(ctx.commenter), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      %{view: view, html: html}
    end

    test "sees the discussion live and the card's fields locked", %{view: view, html: html} do
      assert html =~ "You can comment on this card, but not change it."

      # The card's own fields sit in a disabled fieldset…
      assert has_element?(view, "#card-modal fieldset[disabled] #card-meta-form")
      # …the comment box, status form and votes in live ones.
      assert has_element?(
               view,
               "#card-modal fieldset:not([disabled]) form[phx-submit=add_comment]"
             )

      assert has_element?(
               view,
               "#card-modal fieldset:not([disabled]) form[phx-submit=add_status_update]"
             )

      assert has_element?(view, "#card-modal fieldset:not([disabled]) button[phx-click=vote]")
      # Pasting an image would attach it to the card: not offered.
      refute has_element?(view, "#card-modal [data-upload=comment_image][phx-hook]")
      # Nor sharing: that is the owner's or an editor's.
      refute has_element?(view, "form[id^=share-card]")
    end

    test "comments, reports a status and votes", ctx do
      render_submit(card_panel(ctx.view), "add_comment", %{"body" => "My two cents"})
      render_submit(card_panel(ctx.view), "add_status_update", %{"health" => "at_risk"})
      render_click(card_panel(ctx.view), "vote", %{"count" => "1"})

      card = Boards.get_card!(ctx.card.id)
      assert [%{body: "My two cents"}] = card.comments
      assert [%{health: "at_risk"}] = card.status_updates
      assert Slipdock.Votes.mine(card, ctx.commenter) == 1
    end

    test "is refused every change to the card itself", ctx do
      panel = card_panel(ctx.view)

      assert render_change(panel, "card_change", %{"card" => %{"title" => "Mine now"}}) =~
               "You can comment on this card, but not change it."

      render_click(panel, "toggle_flag", %{"flag" => "blocked"})
      render_submit(panel, "add_check", %{"text" => "Sneaky step"})
      render_click(panel, "archive_card", %{})

      card = Boards.get_card!(ctx.card.id)
      assert card.title == "Discuss me"
      assert card.flags in [nil, []]
      assert card.checklist_items == []
      assert is_nil(card.archived_at)
    end

    test "takes back their own comment and nobody else's", ctx do
      {:ok, mine} = Boards.add_comment(ctx.card, "Mine", by: ctx.commenter)
      {:ok, theirs} = Boards.add_comment(ctx.card, "Theirs", by: ctx.user)
      {:ok, view, _} = live(conn_as(ctx.commenter), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      assert has_element?(view, "#comment-#{mine.id} button[phx-click=delete_comment]")
      refute has_element?(view, "#comment-#{theirs.id} button[phx-click=delete_comment]")

      render_click(card_panel(view), "delete_comment", %{"id" => to_string(theirs.id)})
      render_click(card_panel(view), "delete_comment", %{"id" => to_string(mine.id)})

      assert [%{body: "Theirs"}] = Boards.get_card!(ctx.card.id).comments
    end
  end

  test "a plain reader still gets no comment box and is refused", ctx do
    {:ok, view, _} = live(conn_as(ctx.commenter), ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert render(view) =~ "You have read-only access to this card."
    refute has_element?(view, "form[phx-submit=add_comment]")
    refute has_element?(view, "#card-modal fieldset:not([disabled]) button[phx-click=vote]")

    assert render_submit(card_panel(view), "add_comment", %{"body" => "hi"}) =~
             "read-only access to this card"

    assert Boards.get_card!(ctx.card.id).comments == []
  end

  describe "a page commenter" do
    setup ctx do
      page = page_fixture(ctx.board, %{"title" => "Proposal"}, user: ctx.user)
      {:ok, _} = Access.grant(page, ctx.commenter, "comment", ctx.user)
      %{page: page}
    end

    test "comments and reports on the wiki page, but edits nothing on it", ctx do
      {:ok, view, _} =
        live(conn_as(ctx.commenter), ~p"/boards/#{ctx.board}/wiki/#{ctx.page.slug}")

      assert has_element?(view, "form[phx-submit=add_comment]")
      refute has_element?(view, "form[phx-submit=add_check]")

      render_submit(view, "add_comment", %{"body" => "Reads well"})
      render_submit(view, "add_status_update", %{"health" => "on_track"})
      render_submit(view, "add_check", %{"text" => "Sneaky"})

      page = Slipdock.Repo.preload(Wiki.get_page!(ctx.page.id), Wiki.board_preloads())
      assert [%{body: "Reads well"}] = page.comments
      assert [%{health: "on_track"}] = page.status_updates
      assert page.checklist_items == []
    end

    test "comments from the board's page panel too", ctx do
      {:ok, _} = Wiki.place(ctx.page, hd(ctx.board.columns))
      {:ok, view, _} = live(conn_as(ctx.commenter), ~p"/boards/#{ctx.board}")
      render_click(view, "open_page", %{"id" => ctx.page.id})
      panel = with_target(view, "#board-page")

      render_submit(panel, "add_comment", %{"body" => "From the board"})
      render_submit(panel, "add_check", %{"text" => "Sneaky"})

      page = Slipdock.Repo.preload(Wiki.get_page!(ctx.page.id), Wiki.board_preloads())
      assert [%{body: "From the board"}] = page.comments
      assert page.checklist_items == []
    end
  end
end
