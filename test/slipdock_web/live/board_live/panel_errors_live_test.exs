defmodule SlipdockWeb.BoardLive.PanelErrorsLiveTest do
  @moduledoc """
  The panel notices built from a changeset (#2873), each driven from its
  form: a validation message with a placeholder reads with the number in
  it, never as `%{count}`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Recurrence}

  setup %{user: user} do
    {:ok, user} = Accounts.update_profile(user, %{"timezone" => "Europe/London"})
    board = board_fixture(%{"name" => "Panel errors"}, owner: user)
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Notice card", "due_date" => "2027-01-12"})
    %{user: user, board: board, card: card}
  end

  test "an upload with too long a filename says the limit", ctx do
    Slipdock.TestConfig.own_uploads_dir()
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    name = String.duplicate("a", 252) <> ".pdf"

    view
    |> file_input("#attach-form", :attachment, [
      %{name: name, content: "%PDF-1.4 fake", type: "application/pdf"}
    ])
    |> render_upload(name)

    assert render(view) =~ "Upload failed: filename should be at most 255 character(s)."
    assert Boards.Cards.get_card!(ctx.card.id).attachments == []
  end

  test "a template from a board whose name is too long says the limit", ctx do
    {:ok, board} =
      Boards.update_board(ctx.board, %{"name" => String.duplicate("Long name ", 7)})

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{board}/settings")
    view |> element("button[phx-click=save_as_template]") |> render_click()

    assert render(view) =~
             "Couldn&#39;t save a template: name should be at most 60 character(s)."
  end

  test "a repeat that ends after too many times says the limit", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
    view |> element("#repeat-edit") |> render_click()

    view
    |> form("#repeat-form", repeat: %{preset: "FREQ=DAILY", ends: "after"})
    |> render_change()

    view
    |> form("#repeat-form", repeat: %{preset: "FREQ=DAILY", ends: "after", count: "5000"})
    |> render_submit()

    assert has_element?(view, "#repeat-error", "count must be less than or equal to 1000")
    assert Recurrence.for_card(ctx.card) == nil
  end

  test "an incident missed by a check that isn't one says Missed by", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

    view
    |> element("#incident-form-#{ctx.card.id}")
    |> render_submit(%{"incident" => %{"caused_by" => "", "missed_by" => "luck"}})

    assert has_element?(
             view,
             "#card-incident #incident-error",
             "Missed by must be one of the checks:"
           )
  end
end
