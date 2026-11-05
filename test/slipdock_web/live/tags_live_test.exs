defmodule SlipdockWeb.TagsLiveTest do
  @moduledoc """
  The board's Tags panel as compact rows (#1741): a colour dot opening the
  palette in a popover, the name edited in place, Delete in a ⋯ menu behind
  a confirm, and New tag as one row at the top. What goes wrong is said in
  the panel, never as a toast (a toast's self-click would close the modal).

  The name box's keys (Enter and blur save, Escape puts the name back and
  saves nothing) run in the browser: `tools/e2e/board-settings.sh` drives
  them. Here the server side of each path is checked.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  import Ecto.Query, only: [from: 2]

  alias Slipdock.Boards.Tag

  setup %{user: user} do
    board = board_fixture(%{"name" => "Tagged"}, owner: user)
    urgent = tag_fixture(board, "urgent", "rose")
    later = tag_fixture(board, "later", "sky")
    %{board: board, urgent: urgent, later: later}
  end

  defp open(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/tags")
    view
  end

  defp panel(view), do: with_target(view, "#board-tags")

  defp names(board) do
    Repo.all(from t in Tag, where: t.board_id == ^board.id) |> Enum.map(& &1.name) |> Enum.sort()
  end

  describe "the rows" do
    test "each tag is one row: a dot, its name in place and a ⋯ menu", ctx do
      view = open(ctx.conn, ctx.board)
      row = "#tag-row-#{ctx.urgent.id}"

      # The dot opens its own palette, a popover of the 12 colours.
      assert has_element?(
               view,
               ~s|#{row} #tag-dot-#{ctx.urgent.id}[popovertarget="tag-colors-#{ctx.urgent.id}"]|
             )

      assert has_element?(
               view,
               ~s|#tag-colors-#{ctx.urgent.id}[popover][phx-hook="AnchoredPopover"]|
             )

      for {name, _} <- Slipdock.Palette.all() do
        assert has_element?(
                 view,
                 "#tag-colors-#{ctx.urgent.id} #tag-colors-#{ctx.urgent.id}-#{name}"
               )
      end

      assert has_element?(view, ~s|#tag-colors-#{ctx.urgent.id}-rose[aria-pressed="true"]|)
      assert has_element?(view, ~s|#tag-colors-#{ctx.urgent.id}-sky[aria-pressed="false"]|)

      # The name is a bare box with the hook that saves it, not a form with a Rename button.
      input = "#{row} input#tag-name-#{ctx.urgent.id}.field-bare"
      assert has_element?(view, ~s|#{input}[value="urgent"][data-name="urgent"]|)
      assert view |> element(input) |> render() =~ ~r/phx-hook="[^"]*TagName"/
      refute render(view) =~ "Rename"

      # Delete is in the ⋯ menu, behind a confirm.
      assert has_element?(
               view,
               ~s|#tag-more-#{ctx.urgent.id}[popovertarget="tag-menu-#{ctx.urgent.id}"]|
             )

      assert has_element?(
               view,
               ~s|#tag-menu-#{ctx.urgent.id}[popover] #delete-tag-#{ctx.urgent.id}[data-confirm*="urgent"]|
             )

      refute has_element?(view, "#{row} > button[phx-click=delete_tag]")
    end

    test "New tag is one row, above the list", ctx do
      html = ctx.conn |> open(ctx.board) |> render()

      [form_at, list_at] =
        Enum.map(["id=\"tag-form\"", "id=\"tag-list\""], &(:binary.match(html, &1) |> elem(0)))

      assert form_at < list_at

      doc = Floki.parse_fragment!(html)
      assert [_] = Floki.find(doc, "#tag-form #new-tag-dot[popovertarget=new-tag-colors]")
      assert [_] = Floki.find(doc, "#tag-form input#new-tag-name")
      assert [_] = Floki.find(doc, "#tag-form button[type=submit]")
    end

    test "with no tags it says so", %{conn: conn, user: user} do
      board = board_fixture(%{"name" => "Bare"}, owner: user)
      view = open(conn, board)
      assert has_element?(view, "#tags-empty", "No tags yet")
      assert has_element?(view, "#tag-form")
    end
  end

  describe "a new tag" do
    test "is made in the colour picked from its dot", ctx do
      view = open(ctx.conn, ctx.board)

      view |> element("#new-tag-colors-amber") |> render_click()
      assert has_element?(view, ~s|#new-tag-colors-amber[aria-pressed="true"]|)

      view |> form("#tag-form", %{"tag" => %{"name" => "blocked"}}) |> render_submit()

      tag = Repo.get_by!(Tag, name: "blocked", board_id: ctx.board.id)
      assert tag.color == "amber"
      assert has_element?(view, "#tag-row-#{tag.id} input[value=blocked]")
      # The box is emptied for the next one.
      refute has_element?(view, "#new-tag-name[value]")
    end

    test "an unknown colour is ignored", ctx do
      view = open(ctx.conn, ctx.board)
      render_hook(panel(view), "pick_tag_color", %{"color" => "plaid"})
      view |> form("#tag-form", %{"tag" => %{"name" => "plain"}}) |> render_submit()
      assert Repo.get_by!(Tag, name: "plain", board_id: ctx.board.id).color == "sky"
    end

    test "an empty name makes nothing and says why", ctx do
      view = open(ctx.conn, ctx.board)
      view |> form("#tag-form", %{"tag" => %{"name" => "   "}}) |> render_submit()

      assert has_element?(view, "#new-tag-error", "can't be blank")
      assert has_element?(view, "#new-tag-name.input-error")
      assert names(ctx.board) == ~w(later urgent)
    end

    test "a name already taken makes nothing and says why", ctx do
      view = open(ctx.conn, ctx.board)
      view |> form("#tag-form", %{"tag" => %{"name" => "urgent"}}) |> render_submit()

      assert has_element?(view, "#new-tag-error", "already exists")
      assert names(ctx.board) == ~w(later urgent)
    end
  end

  describe "renaming in place" do
    test "saves the new name and replies ok", ctx do
      view = open(ctx.conn, ctx.board)
      id = "#{ctx.urgent.id}"

      render_hook(panel(view), "rename_tag", %{"tag_id" => id, "name" => "  on fire "})
      assert_reply(view, %{ok: true, name: "on fire"})

      assert Repo.get!(Tag, ctx.urgent.id).name == "on fire"
      assert has_element?(view, ~s|#tag-name-#{id}[data-name="on fire"]|)
      refute has_element?(view, "#tags-error")
    end

    test "the same name is no change", ctx do
      view = open(ctx.conn, ctx.board)

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => "urgent"})

      assert_reply(view, %{ok: true})
      refute has_element?(view, "#tags-error")
    end

    test "an empty name is refused, in the panel, and the old one kept", ctx do
      view = open(ctx.conn, ctx.board)

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => " "})
      assert_reply(view, %{ok: false, name: "urgent"})

      assert has_element?(view, "#tags-error[role=alert]", "A tag needs a name")
      assert Repo.get!(Tag, ctx.urgent.id).name == "urgent"
      # Said in the panel, not as a toast the modal would close on.
      refute render(view) =~ ~s(id="flash-error")
    end

    test "a name another tag has is refused, and the old one kept", ctx do
      view = open(ctx.conn, ctx.board)

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => "later"})
      assert_reply(view, %{ok: false, name: "urgent"})

      assert has_element?(view, "#tags-error", "There is already a tag with that name")
      assert Repo.get!(Tag, ctx.urgent.id).name == "urgent"
    end

    test "a name over 30 characters is refused", ctx do
      view = open(ctx.conn, ctx.board)
      long = String.duplicate("x", 31)

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => long})
      assert_reply(view, %{ok: false})

      assert has_element?(view, "#tags-error", "30 characters at most")
      assert Repo.get!(Tag, ctx.urgent.id).name == "urgent"
    end

    test "a good rename after a refused one clears the message", ctx do
      view = open(ctx.conn, ctx.board)
      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => ""})
      assert has_element?(view, "#tags-error")

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => "hot"})
      refute has_element?(view, "#tags-error")
      assert Repo.get!(Tag, ctx.urgent.id).name == "hot"
    end

    test "a tag that has gone is refused", ctx do
      view = open(ctx.conn, ctx.board)
      {:ok, _} = Boards.delete_tag(ctx.urgent)

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => "x"})
      assert_reply(view, %{ok: false})
    end
  end

  describe "colour and delete" do
    test "a swatch in a tag's popover recolours it", ctx do
      view = open(ctx.conn, ctx.board)

      view |> element("#tag-colors-#{ctx.later.id}-emerald") |> render_click()

      assert Repo.get!(Tag, ctx.later.id).color == "emerald"
      assert has_element?(view, ~s|#tag-colors-#{ctx.later.id}-emerald[aria-pressed="true"]|)
    end

    test "an unknown colour is refused in the panel", ctx do
      view = open(ctx.conn, ctx.board)

      render_hook(panel(view), "set_tag_color", %{"id" => "#{ctx.later.id}", "color" => "plaid"})

      assert has_element?(view, "#tags-error", "couldn't be set")
      assert Repo.get!(Tag, ctx.later.id).color == "sky"
    end

    test "Delete in the ⋯ menu removes the tag", ctx do
      view = open(ctx.conn, ctx.board)

      view |> element("#delete-tag-#{ctx.later.id}") |> render_click()

      refute Repo.get(Tag, ctx.later.id)
      refute has_element?(view, "#tag-row-#{ctx.later.id}")
      assert has_element?(view, "#tag-row-#{ctx.urgent.id}")
    end
  end

  describe "read-only" do
    setup ctx do
      reader = user_fixture("tags.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.user)
      %{reader_conn: conn_as(reader)}
    end

    test "sees the rows in a disabled fieldset", ctx do
      view = open(ctx.reader_conn, ctx.board)
      assert has_element?(view, "#board-tags fieldset[disabled] #tag-row-#{ctx.urgent.id}")
      assert has_element?(view, "#board-tags fieldset[disabled] #tag-form")
    end

    test "can't rename, and is told so in the panel", ctx do
      view = open(ctx.reader_conn, ctx.board)

      render_hook(panel(view), "rename_tag", %{"tag_id" => "#{ctx.urgent.id}", "name" => "mine"})
      assert_reply(view, %{ok: false})

      assert has_element?(view, "#tags-error", "read-only")
      assert Repo.get!(Tag, ctx.urgent.id).name == "urgent"
    end

    test "can't make, recolour or delete either", ctx do
      view = open(ctx.reader_conn, ctx.board)

      render_hook(panel(view), "create_tag", %{"tag" => %{"name" => "sneaky"}})
      render_hook(panel(view), "set_tag_color", %{"id" => "#{ctx.urgent.id}", "color" => "lime"})
      render_hook(panel(view), "delete_tag", %{"id" => "#{ctx.urgent.id}"})

      assert names(ctx.board) == ~w(later urgent)
      assert Repo.get!(Tag, ctx.urgent.id).color == "rose"
    end
  end
end
