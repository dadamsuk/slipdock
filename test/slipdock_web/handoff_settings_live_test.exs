defmodule SlipdockWeb.HandoffSettingsLiveTest do
  @moduledoc """
  A board's own name for "Left off" and its own drafting instructions
  (#1212): set on the settings form and over the API, and used on the card's
  front, in its panel, its form and the Display menu, and by Auto generate.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{conn: conn, user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Half done"})
    {:ok, _} = Boards.leave_handoff(card, owner, %{next_step: "Write the tests", via: "ui"})

    %{
      board: board,
      card: card,
      owner: owner,
      json: put_req_header(conn, "accept", "application/json")
    }
  end

  defp name(ctx, label) do
    {:ok, board} = Boards.update_board(ctx.board, %{"handoff_label" => label})
    board
  end

  test "the settings form sets both, shows the defaults as placeholders, and refuses too long",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/settings")

    assert has_element?(view, "#board-handoff-label[placeholder='Left off']")
    assert has_element?(view, "#board-handoff-prompt[placeholder*='Gotchas:']")

    view
    |> form("#board-form", board: %{"handoff_label" => String.duplicate("x", 41)})
    |> render_submit()

    assert render(view) =~ "should be at most 40 character"
    assert Boards.get_board!(ctx.board.id).handoff_label == nil

    view
    |> form("#board-form",
      board: %{"handoff_label" => "Parked", "handoff_prompt" => "Be brief."}
    )
    |> render_submit()

    board = Boards.get_board!(ctx.board.id)
    assert board.handoff_label == "Parked" and board.handoff_prompt == "Be brief."
  end

  test "the card's front and its panel use the board's name for it", ctx do
    name(ctx, "Parked")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?handoff=full")

    assert has_element?(
             view,
             "#card-#{ctx.card.id} [data-role=handoff-mark][title='Parked — next: Write the tests']"
           )

    html = view |> element("#card-#{ctx.card.id} [data-role=handoff-note]") |> render()
    assert html =~ "Parked:</span> Write the tests"
    refute html =~ "Left off"

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?handoff=short")
    assert has_element?(view, "[data-role=handoff-note]", "Parked:")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    assert has_element?(view, "#card-handoff #handoff-label", "Parked — next:")
  end

  test "every word a person reads about it in the web app is the board's name (#1214)", ctx do
    name(ctx, "Parked")

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    assert view |> element("#handoff-delete") |> render() =~
             "Delete this “Parked”? It goes from the history too"

    view |> element("#card-handoff #handoff-edit") |> render_click()
    assert has_element?(view, "#handoff-form-title", "Parked")
    assert has_element?(view, "#handoff-save", "Save “Parked”")

    assert view |> element("#handoff-clear") |> render() =~
             "Clear “Parked”? The history keeps it."

    refute view |> element("#card-handoff") |> render() =~ "Left off"

    # With none, the meta line's link says it too.
    {:ok, _} = Boards.clear_handoff(ctx.card, ctx.owner, %{via: "ui"})
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    assert has_element?(view, "#card-title-form #handoff-edit", "Add “Parked”")

    # And the Display menu, on the board and in swimlanes.
    for path <- [~p"/boards/#{ctx.board}", ~p"/boards/#{ctx.board}/swimlanes"] do
      {:ok, view, _} = live(ctx.conn, path)
      assert view |> element("#display-handoff p", "Parked") |> has_element?()
      refute view |> element("#display-handoff") |> render() =~ "Handoff note"
    end
  end

  test "without one, it is still Left off in the panel", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    assert has_element?(view, "#card-handoff #handoff-label", "Left off — next:")
  end

  test "Auto generate tells the model the board's own instructions", ctx do
    {:ok, _} = Boards.update_board(ctx.board, %{"handoff_prompt" => "Write it as a haiku."})
    Slipdock.AIStub.reply_with(%{"next_step" => "Ship it", "body" => ""})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    view |> element("#card-handoff #handoff-edit") |> render_click()
    view |> element("#handoff-draft", "Auto generate") |> render_click()
    render_async(view)

    assert_received {:ai_request, %{"messages" => [%{"content" => system}, _]}}
    assert String.starts_with?(system, "Write it as a haiku.")
    assert system =~ ~s("next_step")
  end

  test "the API reads and sets both, and \"\" goes back to the defaults", ctx do
    body = ctx.json |> get(~p"/api/boards/#{ctx.board.code}") |> json_response(200)
    assert body["board"]["handoff_label"] == "Left off"
    assert body["board"]["handoff_prompt"] == nil

    body =
      ctx.json
      |> patch(~p"/api/boards/#{ctx.board.code}", %{
        "handoff_label" => "Parked",
        "handoff_prompt" => "Be brief."
      })
      |> json_response(200)

    assert body["board"]["handoff_label"] == "Parked"
    assert body["board"]["handoff_prompt"] == "Be brief."

    ctx.json
    |> patch(~p"/api/boards/#{ctx.board.code}", %{"handoff_label" => "", "handoff_prompt" => ""})
    |> json_response(200)

    board = Boards.get_board!(ctx.board.id)
    assert board.handoff_label == nil and board.handoff_prompt == nil

    assert ctx.json
           |> patch(~p"/api/boards/#{ctx.board.code}", %{
             "handoff_label" => String.duplicate("x", 41)
           })
           |> json_response(422)
  end
end
