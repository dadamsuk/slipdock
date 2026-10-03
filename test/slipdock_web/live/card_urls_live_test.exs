defmodule SlipdockWeb.CardUrlsLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.Boards
  alias Slipdock.Boards.CardUrl

  setup do
    board = board_fixture(%{"name" => "Roadmap"})
    card = card_fixture(hd(board.columns), %{"title" => "Query parser"})
    %{board: board, card: card}
  end

  describe "the card's web links" do
    test "a link is added, datestamped, and removed", %{conn: conn, board: board, card: card} do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/cards/#{card}")
      assert html =~ "Nothing linked yet"

      html =
        view
        |> form("#card-url-form-0", %{"url" => "example.com/spec", "title" => "The spec"})
        |> render_submit()

      assert html =~ "The spec"
      assert html =~ Calendar.strftime(DateTime.utc_now(), "%-d %b %Y")

      # A bare address is taken to be a web one.
      assert [%CardUrl{url: "https://example.com/spec", title: "The spec"} = url] =
               Boards.get_card!(card.id).urls

      assert html =~ ~s{href="https://example.com/spec"}

      refute render_click(view, "remove_card_url", %{"id" => url.id}) =~ "The spec"
      assert Boards.get_card!(card.id).urls == []
    end

    test "an address that is not one is refused", %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

      html =
        view
        |> form("#card-url-form-0", %{"url" => "javascript:alert(1)", "title" => ""})
        |> render_submit()

      assert html =~ "must be a web, file or mail address"
      assert Boards.get_card!(card.id).urls == []
    end

    test "a link with no label is shown as its address, tidied", %{card: card} do
      {:ok, url} = Boards.add_card_url(card, %{"url" => "https://www.example.com/docs/spec/"})
      assert CardUrl.label(url) == "example.com/docs/spec"
    end

    test "the section carries its own key", %{conn: conn, board: board, card: card} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")
      assert has_element?(view, ~s{#card-urls[data-section-key="w"]})
    end

    test "files and addresses keep their scheme", %{card: card} do
      {:ok, file} = Boards.add_card_url(card, %{"url" => "file:///srv/share/plan.xlsx"})
      {:ok, mail} = Boards.add_card_url(card, %{"url" => "mailto:team@example.com"})

      assert CardUrl.kind(file) == :file
      assert CardUrl.kind(mail) == :mail
      assert file.url == "file:///srv/share/plan.xlsx"
    end
  end

  describe "the API" do
    test "adds, lists and removes a card's web links", %{conn: conn, card: card} do
      conn =
        post(conn, ~p"/api/cards/#{card}/urls", %{
          "url" => "https://example.com/rfc",
          "title" => "RFC"
        })

      assert %{"id" => id, "url" => "https://example.com/rfc", "label" => "RFC", "added_at" => at} =
               json_response(conn, 201)["url"]

      assert at

      conn = get(conn, ~p"/api/cards/#{card}")
      assert [%{"id" => ^id, "title" => "RFC"}] = json_response(conn, 200)["card"]["urls"]

      conn = delete(conn, ~p"/api/cards/#{card}/urls/#{id}")
      assert json_response(conn, 200) == %{"ok" => true}
      assert Boards.get_card!(card.id).urls == []
    end

    test "a link belonging to another card is not this one's to remove", %{conn: conn, card: card} do
      other = card_fixture(hd(board_fixture(%{"name" => "Other"}).columns), %{"title" => "Else"})
      {:ok, url} = Boards.add_card_url(other, %{"url" => "https://example.com"})

      conn = delete(conn, ~p"/api/cards/#{card}/urls/#{url.id}")
      assert json_response(conn, 404)["error"] == "link not found"
    end

    test "a bad address is refused", %{conn: conn, card: card} do
      conn = post(conn, ~p"/api/cards/#{card}/urls", %{"url" => "not a url at all"})
      assert json_response(conn, 422)["error"] == "validation failed"
    end
  end
end
