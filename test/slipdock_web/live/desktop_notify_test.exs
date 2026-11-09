defmodule SlipdockWeb.DesktopNotifyTest do
  @moduledoc """
  Desktop toasts in the page (#2101): every signed-in LiveView carries the
  `DesktopNotify` hook and passes its reader's notifications on as
  `desktop-notify` (`SlipdockWeb.NotifyHook`), but not someone else's or
  the reader's own doing; the Preferences page draws the toggle, off until
  the browser says otherwise.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Notify}

  setup %{user: user} do
    board = board_fixture(%{}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Toast me"})
    %{board: board, card: card}
  end

  test "a mention of the reader reaches their page as desktop-notify", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    assert has_element?(
             view,
             "#desktop-notify[phx-hook=DesktopNotify][data-user-id='#{ctx.user.id}']"
           )

    other = user_fixture("toaster-#{System.unique_integer([:positive])}@example.com")
    {:ok, _} = Access.grant(ctx.board, other, "write", ctx.user)
    handle = ctx.user.email |> String.split("@") |> hd()
    {:ok, _} = Boards.add_comment(ctx.card, "@#{handle} look", by: other)

    path = "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
    assert_push_event(view, "desktop-notify", %{kind: "mention", path: ^path, id: "notify-" <> _})
  end

  describe "a wait on the reader (#2606)" do
    test "one their agent asks under their own token reaches their page", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      agent = %{
        Slipdock.Actor.unknown()
        | kind: "agent",
          via: "mcp",
          user_id: ctx.user.id,
          agent: "builder"
      }

      {:ok, _} =
        Boards.open_wait(ctx.card, agent, %{"needs" => "Which tier?", "on_user_id" => ctx.user.id})

      path = "/boards/#{ctx.board.id}/cards/#{ctx.card.id}"
      assert_push_event(view, "desktop-notify", %{kind: "wait", by_id: nil, path: ^path})
    end

    test "one they open on themselves in person doesn't", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      {:ok, _} =
        Boards.open_wait(ctx.card, Slipdock.Actor.web(ctx.user), %{
          "needs" => "Note to self",
          "on_user_id" => ctx.user.id
        })

      refute_push_event(view, "desktop-notify", _, 100)
    end

    test "with their Email me off, it still reaches their page", ctx do
      {:ok, user} =
        Slipdock.Accounts.update_waiting_notice(ctx.user, %{waiting_emails: false})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      other = user_fixture("asker-#{System.unique_integer([:positive])}@example.com")
      {:ok, _} = Access.grant(ctx.board, other, "write", user)

      {:ok, _} =
        Boards.open_wait(ctx.card, Slipdock.Actor.web(other), %{
          "needs" => "Ship it?",
          "on_user_id" => user.id
        })

      by = other.id
      assert_push_event(view, "desktop-notify", %{kind: "wait", by_id: ^by})
      Swoosh.TestAssertions.assert_no_email_sent()
    end
  end

  test "pages outside a board carry the hook too", %{conn: conn, user: user} do
    {:ok, view, _} = live(conn, ~p"/work")
    assert has_element?(view, "#desktop-notify[data-user-id='#{user.id}']")
  end

  test "the reader's own doing, or someone else's toast, is not pushed", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

    base = %{
      id: "notify-x",
      kind: "mention",
      card_id: ctx.card.id,
      path: "/",
      title: "t",
      body: ""
    }

    send(view.pid, {:notify, Map.merge(base, %{user_id: ctx.user.id, by_id: ctx.user.id})})
    send(view.pid, {:notify, Map.merge(base, %{user_id: ctx.user.id + 1, by_id: nil})})
    refute_push_event(view, "desktop-notify", _, 100)

    Notify.person(ctx.user, ctx.card, subject: "Direct", body: "B")
    assert_push_event(view, "desktop-notify", %{title: "Direct"})
  end

  test "Preferences shows the per-browser toggle, drawn by the browser", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/account/settings")
    assert html =~ "Desktop notifications on this browser"

    assert has_element?(
             view,
             "#desktop-notify-toggle[phx-hook=DesktopNotifyToggle][phx-update=ignore] input[type=checkbox]:not([checked])"
           )

    assert has_element?(view, "#desktop-notify-toggle [data-role=status]", "Off in this browser.")
  end

  test "the Boards help explains them", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/help/boards")

    assert has_element?(
             view,
             "#boards-desktop-notifications",
             "Desktop notifications on this browser"
           )

    assert has_element?(view, "#boards-desktop-notifications a[href='/account/settings']")
  end
end
