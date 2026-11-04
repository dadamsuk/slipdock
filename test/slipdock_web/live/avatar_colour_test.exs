defmodule SlipdockWeb.AvatarColourTest do
  @moduledoc """
  Avatars (#1696): a person's initials in their own colour, the same on the
  card face, the outline, My work, the card back, the header, a share list
  and their comments. The colour's contrast is tested from the palette in
  `Slipdock.PaletteTest`; here, that every surface draws the same one.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Palette}
  alias Slipdock.Accounts.User
  alias SlipdockWeb.SlipdockComponents

  setup %{user: user} do
    board = board_fixture(%{"name" => "Colours", "code" => "colr1696"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Paint the shed"})
    {:ok, card} = Boards.update_card(card, %{"assignee_id" => user.id})
    {:ok, _} = Boards.add_comment(card, "First coat done", by: user)
    %{board: board, card: card, colour: Palette.person_colour(user.id)}
  end

  defp avatar_html(assigns), do: rendered_to_string(~H"<SlipdockComponents.avatar {assigns} />")

  describe "avatar/1" do
    test "draws two initials in the person's colour" do
      user = %User{id: 7, email: "ada.lovelace@example.com", name: "Ada Lovelace"}
      html = avatar_html(%{user: user})

      assert html =~ ~r/>\s*AL\s*</
      assert html =~ ~s(data-colour="#{Palette.person_colour(7)}")
      assert html =~ Palette.person(7)
      assert html =~ "size-6 text-2xs"
    end

    test "at xs, one initial, at the 2xs size, with no pixel literal" do
      user = %User{id: 7, email: "ada@example.com", name: "Ada Lovelace"}
      html = avatar_html(%{user: user, size: "xs"})

      assert html =~ ~r/>\s*A\s*</
      refute html =~ ~r/>\s*AL\s*</
      assert html =~ "size-4 text-2xs"
      refute html =~ ~r/text-\[\d+px\]/
    end

    test "nobody is a slate ?" do
      html = avatar_html(%{user: nil, size: "md"})
      assert html =~ ~r/>\s*\?\s*</
      assert html =~ ~s(data-colour="slate")
      assert html =~ "size-8 text-xs"
    end

    test "the old white-on-white classes are gone" do
      html = avatar_html(%{user: %User{id: 3, email: "x@example.com"}})
      refute html =~ "text-secondary-content"
      refute html =~ "bg-secondary/20"
    end

    test "no avatar code has a pixel-size literal" do
      source = File.read!("lib/slipdock_web/components/slipdock_components.ex")

      [chips] =
        Regex.run(~r/## Assignees.*?## Due dates/s, source)

      refute chips =~ ~r/text-\[\d+px\]/
    end
  end

  defp colours(html) do
    ~r/class="avatar-initials[^"]*"[^>]*data-colour="([a-z]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "the card face, outline and My work draw the assignee in their colour", %{
    conn: conn,
    board: board,
    colour: colour
  } do
    for path <- [~p"/boards/#{board}", ~p"/boards/#{board}/outline", ~p"/work"] do
      {:ok, _view, html} = live(conn, path)
      assert colour in colours(html), "#{path} shows #{inspect(colours(html))}"
    end
  end

  test "the card back's assignee and comment, and the header, are the same colour", %{
    conn: conn,
    board: board,
    card: card,
    colour: colour
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/cards/#{card}")

    assert has_element?(view, "#account-menu .avatar-initials[data-colour=#{colour}]")
    assert has_element?(view, "[id^=comment-] .avatar-initials[data-colour=#{colour}]")
    # Every avatar on the page is this one person.
    assert colours(render(view)) == [colour]
  end

  test "each person is drawn in the colour of their own id" do
    # Two ids the hash puts on different colours, so the check means something.
    [a, b] =
      Enum.find_value(1..50, fn i ->
        if Palette.person_colour(i) != Palette.person_colour(i + 1), do: [i, i + 1]
      end)

    html =
      avatar_html(%{user: %User{id: a, email: "a@example.com"}}) <>
        avatar_html(%{user: %User{id: b, email: "b@example.com"}})

    assert colours(html) == [Palette.person_colour(a), Palette.person_colour(b)]
  end

  test "a share list draws a person in their colour, and a group as an icon", %{user: user} do
    grants = [
      %Slipdock.Access.Grant{id: 1, user_id: user.id, user: user, level: "write"},
      %Slipdock.Access.Grant{
        id: 2,
        group_id: 9,
        group: %Slipdock.Accounts.Group{id: 9, name: "Painters"},
        level: "read"
      }
    ]

    html =
      render_component(&SlipdockWeb.ShareComponents.share_panel/1,
        resource: "board",
        grants: grants,
        groups: [],
        can_manage: false,
        form_key: 0
      )

    assert colours(html) == [Palette.person_colour(user.id)]
    assert html =~ "hero-user-group"
    assert html =~ "Painters"
  end
end
