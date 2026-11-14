defmodule SlipdockWeb.PrioritiseLiveTest do
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  alias Slipdock.{Boards, Fields, Votes}

  setup do
    board = board_fixture(%{"name" => "Bets"})
    [backlog | _] = board.columns
    a = card_fixture(backlog, %{"title" => "Alpha"})
    b = card_fixture(backlog, %{"title" => "Beta"})
    c = card_fixture(backlog, %{"title" => "Gamma", "completed" => true})
    %{board: reload(board), a: a, b: b, c: c}
  end

  test "without a scoring model the view ranks by votes and offers presets", %{
    conn: conn,
    board: board,
    a: a,
    b: b
  } do
    {:ok, _} = Votes.set(b, user_fixture(), 2)
    {:ok, view, html} = live(conn, ~p"/boards/#{board}/prioritise")

    assert html =~ "No scoring model yet"
    assert html =~ ~r{<strong>8</strong>\s+of 10}
    assert has_element?(view, "button[phx-click=install_preset][phx-value-key=rice]")

    ranked =
      Regex.scan(~r/id="prio-(\d+)"/, html) |> Enum.map(fn [_, id] -> String.to_integer(id) end)

    assert ranked == [b.id, a.id]
    # Completed cards are hidden by default.
    refute html =~ "Gamma"
  end

  test "votes, priority and fields are edited in place and the ranking follows", %{
    conn: conn,
    board: board,
    a: a,
    b: b
  } do
    {:ok, _} = Fields.install_preset(board, "rice")
    board = reload(board)
    [reach, impact, confidence, effort, rice] = board.fields
    assert rice.kind == "formula"

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/prioritise")
    assert html =~ "Ranked by <strong class=\"text-base-content\">RICE</strong>"

    # A rating star: the button's value carries the number.
    view
    |> element("#prio-field-#{b.id}-#{impact.id} button[value='4']")
    |> render_click()

    assert Fields.value(Boards.Cards.get_card!(b.id), impact) == 4.0

    for {field, value} <- [{reach, "100"}, {confidence, "80"}] do
      view
      |> form("#prio-field-#{b.id}-#{field.id}", %{"value" => value})
      |> render_change()
    end

    # Enter in a field submits the form rather than reloading the page.
    view |> form("#prio-field-#{b.id}-#{effort.id}", %{"value" => "2"}) |> render_submit()
    assert Fields.value(Boards.Cards.get_card!(b.id), effort) == 2.0

    html = render(view)

    ranked =
      Regex.scan(~r/id="prio-(\d+)"/, html) |> Enum.map(fn [_, id] -> String.to_integer(id) end)

    assert ranked == [b.id, a.id]
    assert html =~ "160"

    # Priority through the shared table_update form.
    view |> form("#prio-priority-#{a.id}", %{"value" => "high"}) |> render_change()
    assert Boards.Cards.get_card!(a.id).priority == "high"

    # Votes: + adds one of mine, within the budget.
    view
    |> element("#prio-#{a.id} button[phx-click=prio_vote][phx-value-count='1']")
    |> render_click()

    assert Boards.Cards.get_card!(a.id) |> Slipdock.Boards.Card.vote_total() == 1
    assert render(view) =~ ~r{<strong>9</strong>\s+of 10}

    # Clicking a header sorts explicitly.
    view |> element("#prioritise-table button[phx-value-sort=votes]") |> render_click()
    assert_patch(view)
    assert render(view) =~ "Ranked by <strong class=\"text-base-content\">Votes</strong>"
  end

  test "a placed wiki page is ranked with the cards, and every control is its own", %{
    conn: conn,
    board: board,
    user: user
  } do
    [backlog | _] = board.columns
    page = page_fixture(board, %{"title" => "The spec"})
    {:ok, page} = Slipdock.Wiki.place(page, backlog)
    {:ok, _} = Fields.install_preset(board, "rice")
    board = reload(board)
    [reach | _] = board.fields

    {:ok, view, html} = live(conn, ~p"/boards/#{board}/prioritise")
    assert html =~ "The spec"

    # A page's row is keyed page-7, not 7: the ids share one list but not one
    # space, so a bare number would name somebody else's card.
    assert has_element?(view, "#prio-page-#{page.id}")

    # The title opens the page's panel, not a card that does not exist.
    view |> element("#prio-page-#{page.id} [role=link]", "The spec") |> render_click()
    assert has_element?(view, "#page-panel")

    # Votes, priority and a field value all land on the page.
    view
    |> element("#prio-page-#{page.id} button[phx-click=prio_vote][phx-value-count='1']")
    |> render_click()

    page_votes = Slipdock.Wiki.get_page!(page.id) |> Slipdock.Repo.preload(:votes)
    assert Votes.mine(page_votes, user) == 1

    view |> form("#prio-priority-page-#{page.id}", %{"value" => "high"}) |> render_change()
    assert Slipdock.Wiki.get_page!(page.id).priority == "high"

    view
    |> form("#prio-field-page-#{page.id}-#{reach.id}", %{"value" => "50"})
    |> render_change()

    saved = Slipdock.Wiki.get_page!(page.id) |> Slipdock.Repo.preload(field_values: :field)
    assert Fields.value(saved, reach) == 50.0
  end

  test "read-only viewers can vote but not edit", %{conn: conn, board: board, a: a} do
    stranger = user_fixture("stranger@example.com")
    {:ok, _} = Slipdock.Access.grant(board, stranger, "read", user_fixture())
    {:ok, view, html} = live(log_in_user(conn, stranger), ~p"/boards/#{board}/prioritise")

    refute has_element?(view, "#prio-priority-#{a.id}")
    refute html =~ "install_preset"

    view
    |> element("#prio-#{a.id} button[phx-click=prio_vote][phx-value-count='1']")
    |> render_click()

    assert Votes.mine(Boards.Cards.get_card!(a.id), stranger) == 1
  end

  describe "numbers read as values (#1734)" do
    setup %{board: board, b: b} do
      {:ok, _} = Fields.install_preset(board, "rice")
      {:ok, plain} = Fields.create_field(board, %{"name" => "Size", "kind" => "number"})
      board = reload(board)
      [reach, _impact, confidence, effort, _rice | _] = board.fields

      for {f, v} <- [{reach, "4000"}, {confidence, "80"}, {effort, "0.5"}, {plain, "12"}] do
        {:ok, _} = Fields.set_value(Boards.Cards.get_card!(b.id), f, v)
      end

      %{board: board, reach: reach, confidence: confidence, effort: effort, plain: plain}
    end

    test "each unit is a suffix in the value's own box, sized to the value", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/prioritise")
      field = fn f -> "#prio-field-#{ctx.b.id}-#{f.id}" end

      # Value and unit share one label, the unit straight after the input.
      assert has_element?(
               view,
               "#{field.(ctx.reach)} label.prio-number input[value='4000'] + span[data-unit]",
               "people"
             )

      assert has_element?(view, ~s(#{field.(ctx.reach)} input[style="--prio-chars: 4"]))
      assert has_element?(view, ~s(#{field.(ctx.effort)} input[style="--prio-chars: 3"]))
      assert has_element?(view, "#{field.(ctx.effort)} span[data-unit]", "weeks")
      refute has_element?(view, "#{field.(ctx.reach)} .prio-unit-tight")

      # "%" sits against its number; a field with no unit has no suffix.
      assert has_element?(view, "#{field.(ctx.confidence)} span.prio-unit-tight", "%")
      refute has_element?(view, "#{field.(ctx.plain)} span[data-unit]")
      assert has_element?(view, "#{field.(ctx.plain)} input[aria-label=Size][value='12']")

      # An empty value starts one character wide, with its unit still beside it.
      assert has_element?(
               view,
               ~s(#prio-field-#{ctx.a.id}-#{ctx.reach.id} input[style="--prio-chars: 1"])
             )

      assert has_element?(
               view,
               "#prio-field-#{ctx.a.id}-#{ctx.reach.id} span[data-unit]",
               "people"
             )

      # Editing still saves through the same form.
      view |> form(field.(ctx.reach), %{"value" => "4500"}) |> render_change()
      assert Fields.value(Boards.Cards.get_card!(ctx.b.id), ctx.reach) == 4500.0

      assert has_element?(
               view,
               ~s(#{field.(ctx.reach)} input[style="--prio-chars: 4"][value='4500'])
             )
    end

    test "ranks, votes and scores use the base font, not mono", ctx do
      {:ok, _} = Votes.set(ctx.b, user_fixture(), 2)
      {:ok, view, _html} = live(ctx.conn, ~p"/boards/#{ctx.board}/prioritise")
      row = view |> element("#prio-#{ctx.b.id}") |> render()

      refute row =~ "font-mono"
      assert has_element?(view, ~s(#prio-#{ctx.b.id} [title="Votes from everyone"]), "2")
    end

    test "on a phone the stacked rows use the base font too", ctx do
      {:ok, view, _html} = live(phone(ctx.conn), ~p"/boards/#{ctx.board}/prioritise")
      assert has_element?(view, "ul#prioritise-table li#prio-#{ctx.b.id}")
      refute view |> element("#prio-#{ctx.b.id}") |> render() =~ "font-mono"
      assert has_element?(view, "#prio-#{ctx.b.id} label.prio-number span[data-unit]", "people")
    end

    test "read-only viewers see each value with its unit, as text", ctx do
      stranger = user_fixture("reader1734@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, stranger, "read", user_fixture())

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, stranger), ~p"/boards/#{ctx.board}/prioritise")

      refute has_element?(view, "#prio-#{ctx.b.id} input[type=number]")
      assert has_element?(view, "#prio-#{ctx.b.id} td span", "4000 people")
      assert has_element?(view, "#prio-#{ctx.b.id} td span", "80%")
    end
  end

  test "a date and a text field are edited in place, the date with the app's date field (#2878)",
       %{conn: conn, board: board, a: a} do
    {:ok, due} = Fields.create_field(board, %{"name" => "Due", "key" => "due", "kind" => "date"})

    {:ok, note} =
      Fields.create_field(board, %{"name" => "Note", "key" => "note", "kind" => "text"})

    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/prioritise")
    date_form = "#prio-field-#{a.id}-#{due.id}"

    assert has_element?(view, "#{date_form} .date-field.field-bare[phx-hook=DateField]")
    refute has_element?(view, "#{date_form} > input[type=date]")

    view |> form(date_form, %{"value" => "2030-01-15"}) |> render_change()
    assert Fields.value(Boards.Cards.get_card!(a.id), due) == ~D[2030-01-15]
    assert has_element?(view, "#{date_form} [data-role=date-text]", "15 Jan")

    view |> form("#prio-field-#{a.id}-#{note.id}", %{"value" => "soon"}) |> render_change()
    assert Fields.value(Boards.Cards.get_card!(a.id), note) == "soon"

    # Cleared, the date says so with a dash, as the row's other empty values do.
    view |> form(date_form, %{"value" => ""}) |> render_change()
    assert Fields.value(Boards.Cards.get_card!(a.id), due) == nil
    assert has_element?(view, "#{date_form} [data-role=date-text]", "—")
  end
end
