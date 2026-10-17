defmodule SlipdockWeb.ArchiveSearchLiveTest do
  @moduledoc """
  Searching a board's archived cards (#1037): the archive panel's search box,
  and an archived card's own link, which lands on it there.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Archive"}, owner: user)
    col = hd(board.columns)
    refunds = archived(col, "Refunds rounding")
    deploy = archived(col, "Deploy rollback")
    live_card = card_fixture(col, %{"title" => "Still live"})
    %{board: board, refunds: refunds, deploy: deploy, live_card: live_card}
  end

  defp archived(col, title) do
    {:ok, card} = Boards.archive_card(card_fixture(col, %{"title" => title}))
    card
  end

  defp search(view, q) do
    view |> element("#archive-search") |> render_change(%{"q" => q})
  end

  defp listed?(view, card), do: has_element?(view, "#archived-#{card.id}")

  test "the box narrows the list by title, by #id and by link", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/archive")
    assert listed?(view, ctx.refunds) and listed?(view, ctx.deploy)
    assert has_element?(view, "#archived-#{ctx.deploy.id}", "##{ctx.deploy.id}")

    search(view, "refunds")
    assert listed?(view, ctx.refunds)
    refute listed?(view, ctx.deploy)

    search(view, "##{ctx.deploy.id}")
    assert listed?(view, ctx.deploy)
    refute listed?(view, ctx.refunds)

    search(view, "https://app.slipdock.us/boards/#{ctx.board.id}/cards/#{ctx.refunds.id}")
    assert listed?(view, ctx.refunds)
    refute listed?(view, ctx.deploy)

    assert search(view, "nothing like it") =~ "No archived cards match."
    refute listed?(view, ctx.refunds)

    search(view, "")
    assert listed?(view, ctx.refunds) and listed?(view, ctx.deploy)
  end

  test "a live card's id finds nothing in the archive", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/archive")
    assert search(view, "#{ctx.live_card.id}") =~ "No archived cards match."
  end

  test "a reader with read-only access can search, but still not restore", ctx do
    reader = user_fixture("reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)
    conn = log_in_user(build_conn(), reader)

    {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/archive")
    search(view, "deploy")
    assert listed?(view, ctx.deploy)
    refute listed?(view, ctx.refunds)

    view
    |> with_target("#board-archive")
    |> render_hook("restore_card", %{"id" => "#{ctx.deploy.id}"})

    assert Repo.get!(Card, ctx.deploy.id).archived_at
  end

  test "a restore keeps the search the reader typed", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/archive")
    other = archived(hd(ctx.board.columns), "Refunds again")
    search(view, "refunds")

    view |> element("#archived-#{ctx.refunds.id} button", "Restore") |> render_click()
    refute listed?(view, ctx.refunds)
    assert listed?(view, other)
    refute listed?(view, ctx.deploy)
  end

  test "an archived card's link opens the archive on that card", ctx do
    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.deploy.id}")

    assert flash["info"] == "That card is archived."
    assert to == ~p"/boards/#{ctx.board}/archive?#{[card: ctx.deploy.id]}"

    {:ok, view, _} = live(ctx.conn, to)
    assert listed?(view, ctx.deploy)
    refute listed?(view, ctx.refunds)
    assert has_element?(view, ~s{#archive-search input[value="##{ctx.deploy.id}"]})
  end

  test "a junk ?card= opens the whole archive", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/archive?card=nope")
    assert listed?(view, ctx.refunds) and listed?(view, ctx.deploy)
  end

  test "a card that is gone, or archived on another board, still says so", ctx do
    {:ok, gone} = Boards.archive_card(card_fixture(hd(ctx.board.columns), %{"title" => "x"}))
    {:ok, _} = Boards.delete_card(gone)
    other = board_fixture(%{"name" => "Other"}, owner: ctx.user)
    elsewhere = archived(hd(other.columns), "Elsewhere")

    for id <- [gone.id, elsewhere.id] do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{id}")

      assert to == ~p"/boards/#{ctx.board}"
      assert flash["error"] == "That card no longer exists."
    end
  end
end
