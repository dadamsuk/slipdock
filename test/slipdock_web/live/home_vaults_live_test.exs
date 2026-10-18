defmodule SlipdockWeb.HomeVaultsLiveTest do
  @moduledoc "Vaults on the home page, among the boards (#751)."
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Ecto.Query, only: [from: 2]

  alias Slipdock.{Accounts, Vaults, Wiki}

  test "with no vaults, there are no vault cards, but a vault can still be made", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "[id^=vault-tile-]")
    assert has_element?(view, "#new-vault", "New vault")
  end

  test "a tile per vault: its boards, pages and synced folders", %{conn: conn, user: user} do
    kb = board_fixture(%{"name" => "Keystone", "code" => "kbh"}, owner: user)
    hunt = board_fixture(%{"name" => "Journal Desk", "code" => "hunth"}, owner: user)
    {:ok, _} = Wiki.create_page(kb, %{"title" => "One"})
    {:ok, _} = Wiki.create_page(hunt, %{"title" => "Two"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: hunt})
    {_raw, token} = Accounts.create_api_token(user, "slipdock CLI on laptop")
    Vaults.touch_mirror(vault, token)
    {:ok, _empty} = Vaults.create_vault(user, %{"name" => "Empty"})

    {:ok, view, _} = live(conn, ~p"/")

    tile = "#vault-tile-#{vault.id}"
    assert has_element?(view, tile, "Notes")
    assert has_element?(view, tile, "2 pages")
    assert has_element?(view, tile, "Keystone · Journal Desk")
    assert has_element?(view, tile, "slipdock CLI on laptop")
    assert has_element?(view, "#boards a", "No boards mapped yet")
  end

  test "somebody else's vault is not shown", %{conn: conn} do
    stranger = user_fixture("home-stranger@example.com")
    {:ok, _} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
    {:ok, _view, html} = live(conn, ~p"/")
    refute html =~ "Theirs"
  end

  test "makes a vault from the home page, and says when the name won't do", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = Vaults.create_vault(user, %{"name" => "First"})
    {:ok, view, _} = live(conn, ~p"/")

    view |> element("#new-vault") |> render_click()
    view |> form("#new-vault-form", %{"name" => "Second"}) |> render_submit()
    assert [_, _] = Vaults.list_vaults(user)
    assert has_element?(view, "#boards a", "Second")
    refute has_element?(view, "#new-vault-form")

    view |> element("#new-vault") |> render_click()
    html = view |> form("#new-vault-form", %{"name" => "second"}) |> render_submit()
    assert html =~ "already have a vault with that name"
    assert length(Vaults.list_vaults(user)) == 2
  end

  describe "a board kept inside its vault (#757)" do
    setup %{user: user} do
      kb = board_fixture(%{"name" => "Keystone", "code" => "kbin"}, owner: user)
      plain = board_fixture(%{"name" => "Plain Board", "code" => "plainin"}, owner: user)
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Notes"})
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb, inside: true})
      %{kb: kb, plain: plain, vault: vault}
    end

    test "leaves the owner's boards and is named on the vault's tile", ctx do
      %{conn: conn, kb: kb, plain: plain, vault: vault} = ctx
      [column | _] = Slipdock.Repo.preload(kb, :columns).columns
      card_fixture(column, %{"title" => "Something to do"})
      {:ok, view, _} = live(conn, ~p"/")

      refute has_element?(view, "#board-#{kb.id}")
      assert has_element?(view, "#board-#{plain.id}", plain.name)

      inside = "#vault-inside-#{vault.id}-#{kb.id}"

      assert has_element?(
               view,
               "#{inside}[href='/boards/#{kb.id}']",
               "pages stored on Keystone"
             )

      assert has_element?(view, inside, "1 card")
    end

    test "still reachable at its address", %{conn: conn, kb: kb} do
      assert {:ok, _view, html} = live(conn, ~p"/boards/#{kb}")
      assert html =~ "Keystone"
    end

    test "anyone it is shared with sees an ordinary board", %{kb: kb, user: owner} do
      member = user_fixture("inside-member@example.com")
      {:ok, _} = Slipdock.Access.grant(kb, member, "read", owner)

      {:ok, view, _} = live(conn_as(member), ~p"/")
      assert has_element?(view, "#board-#{kb.id}", "Keystone")
      refute has_element?(view, "[id^=vault-tile-]")
    end

    test "back on the home page when unmapped, or the vault is deleted", ctx do
      %{conn: conn, kb: kb, vault: vault, user: user} = ctx
      {:ok, _} = Vaults.remove_mapping(vault, "/")
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#boards", "Keystone")

      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb, inside: true})
      {:ok, _} = Vaults.delete_vault(vault)
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#boards", "Keystone")
    end

    test "a new vault can come with a board to hold its pages, kept inside", ctx do
      %{conn: conn, user: user} = ctx
      {:ok, view, _} = live(conn, ~p"/")
      view |> element("#new-vault") |> render_click()

      html =
        view
        |> form("#new-vault-form", %{"name" => "Brain", "with_board" => "true"})
        |> render_submit()

      assert html =~ "with a board of the same name holding its pages"
      {:ok, brain} = Vaults.get_vault(user, "Brain")
      assert [%{path: "", inside: true, board: board}] = brain.mappings
      assert has_element?(view, "#vault-inside-#{brain.id}-#{board.id}", "pages stored on Brain")
      refute has_element?(view, "#board-#{board.id}")
    end
  end

  describe "among the boards" do
    setup %{user: user} do
      alpha = board_fixture(%{"name" => "Alpha", "code" => "alvlt"}, owner: user)
      {:ok, vault} = Vaults.create_vault(user, %{"name" => "Middle"})
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
      %{conn: conn, user: user, alpha: alpha, vault: vault, zulu: zulu} = ctx
      {:ok, view, _} = live(conn, ~p"/")

      html = view |> form("#board-sort", %{"sort" => "newest"}) |> render_change()
      assert tiles(html) == [board: zulu.id, vault: vault.id, board: alpha.id]

      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: zulu})
      html = view |> form("#board-sort", %{"sort" => "name"}) |> render_change()
      assert tiles(html) == [board: alpha.id, vault: vault.id, board: zulu.id]
      # Only one way to drag: not while sorted by name.
      refute has_element?(view, "#vault-#{vault.id} .board-handle")

      html = view |> element("button[phx-value-layout=compact]") |> render_click()
      assert html =~ "<table"
      assert tiles(html) == [board: alpha.id, vault: vault.id, board: zulu.id]
      assert has_element?(view, "tr#vault-#{vault.id} a[href='/vaults/Middle']", "Middle")
      assert has_element?(view, "tr#vault-#{vault.id}", "0 pages · Zulu")
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
      {:ok, theirs} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
      {:ok, view, _} = live(conn, ~p"/")

      html = render_hook(view, "reorder", %{"id" => "vault-#{theirs.id}", "before" => nil})
      assert tiles(html) == [board: alpha.id, vault: vault.id, board: zulu.id]
      assert Slipdock.Repo.reload(theirs).position == nil
    end

    test "New vault looks and works like New board, button and tile", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "button.btn.btn-primary.btn-sm[phx-click=start_create]")
      assert has_element?(view, "button#new-vault.btn.btn-primary.btn-sm")

      [board_tile] = view |> element("#new-board-tile") |> render() |> class_of()
      [vault_tile] = view |> element("#new-vault-tile") |> render() |> class_of()
      assert board_tile == vault_tile

      view |> element("#new-vault-tile") |> render_click()
      assert has_element?(view, "#new-vault-form")
      refute has_element?(view, "#new-vault")
      refute has_element?(view, "#new-vault-tile")

      # One form open at a time.
      view |> element("#new-board-tile") |> render_click()
      refute has_element?(view, "#new-vault-form")
      assert has_element?(view, "#new-board")

      view |> element("#new-vault") |> render_click()
      refute has_element?(view, "#new-board")
      view |> form("#new-vault-form", %{"name" => "Fresh"}) |> render_submit()
      assert {:ok, _} = Vaults.get_vault(user, "Fresh")
      assert has_element?(view, "#new-vault-tile")
    end

    defp class_of(html), do: Regex.run(~r/class="([^"]*)"/, html, capture: :all_but_first)
  end
end
