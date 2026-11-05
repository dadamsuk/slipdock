defmodule SlipdockWeb.CardTagsLiveTest do
  @moduledoc """
  Flags and tags on the card back (#1727): only the applied ones, as chips
  with a remove ×, then "+ Add", which opens a checklist of the rest; the tag
  picker also makes a new tag. `tools/e2e/card-tags.sh` checks the popovers,
  the narrowing and the keys in a browser.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Plan the launch"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp tag!(ctx, name, colour \\ "slate") do
    {:ok, tag} = Boards.create_tag(ctx.board, %{"name" => name, "color" => colour})
    tag
  end

  defp chips(view, kind),
    do:
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#card-#{kind}s [data-role=#{kind}-chip]")

  describe "flags" do
    test "with none, just + Add; the picker lists all five", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      assert chips(view, "flag") == []

      assert has_element?(
               view,
               "#card-flags button#card-flags-add[popovertarget=card-flags-menu]"
             )

      for flag <- ~w(flagged blocked review waiting starred) do
        assert has_element?(
                 view,
                 ~s(#card-flags-menu #card-flag-pick-#{flag}[aria-checked="false"])
               )
      end
    end

    test "the picker puts a flag on, as a chip, and its × takes it off", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#card-flag-pick-blocked") |> render_click()
      assert "blocked" in Boards.get_card!(ctx.card.id).flags
      assert has_element?(view, "#card-flag-blocked[data-role=flag-chip]", "Blocked")
      assert has_element?(view, ~s(#card-flag-pick-blocked[aria-checked="true"]))

      view |> element("#card-flag-blocked button") |> render_click()
      refute "blocked" in Boards.get_card!(ctx.card.id).flags
      refute has_element?(view, "#card-flag-blocked")
    end

    test "chips come in the picker's order, whatever order they were set in", ctx do
      {:ok, card} = Boards.toggle_flag(ctx.card, "starred")
      {:ok, _} = Boards.toggle_flag(card, "flagged")
      {:ok, view, _} = open(ctx.conn, ctx)

      assert view |> chips("flag") |> Enum.map(&Floki.attribute(&1, "id")) ==
               [["card-flag-flagged"], ["card-flag-starred"]]
    end
  end

  describe "tags" do
    test "on a board of 40 tags, only the applied ones are chips", ctx do
      tags = for i <- 1..40, do: tag!(ctx, "Tag #{i}")
      {:ok, _} = Boards.toggle_card_tag(ctx.card, Enum.at(tags, 4))
      {:ok, view, _} = open(ctx.conn, ctx)

      assert length(chips(view, "tag")) == 1
      assert has_element?(view, "#card-tags [data-role=tag-chip]", "Tag 5")
      # The rest are in the picker, out of sight until it opens.
      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#card-tags-menu [data-tag-name]")
             |> length() == 40

      assert has_element?(
               view,
               ~s(#card-tags-menu[popover] #card-tag-pick-#{Enum.at(tags, 4).id}[aria-checked="true"])
             )
    end

    test "the picker ticks a tag on and off; the chip's × takes it off", ctx do
      tag = tag!(ctx, "Design")
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#card-tag-pick-#{tag.id}") |> render_click()
      assert [%{name: "Design"}] = Boards.get_card!(ctx.card.id).tags
      assert has_element?(view, "#card-tag-#{tag.id}", "Design")

      view |> element("#card-tag-pick-#{tag.id}") |> render_click()
      assert Boards.get_card!(ctx.card.id).tags == []

      view |> element("#card-tag-pick-#{tag.id}") |> render_click()
      view |> element("#card-tag-#{tag.id} button") |> render_click()
      assert Boards.get_card!(ctx.card.id).tags == []
      refute has_element?(view, "#card-tag-#{tag.id}")
    end

    test "New tag makes a tag on the root board and puts it on the card", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> form("#card-tag-search", %{"name" => "  Launch week "}) |> render_submit()

      assert [tag] = Boards.list_tags(ctx.board.id)
      assert tag.name == "Launch week"
      assert [%{name: "Launch week"}] = Boards.get_card!(ctx.card.id).tags
      assert has_element?(view, "#card-tags [data-role=tag-chip]", "Launch week")
    end

    test "a name the board has, in any case, is that tag: applied, never made twice", ctx do
      tag = tag!(ctx, "Backend")
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> form("#card-tag-search", %{"name" => "backend"}) |> render_submit()
      assert [%{id: id}] = Boards.list_tags(ctx.board.id)
      assert id == tag.id
      assert [%{id: ^id}] = Boards.get_card!(ctx.card.id).tags

      # Again, with it already on: still on, still one.
      view |> form("#card-tag-search", %{"name" => "BACKEND"}) |> render_submit()
      assert [%{id: ^id}] = Boards.get_card!(ctx.card.id).tags
    end

    test "nothing typed makes nothing; a name too long is said, not crashed on", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> form("#card-tag-search", %{"name" => "   "}) |> render_submit()
      assert Boards.list_tags(ctx.board.id) == []

      view
      |> with_target("#board-card")
      |> render_submit("create_tag", %{"name" => String.duplicate("x", 31)})

      assert Boards.list_tags(ctx.board.id) == []
      assert view |> element("#flash-error") |> render() =~ "Tag not made"
    end

    test "with nothing typed, the picker's New tag opens the tag manager", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(
               view,
               "#card-tags-menu a#card-tag-manage[data-role=manage-tags]",
               "New tag"
             )

      assert has_element?(view, "#card-tags-menu button#card-tag-create[hidden]")
    end
  end

  test "the sections keep their keys, and name the picker each opens", ctx do
    {:ok, view, _} = open(ctx.conn, ctx)

    assert has_element?(
             view,
             ~s(#card-flags[data-section-key="f"][data-section-popover="card-flags-menu"])
           )

    assert has_element?(
             view,
             ~s(#card-tags[data-section-key="t"][data-section-popover="card-tags-menu"])
           )
  end

  test "a reader sees the chips, with no × and no pickers, and New tag is refused", ctx do
    tag = tag!(ctx, "Design")
    {:ok, card} = Boards.toggle_card_tag(ctx.card, tag)
    {:ok, _} = Boards.toggle_flag(card, "starred")
    reader = user_fixture("tags.reader@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

    {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)

    assert has_element?(view, "#card-tag-#{tag.id}", "Design")
    assert has_element?(view, "#card-flag-starred", "Starred")
    refute has_element?(view, "#card-tags button")
    refute has_element?(view, "#card-flags button")
    refute has_element?(view, "#card-tags-menu")
    refute has_element?(view, "#card-flags-menu")

    view |> with_target("#board-card") |> render_submit("create_tag", %{"name" => "Sneaky"})
    assert Boards.list_tags(ctx.board.id) |> Enum.map(& &1.name) == ["Design"]
  end

  test "a reader with nothing applied sees None", ctx do
    reader = user_fixture("tags.reader.none@example.com")
    {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
    {:ok, view, _} = open(log_in_user(build_conn(), reader), ctx)

    assert has_element?(view, "#card-flags", "None")
    assert has_element?(view, "#card-tags", "None")
  end
end
