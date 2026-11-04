defmodule SlipdockWeb.PlainWordsTest do
  @moduledoc """
  UI copy that says what to do rather than how it works (#1699): the
  automations rule row, the card back's Health, Tidy up and the board
  settings' Hotkey. The sign-in strapline is in `LoginWordingTest` and the
  Users intro in `UsersLiveTest`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Automations

  setup %{user: user} do
    board = board_fixture(%{"name" => "Wording", "code" => "words1699"}, owner: user)
    [_backlog, doing | _] = board.columns
    card = card_fixture(doing, %{"title" => "Say it plainly"})
    %{board: board, doing: doing, card: card}
  end

  describe "the automations rule row" do
    test "reads in plain English, with no rule kind chip", %{conn: conn, board: board, user: user} do
      {:ok, _} =
        Automations.create_rule_from_preset(
          board,
          "stale",
          %{"column" => "In Progress", "days" => "5", "notify" => "alert"},
          created_by: user
        )

      {:ok, _} =
        Automations.create_rule_from_preset(
          board,
          "review_emailed_cards",
          %{"column" => "In Progress", "flag" => "flagged"},
          created_by: user
        )

      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/automations")
      rows = view |> element("ul:has(> li[id^=rule-])") |> render()

      assert rows =~ "and it is still open, raise an info alert."
      assert rows =~ ", flag it."
      refute rows =~ "completed is false"
      refute rows =~ "flag it flagged"

      # The kind is only in the spec under "What this does, exactly".
      refute rows =~ ~r/<span class="chip chip-line">\s*card_stale\s*<\/span>/
      assert rows =~ "What this does, exactly"
      assert rows =~ ~r/<pre[^>]*>[^<]*card_stale/
      outside = String.replace(rows, ~r/<pre[^>]*>.*?<\/pre>/s, "")
      refute outside =~ "card_stale"
      refute outside =~ "card_emailed"
    end
  end

  describe "the card back's Health" do
    test "explains the pill in a tooltip, not on the page", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/cards/#{card}")

      refute html =~ "The first pill is computed"
      assert has_element?(view, ~s(#card-status [aria-describedby="card-health-about"]))

      assert has_element?(
               view,
               ~s(#card-health-about[title="Worked out from the card's dates, blockers and subcards."])
             )

      # The words are there for a screen reader, hidden from sight.
      assert has_element?(view, "#card-health-about .sr-only", "Worked out from")
      refute has_element?(view, "#card-status p")
    end

    test "with a reported health too, the tooltip says what each pill is", %{
      conn: conn,
      board: board,
      card: card
    } do
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card}")

      view
      |> form("#status-form-0", %{"health" => "at_risk", "body" => "Waiting on legal"})
      |> render_submit()

      assert has_element?(view, ~s(#card-health-about[title^="The first is worked out"]))

      assert has_element?(
               view,
               ~s(#card-health-about[title$="The second is what was last reported."])
             )
    end
  end

  describe "Tidy up" do
    test "has a title, a one-line description, and the action in its empty state", %{
      conn: conn,
      board: board
    } do
      {:ok, view, html} = live(conn, ~p"/boards/#{board}/tidy")

      assert has_element?(view, "#garden-title h1", "Tidy up")
      assert has_element?(view, "#garden-title p", "Nothing changes until you apply one.")
      refute html =~ "over for rot"
      refute html =~ "The gardener looks"

      assert has_element?(view, "#garden-empty h2", "Nothing to tidy")
      assert has_element?(view, "#garden-empty #garden-empty-run", "Look the board over")

      # The empty state's button runs the gardener like the header's does.
      view |> element("#garden-empty-run") |> render_click()
      assert has_element?(view, "#garden-empty", "Every suggestion has been dealt with.")
    end

    test "a reader gets the empty state without the action", %{board: board, user: user} do
      reader = user_fixture("tidy.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(board, reader, "read", user)
      {:ok, view, _} = live(conn_as(reader), ~p"/boards/#{board}/tidy")

      assert has_element?(view, "#garden-empty")
      refute has_element?(view, "#garden-empty-run")
    end
  end

  test "the hotkey hint reads as two plain sentences", %{conn: conn, board: board} do
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/settings")

    refute html =~ "The digit is yours alone"
    refute html =~ "picking one another board or your wiki has"
    assert html =~ "Only you see your digits."

    assert html =~
             ~r/Picking one that another board\s+or your wiki already has moves it to this board\./
  end
end
