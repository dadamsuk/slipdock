defmodule SlipdockWeb.CardThumbnailTest do
  @moduledoc """
  An image attached to a card is a thumbnail on the card's front: the first
  one nobody has ticked "Don't show on the card front" beside, unless the
  Display menu leaves Images out.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards
  alias Slipdock.Boards.Attachment
  alias Slipdock.Swimlanes.Config

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    board = board_fixture(%{"name" => "Pictures board"})
    card = card_fixture(hd(board.columns), %{"title" => "Has pictures"})
    %{board: reload(board), card: card}
  end

  defp attach(card, name, type \\ "image/png") do
    path = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)
    {:ok, a} = Boards.add_attachment(card, %{filename: name, content_type: type}, path)
    a
  end

  defp thumb(card), do: "#card-#{card.id} img[data-role=card-image]"

  defp thumb_of(card, a),
    do: "#card-#{card.id} img[data-role=card-image][src='#{Boards.attachment_url(a)}']"

  test "the card's first image is the thumbnail on its front", %{
    conn: conn,
    board: board,
    card: card
  } do
    first = attach(card, "first.png")
    second = attach(card, "second.png")

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")

    assert has_element?(view, thumb_of(card, first))
    # One thumbnail, not one per image.
    refute has_element?(view, thumb_of(card, second))
  end

  test "a card with no image, or only other files, has no thumbnail", %{
    conn: conn,
    board: board,
    card: card
  } do
    attach(card, "notes.pdf", "application/pdf")
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, thumb(card))
  end

  test "an image kept off the front gives way to the next one, and none is left", %{
    conn: conn,
    board: board,
    card: card
  } do
    first = attach(card, "first.png")
    second = attach(card, "second.png")
    {:ok, _} = Boards.hide_attachment_on_card(first, true)

    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, thumb_of(card, second))
    refute has_element?(view, thumb_of(card, first))

    {:ok, _} = Boards.hide_attachment_on_card(second, true)
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    refute has_element?(view, thumb(card))
  end

  test "Display can leave images out, comfortable and compact alike", %{
    conn: conn,
    board: board,
    card: card
  } do
    attach(card, "first.png")

    without = Config.facet_keys() -- ["images"]
    {:ok, view, _} = live(conn, ~p"/boards/#{board}?#{[show: Enum.join(without, ",")]}")
    refute has_element?(view, thumb(card))

    # Compact leaves images out unless asked, and shows a small one when asked.
    {:ok, view, _} = live(conn, ~p"/boards/#{board}?#{[density: "compact"]}")
    refute has_element?(view, thumb(card))

    {:ok, view, _} =
      live(conn, ~p"/boards/#{board}?#{[density: "compact", show_compact: "images"]}")

    assert has_element?(view, "#card-#{card.id} img[data-role=card-image].size-5")
  end

  test "the Display menu offers Images", %{conn: conn, board: board} do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    assert has_element?(view, "#display-menu input[name='show[]'][value=images]")
  end

  describe "the card panel's tick box" do
    test "sits beside images only, and keeps the image off the front", %{
      conn: conn,
      board: board,
      card: card
    } do
      image = attach(card, "shot.png")
      pdf = attach(card, "notes.pdf", "application/pdf")

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")

      assert has_element?(view, "#hide-on-card-#{image.id}:not([checked])")
      refute has_element?(view, "#hide-on-card-#{pdf.id}")
      assert has_element?(view, thumb_of(card, image))

      view |> element("#hide-on-card-#{image.id}") |> render_click()

      assert Boards.get_attachment!(image.id).hide_on_card
      assert has_element?(view, "#hide-on-card-#{image.id}[checked]")
      refute has_element?(view, thumb(card))

      # Unticked, it is the thumbnail again.
      view |> element("#hide-on-card-#{image.id}") |> render_click()
      refute Boards.get_attachment!(image.id).hide_on_card
      assert has_element?(view, thumb_of(card, image))
    end

    test "is not for a reader who cannot change the card", %{board: board, card: card} do
      image = attach(card, "shot.png")
      reader = user_fixture("thumbnail.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", board.owner)

      {:ok, view, _} =
        build_conn() |> log_in_user(reader) |> live(~p"/boards/#{board}/cards/#{card.id}")

      assert has_element?(view, "#hide-on-card-#{image.id}[disabled]")

      # Pushed anyway, it changes nothing.
      render_click(with_target(view, "#board-card"), "hide_on_card", %{
        "id" => to_string(image.id),
        "hide" => "true"
      })

      refute Boards.get_attachment!(image.id).hide_on_card
    end
  end

  describe "Attachment.front_image/1" do
    test "is the first image not kept off, never another kind of file" do
      pdf = %Attachment{content_type: "application/pdf", hide_on_card: false}
      kept_off = %Attachment{content_type: "image/png", hide_on_card: true}
      svg = %Attachment{content_type: "image/svg+xml", hide_on_card: false}
      shown = %Attachment{content_type: "image/jpeg", hide_on_card: false}

      assert Attachment.front_image([pdf, kept_off, svg, shown]) == shown
      assert Attachment.front_image([pdf, kept_off, svg]) == nil
      assert Attachment.front_image([]) == nil
      assert Attachment.front_image(nil) == nil
    end
  end
end
