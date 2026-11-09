defmodule SlipdockWeb.VerifyRejectionLimitLiveTest do
  @moduledoc """
  The rejection limit's surfaces (#1779): board settings (shown with verify
  on), REST's board update and JSON, and the 0..50 range.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.Boards

  setup %{user: user} do
    board = board_fixture(%{"name" => "Limits", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true})
    %{board: board}
  end

  test "board settings show the limit with verify on, and save it", ctx do
    {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
    assert has_element?(view, "#board-verify-rejection-limit[value='2']")
    assert render(view) =~ "Rejections before a person decides"

    view |> form("#agentic-form", board: %{"verify_rejection_limit" => "0"}) |> render_submit()
    assert Boards.get_board!(ctx.board.id).verify_rejection_limit == 0

    {:ok, _} = Boards.update_board(Boards.get_board!(ctx.board.id), %{"verify_work" => false})
    {:ok, view, _} = live(ctx.conn, agentic_path(ctx.board))
    refute has_element?(view, "#board-verify-rejection-limit")
  end

  test "REST sets it and shows it; out of range is refused", ctx do
    conn = ctx.conn |> put_req_header("accept", "application/json")

    json =
      conn
      |> patch(~p"/api/boards/#{ctx.board.code}", %{"verify_rejection_limit" => 4})
      |> json_response(200)

    assert json["board"]["verify_rejection_limit"] == 4
    assert Boards.get_board!(ctx.board.id).verify_rejection_limit == 4

    for bad <- [-1, 51] do
      assert %{"details" => %{"verify_rejection_limit" => [msg]}} =
               conn
               |> patch(~p"/api/boards/#{ctx.board.code}", %{"verify_rejection_limit" => bad})
               |> json_response(422)

      assert msg == "must be 0 (no limit) to 50"
    end

    assert Boards.get_board!(ctx.board.id).verify_rejection_limit == 4
  end

  test "the guide, docs/agents.md and the manual describe it", ctx do
    guide = SlipdockWeb.APIGuide.markdown(user: ctx.user) |> String.replace(~r/\s+/, " ")
    assert guide =~ "Past the board's `verify_rejection_limit` (2 by default, 0 never)"

    agents = Slipdock.DocsText.read!("docs/agents.md") |> String.replace(~r/\s+/, " ")
    assert agents =~ "`verify_rejection_limit` (2 by default, 0 never;"

    manual = Slipdock.DocsText.read!("docs/manual.md") |> String.replace(~r/\s+/, " ")
    assert manual =~ "**Too many rejections go to a person.**"
    assert manual =~ "--verify-rejection-limit 2"
    assert manual =~ "*Rework as rejected* (or any other answer, or skipping)"
    # #1777's four checks and #1778's parts, in the manual too.
    assert manual =~ "**The verdict in parts.**"
    assert manual =~ "The verifier judges four things in order"
  end
end
