defmodule SlipdockWeb.CardSectionsLiveTest do
  @moduledoc """
  The card back's section labels and the subcards area (#1728): key letters
  marked, not underlined at rest; one icon rule for the headings; one add
  row for subcards with a list picker; Remove subcards in a menu; and a
  one-line drop zone when nothing is attached.
  `tools/e2e/card-sections.sh` checks the Alt underline in a browser, and
  `assets/js/key_hints.test.js` the switch itself.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Launch the site"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp epic!(ctx) do
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = Boards.create_sub_board(ctx.card, t)
    Boards.get_board!(sub.id)
  end

  defp doc(view), do: view |> render() |> Floki.parse_document!()

  describe "key letters" do
    test "are marked, never underlined by a class of their own", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      html = render(view)

      marks = view |> doc() |> Floki.find("#card-modal [data-section-key] u")
      assert length(marks) >= 8
      assert Enum.all?(marks, &(Floki.attribute(&1, "class") == ["keyed-key"]))
      refute html =~ "underline decoration-1"
    end

    test "the underline is drawn only under data-show-keys, in app.css" do
      css = File.read!("assets/css/app.css")
      assert css =~ ".keyed-key { text-decoration: none; }"
      assert css =~ "[data-show-keys] .keyed-key {"
    end
  end

  test "every section heading in the main column has an icon", ctx do
    epic!(ctx)
    {:ok, view, _} = open(ctx.conn, ctx)

    headings =
      view
      |> doc()
      |> Floki.find("#card-modal [data-section-key]")
      |> Enum.map(fn section -> {section, Floki.find(section, ".section-label")} end)
      |> Enum.reject(fn {_, labels} -> labels == [] end)

    assert length(headings) >= 8

    for {section, [label | _]} <- headings do
      key = section |> Floki.attribute("data-section-key") |> hd()
      assert Floki.find(label, "span[class*=hero-]") != [], "section #{key} has no icon"
    end

    # Flags and Tags, which had none.
    assert has_element?(view, "#card-flags .section-label .hero-flag")
    assert has_element?(view, "#card-tags .section-label .hero-tag")
  end

  describe "subcards" do
    test "one add row, its list picker on the first list", ctx do
      sub = epic!(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      assert [_] = view |> doc() |> Floki.find("#card-modal form[phx-submit=quick_add_subcard]")

      options = view |> doc() |> Floki.find("#add-subcard-0 select[name=column_id] option")

      assert Enum.map(options, &(&1 |> Floki.attribute("value") |> hd())) ==
               Enum.map(sub.columns, &to_string(&1.id))

      # No option is marked selected, so the browser shows (and sends) the first.
      assert Enum.all?(options, &(Floki.attribute(&1, "selected") == []))
    end

    test "adds to whichever list is picked, each of them", ctx do
      sub = epic!(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      sub.columns
      |> Enum.with_index()
      |> Enum.each(fn {col, i} ->
        view
        |> form("#add-subcard-#{i}", %{"title" => "In #{col.name}", "column_id" => col.id})
        |> render_submit()

        assert [%{title: title}] =
                 Boards.get_board!(sub.id).columns |> Enum.at(i) |> Map.get(:cards)

        assert title == "In #{col.name}"
      end)

      for col <- sub.columns, do: assert(render(view) =~ "In #{col.name}")
    end

    test "a blank title, or a list from another board, adds nothing", ctx do
      sub = epic!(ctx)
      other = board_fixture(%{}, owner: ctx.owner)
      {:ok, view, _} = open(ctx.conn, ctx)

      view
      |> form("#add-subcard-0", %{"title" => "   ", "column_id" => hd(sub.columns).id})
      |> render_submit()

      view
      |> with_target("#board-card")
      |> render_submit("quick_add_subcard", %{
        "title" => "Stray",
        "column_id" => hd(other.columns).id
      })

      for col <- sub.columns, do: assert(Boards.active_items(col.id) == [])
      assert Boards.active_items(hd(other.columns).id) == []
    end

    test "Remove subcards is in the section's menu, asks first, and removes them", ctx do
      epic!(ctx)
      {:ok, view, _} = open(ctx.conn, ctx)

      refute has_element?(
               view,
               "section[data-section-key=s] > button[phx-click=delete_sub_board]"
             )

      assert has_element?(view, "#subcards-more[popovertarget=subcards-more-menu]")

      assert has_element?(
               view,
               ~s(#subcards-more-menu #delete-sub-board[data-confirm="Remove all subcards of this card? This deletes them permanently."]),
               "Remove subcards"
             )

      view |> element("#delete-sub-board") |> render_click()
      assert is_nil(Boards.get_card!(ctx.card.id).sub_board)
      refute has_element?(view, "#subcards-more")
      assert has_element?(view, "button[phx-click=pick_template]", "Add subcards")
    end

    test "a reader has no add row and no menu", ctx do
      epic!(ctx)
      reader = user_fixture("sections.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)

      refute has_element?(view, "form[phx-submit=quick_add_subcard]")
      refute has_element?(view, "#subcards-more")
      refute has_element?(view, "#subcards-more-menu")
    end
  end

  describe "attachments, when there are none" do
    test "a one-line drop zone that opens the file picker", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      [zone] = view |> doc() |> Floki.find("#card-attachments [data-role=drop-zone]")
      assert Floki.text(zone) =~ "Drop files here or click to attach"

      [input_id] =
        view |> doc() |> Floki.find("#attach-form input[type=file]") |> Floki.attribute("id")

      assert Floki.attribute(zone, "for") == [input_id]
    end

    test "gone once something is attached, and never for a reader", ctx do
      Slipdock.TestConfig.own_uploads_dir()
      path = Path.join(System.tmp_dir!(), "sections-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "brief")
      on_exit(fn -> File.rm(path) end)

      {:ok, _} =
        Boards.add_attachment(
          ctx.card,
          %{filename: "brief.txt", content_type: "text/plain"},
          path
        )

      {:ok, view, _} = open(ctx.conn, ctx)
      refute has_element?(view, "[data-role=drop-zone]")

      reader = user_fixture("sections.attach.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Bare"})

      {:ok, view, _} =
        live(log_in_user(build_conn(), reader), ~p"/boards/#{ctx.board}/cards/#{other.id}")

      refute has_element?(view, "[data-role=drop-zone]")
    end
  end
end
