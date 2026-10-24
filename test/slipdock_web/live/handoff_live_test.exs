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
      assert has_element?(view, "#card-title-form a#handoff-edit", "Add “Left off”")

      view |> element("#handoff-edit", "Add “Left off”") |> render_click()
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
      assert has_element?(view, "#card-title-form #handoff-edit", "Add “Left off”")
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

  describe "deleting (#1214)" do
    test "Delete removes it outright, and the one before it shows again", ctx do
      leave(ctx, "Earlier step")
      leave(ctx, "A wrong turn")
      {:ok, view, _} = open(ctx.conn, ctx)

      assert has_element?(view, "#handoff-current #handoff-delete", "Delete")
      assert view |> element("#handoff-delete") |> render() =~ "data-confirm"

      view |> element("#handoff-delete") |> render_click()

      assert has_element?(view, "#handoff-next", "Earlier step")
      refute has_element?(view, "#card-handoff", "A wrong turn")
      assert [%{next_step: "Earlier step"}] = Boards.handoff_history(ctx.card)

      # The last one: no panel, only the meta line's link.
      view |> element("#handoff-delete") |> render_click()
      refute has_element?(view, "#card-handoff")
      assert has_element?(view, "#card-title-form #handoff-edit")
      assert Boards.handoff_history(ctx.card) == []
    end

    test "a commenter may delete their own, not the owner's", ctx do
      commenter = user_fixture("live.handoff.deleter@example.com")
      {:ok, _} = Access.grant(ctx.board, commenter, "read", ctx.owner)
      {:ok, _} = Access.grant(ctx.card, commenter, "comment", ctx.owner)
      leave(ctx, "Owner's step")

      {:ok, view, _} = open(conn_as(commenter), ctx)
      assert has_element?(view, "#handoff-edit")
      refute has_element?(view, "#handoff-delete")

      view |> with_target("#board-card") |> render_click("delete_handoff", %{})
      assert %{next_step: "Owner's step"} = Boards.current_handoff(ctx.card)

      {:ok, _} =
        Boards.leave_handoff(ctx.card, commenter, %{next_step: "Commenter's", via: "ui"})

      {:ok, view, _} = open(conn_as(commenter), ctx)
      view |> element("#handoff-delete") |> render_click()
      assert %{next_step: "Owner's step"} = Boards.current_handoff(ctx.card)
    end

    test "a reader has no Delete, and the server refuses the event", ctx do
      reader = user_fixture("live.handoff.reader3@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      leave(ctx, "Owner's step")

      {:ok, view, _} = open(conn_as(reader), ctx)
      refute has_element?(view, "#handoff-delete")
      view |> with_target("#board-card") |> render_click("delete_handoff", %{})
      assert %{next_step: "Owner's step"} = Boards.current_handoff(ctx.card)
    end
  end

  describe "the note and the history (#1214)" do
    test "the note is Markdown, as a comment is", ctx do
      leave(ctx, "Go on", "- done: `the schema`\n- see [the spec](https://example.com/spec)")
      {:ok, view, _} = open(ctx.conn, ctx)

      html = view |> element("#handoff-body") |> render()
      assert html =~ "<li>"
      assert html =~ "<code>the schema</code>"
      assert html =~ ~s(href="https://example.com/spec")
    end

    test "raw HTML in the note is shown, not obeyed", ctx do
      leave(ctx, "Go on", "<script>alert(1)</script>")
      {:ok, view, _} = open(ctx.conn, ctx)
      refute view |> element("#handoff-body") |> render() =~ "<script>"
    end

    test "each entry opens to its note", ctx do
      leave(ctx, "Earlier", "State: half way")
      leave(ctx, "Now")
      {:ok, view, _} = open(ctx.conn, ctx)

      [earlier, _] = Enum.reverse(Boards.handoff_history(ctx.card))
      assert has_element?(view, "#handoff-#{earlier.id} details", "State: half way")
    end

    test "Restore makes an earlier one current again, as a new entry", ctx do
      leave(ctx, "Earlier", "State: half way")
      leave(ctx, "A wrong turn")
      {:ok, view, _} = open(ctx.conn, ctx)

      [current, earlier] = Boards.handoff_history(ctx.card)
      refute has_element?(view, "#handoff-#{current.id} button", "Restore")

      view |> element("#handoff-#{earlier.id} button", "Restore") |> render_click()

      assert has_element?(view, "#handoff-next", "Earlier")
      assert [restored, ^current, ^earlier] = Boards.handoff_history(ctx.card)
      assert %{next_step: "Earlier", body: "State: half way", via: "ui"} = restored
      assert restored.user_id == ctx.owner.id
    end

    test "after a clear, the old one can be restored; the clear can't", ctx do
      leave(ctx, "Before the clear")
      {:ok, clear} = Boards.clear_handoff(ctx.card, ctx.owner, %{via: "ui"})
      {:ok, view, _} = open(ctx.conn, ctx)

      view |> element("#card-title-form #handoff-edit") |> render_click()
      refute has_element?(view, "#handoff-#{clear.id} button", "Restore")
      [_, old] = Boards.handoff_history(ctx.card)
      view |> element("#handoff-#{old.id} button", "Restore") |> render_click()

      assert %{next_step: "Before the clear"} = Boards.current_handoff(ctx.card)
    end

    test "an id that isn't one of this card's, or a clear, is refused", ctx do
      leave(ctx, "Mine")
      {:ok, clear} = Boards.clear_handoff(ctx.card, ctx.owner, %{via: "ui"})
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
      {:ok, theirs} = Boards.leave_handoff(other, ctx.owner, %{next_step: "Other's", via: "ui"})
      {:ok, view, _} = open(ctx.conn, ctx)

      for id <- [theirs.id, clear.id, "nope"] do
        view |> with_target("#board-card") |> render_click("restore_handoff", %{"id" => id})
        assert render(view) =~ "That one can&#39;t be restored."
      end

      assert Boards.current_handoff(ctx.card) == nil
    end

    test "a reader sees the history but no Restore, and the event is refused", ctx do
      reader = user_fixture("live.handoff.reader4@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      leave(ctx, "Earlier")
      leave(ctx, "Now")
      [_, earlier] = Boards.handoff_history(ctx.card)

      {:ok, view, _} = open(conn_as(reader), ctx)
      assert has_element?(view, "#handoff-#{earlier.id}")
      refute has_element?(view, "#handoff-history button", "Restore")

      view
      |> with_target("#board-card")
      |> render_click("restore_handoff", %{"id" => earlier.id})

      assert %{next_step: "Now"} = Boards.current_handoff(ctx.card)
    end
  end

  describe "Auto generate (#1099)" do
    test "fills the form from the model's draft and writes nothing until saved", ctx do
      Slipdock.AIStub.reply_with(%{
        "next_step" => "Fix the flaky upload test",
        "body" => "State: API done\nGotchas: seed 42"
      })

      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#handoff-edit") |> render_click()
      view |> element("#handoff-draft", "Auto generate") |> render_click()

      html = render_async(view)
      assert html =~ "Drafted from the card"
      assert has_element?(view, "#handoff-form input[value='Fix the flaky upload test']")
      assert has_element?(view, "#handoff-form textarea", "Gotchas: seed 42")
      assert Boards.handoff_history(ctx.card) == []

      # What the model was told is about this card.
      assert_received {:ai_request, %{"messages" => [_, %{"content" => content}]}}
      assert content =~ "“Half done”"

      view
      |> form("#handoff-form",
        handoff: %{next_step: "Fix the flaky upload test", body: "State: API done"}
      )
      |> render_submit()

      assert %{next_step: "Fix the flaky upload test", via: "ui"} =
               Boards.current_handoff(ctx.card)
    end

    test "says why when the model gives no next step, and the form keeps what it had", ctx do
      leave(ctx, "Keep me")
      Slipdock.AIStub.reply_with(%{"body" => "nothing useful"})

      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#handoff-edit") |> render_click()
      view |> element("#handoff-draft") |> render_click()
      render_async(view)

      assert has_element?(view, "#handoff-draft-error", "didn't suggest a next step")
      assert has_element?(view, "#handoff-form input[value='Keep me']")
    end

    test "is not offered without an AI model, and the event asks no model", ctx do
      Slipdock.TestConfig.merge(:ai, api_key: nil)

      {:ok, view, _} = open(ctx.conn, ctx)
      view |> element("#handoff-edit") |> render_click()
      refute has_element?(view, "#handoff-draft")

      # Sent anyway (a page loaded before the key went), no model is asked.
      view |> with_target("#board-card") |> render_click("draft_handoff", %{})
      refute_received {:ai_request, _}
      refute render(view) =~ "Generating…"
    end

    test "a commenter may use it; a reader may not", ctx do
      Slipdock.AIStub.reply_with(%{"next_step" => "From the model", "body" => ""})
      commenter = user_fixture("live.handoff.drafter@example.com")
      {:ok, _} = Access.grant(ctx.board, commenter, "read", ctx.owner)
      {:ok, _} = Access.grant(ctx.card, commenter, "comment", ctx.owner)

      {:ok, view, _} = open(conn_as(commenter), ctx)
      view |> element("#handoff-edit") |> render_click()
      view |> element("#handoff-draft") |> render_click()
      render_async(view)
      assert has_element?(view, "#handoff-form input[value='From the model']")

      reader = user_fixture("live.handoff.drafter.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)
      {:ok, rview, _} = open(conn_as(reader), ctx)
      rview |> with_target("#board-card") |> render_click("draft_handoff", %{})
      refute has_element?(rview, "#handoff-form")
      refute has_element?(rview, "#handoff-draft-error")
    end

    test "only while the form is open", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)
      view |> with_target("#board-card") |> render_click("draft_handoff", %{})
      refute has_element?(view, "#handoff-form")
      refute_received {:ai_request, _}
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

  describe "the meta line's actions look like buttons (#1230)" do
    test "for a writer, each action is a meta-action and the plain text is not", ctx do
      {:ok, view, _} = open(ctx.conn, ctx)

      line = "#card-title-form div.flex-wrap"
      assert has_element?(view, "#{line} button#card-move-board.meta-action", "another board")
      assert has_element?(view, "#{line} a#handoff-edit.meta-action", "Add “Left off”")
      assert has_element?(view, "#{line} a#wait-ask.meta-action", "Ask questions")

      # Exactly those three; the words around them stay words, without the
      # dots that used to set the links apart.
      html = view |> element(line) |> render()
      assert length(Regex.scan(~r/class="meta-action"/, html)) == 3
      assert has_element?(view, "#{line} > span", "created")
      refute has_element?(view, "#{line} span.meta-action")
      refute html =~ ~r/<span>·<\/span>/
    end

    test "a reader, with nothing to press, sees none", ctx do
      reader = user_fixture("live.handoff.meta.reader@example.com")
      {:ok, _} = Access.grant(ctx.board, reader, "read", ctx.owner)

      {:ok, view, _} = open(conn_as(reader), ctx)

      assert has_element?(view, "#card-title-form", "created")
      refute has_element?(view, "#card-title-form .meta-action")
    end
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

  describe "the note on the card's front (#1171)" do
    alias Slipdock.Swimlanes.Config

    test "is a Display setting: off by default, two lines or full, kept in the URL" do
      assert %Config{}.handoff == "hide"
      assert Enum.map(Config.handoffs(), &elem(&1, 0)) == ~w(hide short full)
      assert Config.from_query(%{"handoff" => "full"}).handoff == "full"
      assert Config.from_query(%{"handoff" => "everything"}).handoff == "hide"
      # A setting the menu does not send leaves it alone.
      assert Config.from_form(%{"density" => "compact"}, %Config{handoff: "short"}).handoff ==
               "short"

      assert Config.to_query(%Config{handoff: "short"}) == [handoff: "short"]
      assert Config.from_map(Config.to_map(%Config{handoff: "full"})).handoff == "full"
      assert Config.from_map(%{"density" => "compact"}).handoff == "hide"
    end

    test "off by default: the mark alone", ctx do
      leave(ctx, "Pick up the tests", "State: half done")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      assert has_element?(view, "#display-handoff input[name=handoff][value=hide][checked]")
      assert has_element?(view, "#card-#{ctx.card.id} [data-role=handoff-mark]")
      refute has_element?(view, "[data-role=handoff-note]")
    end

    test "the menu shows it cut to two lines, or in full", ctx do
      leave(ctx, "Pick up the tests", "State: half done\nGotchas: the seed")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")

      view |> form("#swim-config", %{"handoff" => "short"}) |> render_change()
      assert_patch(view, ~p"/boards/#{ctx.board}?handoff=short")

      note = "#card-#{ctx.card.id} [data-role=handoff-note][data-mode=short]"
      assert has_element?(view, note <> " p.line-clamp-2", "Pick up the tests")
      assert has_element?(view, note <> "[title*='Gotchas: the seed']")

      view |> form("#swim-config", %{"handoff" => "full"}) |> render_change()
      assert_patch(view, ~p"/boards/#{ctx.board}?handoff=full")

      html = view |> element("#card-#{ctx.card.id} [data-role=handoff-note]") |> render()
      assert html =~ ~s(data-mode="full")
      refute html =~ "line-clamp-2"
      refute html =~ "title="
      # Next step and body, as written, with the line break kept.
      assert html =~ "Pick up the tests\nState: half done\nGotchas: the seed"
    end

    test "a note with no body shows the next step alone", ctx do
      leave(ctx, "Only a next step")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?handoff=full")

      html = view |> element("#card-#{ctx.card.id} [data-role=handoff-note]") |> render()
      assert html =~ "Left off:</span> Only a next step</p>"
    end

    test "not on completed, cleared or note-less cards, nor on compact ones", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Cleared"})
      plain = card_fixture(hd(ctx.board.columns), %{"title" => "Plain"})
      open_one = card_fixture(hd(ctx.board.columns), %{"title" => "Open"})
      leave(ctx, "Will be done")
      {:ok, _} = Boards.leave_handoff(other, ctx.owner, %{next_step: "x", via: "ui"})
      {:ok, _} = Boards.clear_handoff(other, ctx.owner, %{via: "ui"})
      {:ok, _} = Boards.leave_handoff(open_one, ctx.owner, %{next_step: "Go on", via: "ui"})
      {:ok, _} = Boards.update_card(ctx.card, %{"completed" => true})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?handoff=full")

      for card <- [ctx.card, other, plain] do
        refute has_element?(view, "#card-#{card.id} [data-role=handoff-note]")
      end

      assert has_element?(view, "#card-#{open_one.id} [data-role=handoff-note]", "Go on")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}?handoff=full&density=compact")
      refute has_element?(view, "[data-role=handoff-note]")
      assert has_element?(view, "#card-#{open_one.id} [data-role=handoff-mark]")
    end

    test "swimlanes show it too; views without card fronts don't offer it", ctx do
      leave(ctx, "Lane step")

      {:ok, view, _} =
        live(ctx.conn, ~p"/boards/#{ctx.board}/swimlanes?handoff=short")

      assert has_element?(view, "#display-handoff")
      assert has_element?(view, "[data-role=handoff-note][data-mode=short]", "Lane step")

      for mode <- ~w(table timeline calendar outline) do
        {:ok, view, _} = live(ctx.conn, "/boards/#{ctx.board.id}/#{mode}")
        refute has_element?(view, "#display-handoff")
      end
    end
  end
end
