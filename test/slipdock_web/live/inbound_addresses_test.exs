defmodule SlipdockWeb.InboundAddressesTest do
  @moduledoc """
  Your inbound addresses in the UI (#1245): the board menu's *Email to this
  board* and the Account tab's Quick Add address, each with copy and rotate.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, TestConfig}
  alias Slipdock.Inbound.{Token, Tokens}

  @domain "in.example.com"

  defp on, do: TestConfig.put(:inbound, domain: @domain, secrets: ["s"])

  defp text(view, selector),
    do: view |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.text()

  describe "the board menu" do
    test "Email to this board shows the card address, made only when opened",
         %{conn: conn, user: user} do
      on()
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}")
      assert has_element?(view, "#board-share-inbound", "Email to this board")
      refute has_element?(view, "#board-inbound-modal")
      assert Repo.aggregate(Token, :count) == 0

      view |> element("#board-share-inbound") |> render_click()

      assert has_element?(view, "#board-inbound-modal")
      {:ok, card} = Tokens.address(user, board, :card)
      assert text(view, "#board-inbound-card") == card

      assert has_element?(
               view,
               ~s(#board-inbound-card-copy[phx-hook="CopyText"][data-target="board-inbound-card"])
             )

      {:ok, page} = Tokens.address(user, board, :page)
      assert text(view, "#board-inbound-page") == page
    end

    test "rotating asks first, then shows a new address and the old one stops working",
         %{conn: conn, user: user} do
      on()
      board = board_fixture(%{}, owner: user)
      {:ok, old} = Tokens.address(user, board, :card)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}")
      view |> element("#board-share-inbound") |> render_click()

      assert view |> element("#board-inbound-rotate") |> render() =~ "data-confirm"
      view |> element("#board-inbound-rotate") |> render_click()

      new = text(view, "#board-inbound-card")
      assert new != old
      assert has_element?(view, "#board-inbound-rotated")
      assert Tokens.resolve(old) == {:error, :revoked}
      assert {:ok, {:card, _, _}} = Tokens.resolve(new)
    end

    test "closing the dialog", %{conn: conn, user: user} do
      on()
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}")
      view |> element("#board-share-inbound") |> render_click()
      view |> element("#board-inbound-modal button[aria-label=Close]") |> render_click()

      refute has_element?(view, "#board-inbound-modal")
    end

    test "not offered to somebody who can only read the board", %{user: owner} do
      on()
      board = board_fixture(%{}, owner: owner)
      reader = user_fixture("reader@example.com")
      share_fixture(board, reader, "read")

      {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board.id}")
      refute has_element?(view, "#board-share-inbound")
      refute has_element?(view, "#board-inbound")
    end

    test "offered to somebody the board is shared with to write", %{user: owner} do
      on()
      board = board_fixture(%{}, owner: owner)
      writer = user_fixture("writer@example.com")
      share_fixture(board, writer, "write")

      {:ok, view, _html} = live(conn_as(writer), ~p"/boards/#{board.id}")
      view |> element("#board-share-inbound") |> render_click()

      {:ok, theirs} = Tokens.address(writer, board, :card)
      assert text(view, "#board-inbound-card") == theirs
    end

    test "not there while inbound mail is off", %{conn: conn, user: user} do
      TestConfig.put(:inbound, [])
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}")
      refute has_element?(view, "#board-share-inbound")
      refute has_element?(view, "#board-share-menu-inbound")
      refute has_element?(view, "#board-inbound")
    end
  end

  describe "the wiki's board menu" do
    test "offers Email to this board, with the board's addresses",
         %{conn: conn, user: user} do
      on()
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}/wiki")
      assert has_element?(view, "#board-share-inbound", "Email to this board")
      assert has_element?(view, "#board-share-menu-inbound", "Email to this board")

      view |> element("#board-share-inbound") |> render_click()

      {:ok, page} = Tokens.address(user, board, :page)
      assert text(view, "#board-inbound-page") == page
    end

    test "its panels navigate to the board, which owns them", %{conn: conn, user: user} do
      on()
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}/wiki")
      share = element(view, "#board-share")

      assert render(share) =~ ~s(data-phx-link="redirect")
      assert render(share) =~ ~s(href="/boards/#{board.id}/settings")

      assert {:error, {:live_redirect, %{to: to}}} = render_click(share)
      assert to == "/boards/#{board.id}/settings"
    end

    test "on the board itself its panels still patch", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}")
      assert view |> element("#board-share") |> render() =~ ~s(data-phx-link="patch")
    end

    test "not there for somebody who can only read the board", %{user: owner} do
      on()
      board = board_fixture(%{}, owner: owner)
      reader = user_fixture("reader@example.com")
      share_fixture(board, reader, "read")

      {:ok, view, _html} = live(conn_as(reader), ~p"/boards/#{board.id}/wiki")
      refute has_element?(view, "#board-share")
      refute has_element?(view, "#board-share-inbound")
      refute has_element?(view, "#board-inbound")
    end

    test "there without Email to this board while inbound mail is off",
         %{conn: conn, user: user} do
      TestConfig.put(:inbound, [])
      board = board_fixture(%{}, owner: user)

      {:ok, view, _html} = live(conn, ~p"/boards/#{board.id}/wiki")
      assert has_element?(view, "#board-share")
      refute has_element?(view, "#board-share-inbound")
      refute has_element?(view, "#board-inbound")
    end
  end

  describe "the Account tab" do
    test "shows the personal Quick Add address with copy and rotate",
         %{conn: conn, user: user} do
      on()

      {:ok, view, _html} = live(conn, ~p"/account")
      {:ok, add} = Tokens.address(user, nil, :add)

      assert text(view, "#account-inbound-add") == add
      assert has_element?(view, ~s(#account-inbound-add-copy[data-target="account-inbound-add"]))

      view |> element("#account-inbound-rotate") |> render_click()
      new = text(view, "#account-inbound-add")
      assert new != add
      assert Tokens.resolve(add) == {:error, :revoked}
    end

    test "the acknowledgement setting, off until ticked, and back off", %{conn: conn, user: user} do
      on()

      {:ok, view, _html} = live(conn, ~p"/account")
      refute view |> element("#account-inbound-ack") |> render() =~ "checked"

      view |> form("#account-inbound-ack-form", %{"ack" => "true"}) |> render_change()
      assert Repo.reload!(user).inbound_ack
      assert view |> element("#account-inbound-ack") |> render() =~ "checked"

      view |> form("#account-inbound-ack-form", %{"ack" => "false"}) |> render_change()
      refute Repo.reload!(user).inbound_ack
    end

    test "not there while inbound mail is off", %{conn: conn} do
      TestConfig.put(:inbound, [])

      {:ok, view, _html} = live(conn, ~p"/account")
      refute has_element?(view, "#account-inbound")
    end
  end
end
