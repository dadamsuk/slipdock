defmodule SlipdockWeb.ColorSwatchLiveTest do
  @moduledoc """
  The pickers that draw `<.color_swatch>`'s "none" variant (#2888): the card's
  cover and borders and a list's colour. Each None button keeps its own words,
  is the pressed one while nothing is chosen, and clears the colour; and every
  swatch beside it has an accessible name.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards.Column
  alias Slipdock.{Palette, Repo}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    column = hd(board.columns)
    card = card_fixture(column, %{"title" => "Painted"})
    %{board: board, column: column, card: card}
  end

  defp none(scope, event), do: ~s(#{scope} button[data-swatch="none"][phx-click="#{event}"])

  defp colour(scope, event, name),
    do: ~s(#{scope} button[data-swatch="#{name}"][phx-click="#{event}"])

  describe "the card's cover" do
    test "None is pressed until a colour is, and clears it again", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      none = none("#board-card", "set_cover") <> ~s([title="No cover"][aria-label="No cover"])

      assert has_element?(view, none <> ~s([aria-pressed="true"]))

      view |> element(colour("#board-card", "set_cover", "sky")) |> render_click()
      assert Repo.reload!(ctx.card).color == "sky"
      assert has_element?(view, none <> ~s([aria-pressed="false"]))

      assert has_element?(
               view,
               colour("#board-card", "set_cover", "sky") <>
                 ~s([aria-pressed="true"][aria-label="#{Palette.label("sky")}"])
             )

      view |> element(none) |> render_click()
      assert Repo.reload!(ctx.card).color == nil
      assert has_element?(view, none <> ~s([aria-pressed="true"]))
    end
  end

  describe "the card's borders" do
    test "each edge's None says which edge, and is pressed while it has no colour", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      top = none("#card-borders", "set_border") <> ~s([phx-value-edge="top"])

      assert has_element?(view, top <> ~s([aria-label="No top border"][aria-pressed="true"]))

      view
      |> element(colour("#card-borders", "set_border", "red") <> ~s([phx-value-edge="top"]))
      |> render_click()

      assert Repo.reload!(ctx.card).border_top == "red"
      assert has_element?(view, top <> ~s([aria-pressed="false"]))

      view |> element(top) |> render_click()
      assert Repo.reload!(ctx.card).border_top == nil
      assert has_element?(view, top <> ~s([aria-pressed="true"]))
    end
  end

  describe "a list's colour" do
    test "None is pressed until a colour is, and clears it again", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      view |> with_target("#board-column") |> render_hook("edit_column", %{"id" => ctx.column.id})
      none = none("#board-column", "set_column_color") <> ~s([title="None"][aria-label="None"])

      assert has_element?(view, none <> ~s([aria-pressed="true"]))

      view |> element(colour("#board-column", "set_column_color", "rose")) |> render_click()
      assert Repo.get!(Column, ctx.column.id).color == "rose"
      assert has_element?(view, none <> ~s([aria-pressed="false"]))

      assert has_element?(
               view,
               colour("#board-column", "set_column_color", "rose") <>
                 ~s([aria-pressed="true"][aria-label="#{Palette.label("rose")}"])
             )

      view |> element(none) |> render_click()
      assert Repo.get!(Column, ctx.column.id).color == nil
      assert has_element?(view, none <> ~s([aria-pressed="true"]))
    end
  end

  describe "the tags panel" do
    test "its palette is the shared swatch: named, and closing its popover", ctx do
      tag = tag_fixture(ctx.board, "later")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/tags")
      pal = "tag-colors-#{tag.id}"

      for name <- Palette.names() do
        assert has_element?(
                 view,
                 ~s(##{pal}-#{name}[data-swatch="#{name}"][aria-label="#{Palette.label(name)}"]) <>
                   ~s([popovertarget="#{pal}"][popovertargetaction="hide"][phx-value-id="#{tag.id}"])
               )
      end

      assert has_element?(
               view,
               ~s(#new-tag-colors-rose[data-swatch="rose"][popovertarget="new-tag-colors"])
             )
    end
  end
end
