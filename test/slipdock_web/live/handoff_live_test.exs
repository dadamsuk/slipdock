defmodule SlipdockWeb.HandoffLiveTest do
  @moduledoc """
  A card's handoff in the browser (W-1804): a "Leave a handoff" link on the
  meta line until one is written, then the note just beneath the title, its
  update form and history, who may write it, and the ↩ marker on the card's
  front while the card is open.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards}

  setup %{user: owner} do
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Half done"})
    %{board: board, card: card, owner: owner}
  end

  defp open(conn, ctx), do: live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

  defp leave(ctx, next, body \\ nil),
    do:
      {:ok, _} =
        Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: next, body: body, via: "api"})

  describe "the panel" do
    test "shows the next step, the note, who, how, and the history", ctx do
      leave(ctx, "Write the migration")
      leave(ctx, "Wire up the API", "State: schema done")

      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(view, "#card-handoff #handoff-next", "Wire up the API")
      assert has_element?(view, "#card-handoff #handoff-current", "State: schema done")
      # Shown as written: no template indent before it in a pre-wrap block.
      assert view |> element("#handoff-body") |> render() =~ ~r/>State: schema done</
      assert has_element?(view, "#card-handoff #handoff-current", "· api")
      assert has_element?(view, "#handoff-history summary", "History (2)")
      assert has_element?(view, "#handoff-history", "Write the migration")
      assert has_element?(view, "#card-handoff #handoff-edit", "Update")
      # No link on the meta line once there is one: Update is on the note.
      refute has_element?(view, "#card-title-form #handoff-edit")
    end

    test "sits just beneath the title and its meta line, before flags and description", ctx do
      leave(ctx, "First thing")
      {:ok, _view, html} = open(ctx.conn, ctx)

      {title, _} = :binary.match(html, ~s(id="card-title-form"))
      {panel, _} = :binary.match(html, ~s(id="card-handoff"))
      {rest, _} = :binary.match(html, ~s(id="card-form"))
      assert title < panel and panel < rest
    end

    test "a single note shows no history (the first test shows two do)", ctx do
      leave(ctx, "Only one")
      {:ok, view, _} = open(ctx.conn, ctx)
      refute has_element?(view, "#handoff-history")
    end

    test "with none, there is no panel, only a link on the meta line", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      refute has_element?(view, "#card-handoff")
      refute has_element?(view, "#handoff-history")
      assert has_element?(view, "#card-title-form a#handoff-edit", "Leave a handoff")

      view |> element("#handoff-edit", "Leave a handoff") |> render_click()
      # The form opens beneath the title, with the note's shape as a placeholder,
      # and the link goes while it is open.
      assert has_element?(view, "#card-handoff #handoff-form textarea[placeholder*='Gotchas:']")
      refute has_element?(view, "#card-title-form #handoff-edit")
    end

    test "the form writes a new handoff, as from the UI", ctx do
      leave(ctx, "Old step")
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#handoff-edit") |> render_click()
      # It starts from the current note.
      assert has_element?(view, "#handoff-form input[value='Old step']")

      view
      |> form("#handoff-form", handoff: %{next_step: "Run the suite", body: "Gotchas: seed 42"})
      |> render_submit()

      assert %{next_step: "Run the suite", body: "Gotchas: seed 42", via: "ui"} =
               current = Boards.current_handoff(ctx.card)

      assert current.user_id == ctx.owner.id
      refute has_element?(view, "#handoff-form")
      assert has_element?(view, "#handoff-next", "Run the suite")
      assert has_element?(view, "#handoff-history summary", "History (2)")
    end

    test "a blank next step is refused on the form, and nothing is written", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#handoff-edit") |> render_click()

      html =
        view
        |> form("#handoff-form", handoff: %{next_step: "  ", body: "only a note"})
        |> render_submit()

      assert html =~ "say the one next step"
      assert has_element?(view, "#handoff-form")
      assert Boards.handoff_history(ctx.card) == []
    end

    test "cancel closes the form without writing", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#handoff-edit") |> render_click()
      view |> element("#handoff-form button", "Cancel") |> render_click()
      refute has_element?(view, "#card-handoff")
      assert has_element?(view, "#card-title-form #handoff-edit", "Leave a handoff")
      assert Boards.handoff_history(ctx.card) == []
    end

    test "clear clears it, and the history keeps the clear", ctx do
      leave(ctx, "Going away")
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#handoff-edit") |> render_click()
      view |> element("#handoff-clear") |> render_click()

      assert Boards.current_handoff(ctx.card) == nil
      refute has_element?(view, "#card-handoff")

      # Back to the link; writing a new one shows the history, clear and all.
      view |> element("#card-title-form #handoff-edit") |> render_click()
      assert has_element?(view, "#handoff-form")
      assert has_element?(view, "#handoff-history", "cleared")
      assert has_element?(view, "#handoff-history", "Going away")
    end
  end

  test "a runner's note says it came from a runner and which job", ctx do
    {:ok, _, _} = Slipdock.Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"})
    {:ok, job} = Slipdock.Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "p"})

    {:ok, _} =
      Boards.leave_handoff(ctx.card, nil, %{
        next_step: "From the job",
        via: "runner",
        job_id: job.id
      })

    {:ok, view, _} = open(ctx.conn, ctx)
    assert has_element?(view, "#handoff-current", "a runner")
    assert has_element?(view, "#handoff-current", "· runner · job ##{job.id}")
  end

  describe "who may write it" do
    test "a commenter may", ctx do
      commenter = user_fixture("live.handoff.commenter@example.com")
      {:ok, _} = Access.grant(ctx.board, commenter, "read", ctx.owner)
      {:ok, _} = Access.grant(ctx.card, commenter, "comment", ctx.owner)

      {:ok, view, _} = open(conn_as(commenter), ctx)

      # The link sits in the title's fieldset, disabled for a commenter, so it
      # is a link, not a button; the form it opens is in a fieldset of its own.
      assert has_element?(view, "#card-modal fieldset[disabled] #card-title-form a#handoff-edit")
      view |> element("#handoff-edit") |> render_click()
      assert has_element?(view, "#card-modal fieldset:not([disabled]) #handoff-form")
      view |> form("#handoff-form", handoff: %{next_step: "From a commenter"}) |> render_submit()

      assert %{next_step: "From a commenter"} = Boards.current_handoff(ctx.card)
    end

    test "a reader sees it but has no button, and the server refuses the event", ctx do
      reader = user_fixture("live.handoff.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      leave(ctx, "Owner's step")

      {:ok, view, _} = open(conn_as(reader), ctx)

      assert has_element?(view, "#handoff-next", "Owner's step")
      refute has_element?(view, "#handoff-edit")

      view
      |> with_target("#board-card")
      |> render_submit("leave_handoff", %{"handoff" => %{"next_step" => "Sneaked"}})

      view |> with_target("#board-card") |> render_click("clear_handoff", %{})

      assert %{next_step: "Owner's step"} = Boards.current_handoff(ctx.card)
    end

    test "a reader sees no panel on a card with no handoff", ctx do
      reader = user_fixture("live.handoff.reader2@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

      {:ok, view, _} = open(conn_as(reader), ctx)
      refute has_element?(view, "#card-handoff")
      refute has_element?(view, "#handoff-edit")
    end
  end

  describe "the card's front" do
    test "marks an open card with a handoff, the next step as the tooltip", ctx do
      leave(ctx, "Pick up the tests")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(
               view,
               "#card-#{ctx.card.id} [data-role=handoff-mark][title='Left off — next: Pick up the tests']"
             )
    end

    test "no mark once the card is completed, nor after a clear, nor with none", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Cleared"})
      plain = card_fixture(hd(ctx.board.columns), %{"title" => "Plain"})
      leave(ctx, "Will be done")
      {:ok, _} = Boards.leave_handoff(other, ctx.owner, %{next_step: "x", via: "ui"})
      {:ok, _} = Boards.clear_handoff(other, ctx.owner, %{via: "ui"})
      {:ok, _} = Boards.update_card(ctx.card, %{"completed" => true})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      for card <- [ctx.card, other, plain] do
        assert has_element?(view, "#card-#{card.id}")
        refute has_element?(view, "#card-#{card.id} [data-role=handoff-mark]")
      end

      # The note itself is kept, and the card's panel still shows it.
      assert %{next_step: "Will be done"} = Boards.current_handoff(ctx.card)
    end
  end
end
