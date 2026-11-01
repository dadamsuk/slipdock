defmodule SlipdockWeb.HomeVaultsLiveTest do
  @moduledoc "Vaults on the home page, among the boards (#751)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Slipdock.{Accounts, Vaults, Wiki}

  test "with no board of your own: the empty state and no vault tile", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No boards yet"
    refute has_element?(view, "[id^=vault-tile-]")
    refute has_element?(view, "#boards")
  end

  test "a board somebody shared is no vault of yours", %{conn: conn, user: user} do
    lender = user_fixture("home-lender@example.com")
    lent = board_fixture(%{"name" => "Lent", "code" => "lenth"}, owner: lender)
    share_fixture(lent, user, "read")

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#board-#{lent.id}", "Lent")
    refute has_element?(view, "[id^=vault-tile-]")
  end

  test "one tile: its boards, pages and synced folders", %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbh"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "hunth"}, owner: user)
    {:ok, _} = Wiki.create_page(kb, %{"title" => "One"})
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Two"})
    {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Notes"})
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)

    {:ok, view, _} = live(conn, ~p"/")

    tile = "#vault-tile-#{vault.id}"
    assert has_element?(view, tile, "Notes")
    assert has_element?(view, tile, "2 pages")
    assert has_element?(view, tile, "2 boards")
    assert has_element?(view, tile, "Journal Desk")
    assert has_element?(view, tile, "Keystone")
    assert has_element?(view, tile, "slipdock CLI on laptop")
    assert [_] = Regex.scan(~r/id="vault-tile-/, render(view))
  end

  test "boards list as boards, with nothing kept inside the vault", %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbin"}, owner: user)
    plain = board_fixture(%{"name" => "Plain Board", "code" => "plainin"}, owner: user)
    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#board-#{kb.id}", "Keystone")
    assert has_element?(view, "#board-#{plain.id}", "Plain Board")
    refute has_element?(view, "[id^=vault-inside-]")
    refute html =~ "pages stored on"
  end

  test "there is no way to make a vault", %{conn: conn, user: user} do
    board_fixture(%{"name" => "Keystone", "code" => "kbnv"}, owner: user)
    {:ok, view, html} = live(conn, ~p"/")

    refute has_element?(view, "#new-vault")
    refute has_element?(view, "#new-vault-tile")
    refute has_element?(view, "#new-vault-form")
    refute html =~ "New vault"
    assert has_element?(view, "#new-board-tile")
  end

  test "the tile's count and activity come from the boards you own", %{user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbcnt"}, owner: user)
    [column | _] = Slipdock.Repo.preload(kb, :columns).columns
    card_fixture(column, %{"title" => "One"})
    card_fixture(column, %{"title" => "Two"})
    gone = card_fixture(column, %{"title" => "Gone"})
    {:ok, _} = Slipdock.Boards.archive_card(gone)

    lender = user_fixture("home-count@example.com")
    lent = board_fixture(%{"name" => "Lent", "code" => "lentcnt"}, owner: lender)
    [lent_column | _] = Slipdock.Repo.preload(lent, :columns).columns
    card_fixture(lent_column, %{"title" => "Not mine"})
    share_fixture(lent, user, "read")

    {:ok, _} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Counted"})
    {:ok, user} = Accounts.update_board_view(user, %{"board_layout" => "compact"})

    {:ok, view, _} = live(log_in_user(build_conn(), user), ~p"/")
    vault = Vaults.root(user)

    assert view |> element("tr#vault-#{vault.id} td.tabular-nums") |> render() =~ ">2<"
    assert has_element?(view, "tr#vault-#{vault.id}", "just now")
  end

  describe "among the boards" do
    setup %{user: user} do
      alpha = board_fixture(%{"name" => "Alpha", "code" => "alvlt"}, owner: user)
      {:ok, vault} = user |> Vaults.root() |> Vaults.update_vault(%{"name" => "Middle"})
      zulu = board_fixture(%{"name" => "Zulu", "code" => "zuvlt"}, owner: user)

      # A second apart, as they would be made by hand: within one second, a
      # board and a vault have no order of their own.
      for {schema, id, ago} <- [
            {Slipdock.Boards.Board, alpha.id, 20},
            {Vaults.Vault, vault.id, 10}
          ] do
        at = DateTime.add(DateTime.utc_now(:second), -ago)

        Slipdock.Repo.update_all(from(x in schema, where: x.id == ^id),
          set: [inserted_at: at]
        )
      end

      %{alpha: alpha, vault: vault, zulu: zulu}
    end

    defp tiles(html) do
      ~r/\sid="(board|vault)-(\d+)"/
      |> Regex.scan(html)
      |> Enum.map(fn [_, kind, id] -> {String.to_atom(kind), String.to_integer(id)} end)
    end

    test "a vault is a card in the boards' grid, in the order they were made", ctx do
      %{conn: conn, alpha: alpha, vault: vault, zulu: zulu} = ctx
      {:ok, view, _} = live(conn, ~p"/")

      grid = view |> element("#boards") |> render()
      assert tiles(grid) == [board: alpha.id, vault: vault.id, board: zulu.id]
      assert has_element?(view, "#boards #vault-#{vault.id}[data-id='vault-#{vault.id}']")
      assert has_element?(view, "#vault-#{vault.id} .board-handle")
    end

    test "follows the sort, and is in the compact list too", ctx do
      %{conn: conn, alpha: alpha, vault: vault, zulu: zulu} = ctx
      {:ok, view, _} = live(conn, ~p"/")

      html = view |> form("#board-sort", %{"sort" => "newest"}) |> render_change()
      assert tiles(html) == [board: zulu.id, vault: vault.id, board: alpha.id]

      html = view |> form("#board-sort", %{"sort" => "name"}) |> render_change()
      assert tiles(html) == [board: alpha.id, vault: vault.id, board: zulu.id]
      # Only one way to drag: not while sorted by name.
      refute has_element?(view, "#vault-#{vault.id} .board-handle")

      html = view |> element("button[phx-value-layout=compact]") |> render_click()
      assert html =~ "<table"
      assert tiles(html) == [board: alpha.id, vault: vault.id, board: zulu.id]
      assert has_element?(view, "tr#vault-#{vault.id} a[href='/vaults/Middle']", "Middle")
      assert has_element?(view, "tr#vault-#{vault.id}", "0 pages · Alpha · Zulu")
    end

    test "is moved like a board, and the order is kept", ctx do
      %{conn: conn, alpha: alpha, vault: vault, zulu: zulu} = ctx
      {:ok, view, _} = live(conn, ~p"/")

      html = render_click(view, "nudge", %{"id" => "vault-#{vault.id}", "dir" => "up"})
      assert tiles(html) == [vault: vault.id, board: alpha.id, board: zulu.id]
      refute has_element?(view, "#vault-#{vault.id} button[phx-value-dir=up]")
      assert has_element?(view, "#vault-#{vault.id} button[phx-value-dir=down]")

      # Dropped at the end, then a board dropped in front of it.
      html =
        render_hook(view, "reorder", %{"id" => "vault-#{vault.id}", "before" => nil})

      assert tiles(html) == [board: alpha.id, board: zulu.id, vault: vault.id]

      html =
        render_hook(view, "reorder", %{
          "id" => to_string(alpha.id),
          "before" => "vault-#{vault.id}"
        })

      assert tiles(html) == [board: zulu.id, board: alpha.id, vault: vault.id]

      {:ok, _view, html} = live(conn, ~p"/")
      assert tiles(html) == [board: zulu.id, board: alpha.id, vault: vault.id]
    end

    test "somebody else's vault can't be moved by naming it", ctx do
      %{conn: conn, alpha: alpha, vault: vault, zulu: zulu} = ctx
      stranger = user_fixture("vault-mover@example.com")
      {:ok, theirs} = stranger |> Vaults.root() |> Vaults.update_vault(%{"name" => "Theirs"})
      {:ok, view, _} = live(conn, ~p"/")

      html = render_hook(view, "reorder", %{"id" => "vault-#{theirs.id}", "before" => nil})
      assert tiles(html) == [board: alpha.id, vault: vault.id, board: zulu.id]
      assert Slipdock.Repo.reload(theirs).position == nil
    end
  end
end
