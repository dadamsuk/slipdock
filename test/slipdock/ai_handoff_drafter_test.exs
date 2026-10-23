defmodule Slipdock.AIHandoffDrafterTest do
  @moduledoc """
  Auto generate's draft of a card's handoff (#1099): what the model is told
  (recent activity first, the card, the handoff before), and what is made of
  its answer.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Boards, Repo}
  alias Slipdock.AI.HandoffDrafter
  alias Slipdock.Boards.Activity

  setup do
    owner = user_fixture()
    board = board_fixture(%{}, owner: owner)
    card = card_fixture(hd(board.columns), %{"title" => "Wire up billing"})
    {:ok, _} = Boards.add_comment(card, "Webhook signature check fails on staging")
    %{owner: owner, board: board, card: card}
  end

  defp loaded(card), do: Boards.get_card!(card.id)

  defp prompt do
    assert_received {:ai_request, %{"messages" => [_system, %{"content" => content}]}}
    content
  end

  defp system_prompt do
    assert_received {:ai_request, %{"messages" => [%{"content" => system}, _user]}}
    system
  end

  test "drafts the next step and the note, from the card's recent history", ctx do
    AIStub.reply_with(%{
      "next_step" => "  Fix the webhook signature check on staging ",
      "body" => "State: checkout done\nGotchas: staging secret differs"
    })

    assert {:ok, %{next_step: "Fix the webhook signature check on staging", body: body}} =
             HandoffDrafter.draft(loaded(ctx.card), ctx.board, user: ctx.owner)

    assert body == "State: checkout done\nGotchas: staging secret differs"

    content = prompt()
    assert content =~ "Webhook signature check fails on staging"
    assert content =~ "Card ##{ctx.card.id}: “Wire up billing”"
    assert content =~ "## The handoff before this one\n(none)"
  end

  test "is told only the last fortnight's activity, newest first, and the last note", ctx do
    %{board: board, card: card, owner: owner} = ctx
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {days, message} <- [{30, "an old move"}, {3, "moved to Doing"}, {1, "flagged blocked"}] do
      Repo.insert!(%Activity{
        board_id: board.id,
        card_id: card.id,
        kind: "test",
        message: message,
        inserted_at: DateTime.add(now, -days * 86_400)
      })
    end

    {:ok, _} = Boards.leave_handoff(card, owner, %{next_step: "Ask finance", via: "ui"})

    text = HandoffDrafter.context(loaded(card), board, now: now)
    refute text =~ "an old move"
    {blocked, _} = :binary.match(text, "flagged blocked")
    {doing, _} = :binary.match(text, "moved to Doing")
    assert blocked < doing
    assert text =~ "## The handoff before this one\nNext step: Ask finance"
  end

  test "after a clear there is no handoff before, and the activity says it was cleared", ctx do
    {:ok, _} = Boards.leave_handoff(ctx.card, ctx.owner, %{next_step: "x", via: "ui"})
    {:ok, _} = Boards.clear_handoff(ctx.card, ctx.owner, %{via: "ui"})

    text = HandoffDrafter.context(loaded(ctx.card), ctx.board)
    assert text =~ "## The handoff before this one\n(none)"
    assert text =~ "cleared the handoff"
  end

  test "a body given as lines is joined, an empty one is none, a long step is cut", ctx do
    AIStub.reply_with(%{
      "next_step" => String.duplicate("a", 400),
      "body" => ["State: x", "Open: y"]
    })

    assert {:ok, %{next_step: step, body: "State: x\nOpen: y"}} =
             HandoffDrafter.draft(loaded(ctx.card), ctx.board, user: ctx.owner)

    assert String.length(step) == 280

    AIStub.reply_with(%{"next_step" => "Ship it", "body" => "  "})

    assert {:ok, %{next_step: "Ship it", body: nil}} =
             HandoffDrafter.draft(loaded(ctx.card), ctx.board, user: ctx.owner)
  end

  test "no next step in the answer is an error, not a blank draft", ctx do
    AIStub.reply_with(%{"body" => "State: something"})

    assert {:error, "The model didn't suggest a next step." <> _} =
             HandoffDrafter.draft(loaded(ctx.card), ctx.board, user: ctx.owner)
  end

  test "the model failing is an error fit to show", ctx do
    AIStub.fail_with(500, "upstream down")
    assert {:error, message} = HandoffDrafter.draft(loaded(ctx.card), ctx.board, user: ctx.owner)
    assert is_binary(message)
  end

  describe "a board's own instructions (#1212)" do
    test "without any, the built-in ones are sent, with the answer's shape", ctx do
      AIStub.reply_with(%{"next_step" => "Ship it", "body" => ""})
      assert {:ok, _} = HandoffDrafter.draft(loaded(ctx.card), ctx.board, user: ctx.owner)

      system = system_prompt()
      assert String.starts_with?(system, HandoffDrafter.default_instructions())
      assert system =~ ~s({"next_step": "...", "body": "..."})
    end

    test "they replace the built-in ones, and the answer's shape is still asked for", ctx do
      {:ok, board} =
        Boards.update_board(ctx.board, %{"handoff_prompt" => "  Write it as a haiku.  "})

      AIStub.reply_with(%{"next_step" => "Ship it", "body" => "Autumn"})

      assert {:ok, %{next_step: "Ship it", body: "Autumn"}} =
               HandoffDrafter.draft(loaded(ctx.card), board, user: ctx.owner)

      system = system_prompt()
      assert String.starts_with?(system, "Write it as a haiku.\n\n")
      refute system =~ "Gotchas:"
      assert system =~ ~s({"next_step": "...", "body": "..."})
    end
  end
end
