defmodule Slipdock.Meetings.UndoTest do
  @moduledoc """
  Undo (#539, G9): a commit reversed as a whole puts the board and the wiki
  back exactly, field by field; an edit made since the commit is listed and
  never silently thrown away; and the record shows every step, by whom.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Boards, Repo, Wiki}
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Meetings.{Commit, Event, Question, Review, Undo, Version}
  alias Slipdock.Wiki.Page

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    todo = Enum.find(board.columns, &(&1.name == "To Do"))

    card =
      card_fixture(todo, %{
        "title" => "Pricing page refresh",
        "priority" => "low",
        "due_date" => "2026-12-01"
      })

    {:ok, card} = Boards.update_card(card, %{"assignee_ids" => [owner.id]})
    {:ok, card} = Boards.toggle_completed(card)
    %{owner: owner, board: board, sam: sam, card: Repo.reload!(card)}
  end

  defp snapshot(card) do
    card = Repo.get!(Card, card.id) |> Repo.preload(:assignees)

    {card.title, card.priority, card.due_date, card.completed, card.column_id, card.archived_at,
     Enum.map(card.assignees, & &1.id),
     Repo.aggregate(from(c in Comment, where: c.card_id == ^card.id), :count)}
  end

  defp committed(ctx, extra_pages \\ fn -> :ok end) do
    extra_pages.()

    candidate = %{
      "type" => "card",
      "id" => ctx.card.id,
      "ref" => "##{ctx.card.id}",
      "title" => ctx.card.title,
      "lines" => ["L3"],
      "strength" => "id",
      "version" => Version.of(ctx.card)
    }

    change = %{
      "kind" => "card_change",
      "title" => "Due Friday, urgent, Sam's",
      "card" => "##{ctx.card.id}",
      "owner" => "Sam",
      "change" => %{"field" => "due_date", "to" => "2026-10-09"},
      "comment" => "Moved up in the pricing sync.",
      "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
    }

    capture =
      reviewed_capture(
        ctx.board,
        ctx.owner,
        [
          decision_finding(%{"supersedes" => "monthly plan only"}),
          action_finding(nil, %{
            "owner" => nil,
            "title" => "Tell sales",
            "evidence" => [%{"line" => "L4", "quote" => "Yes, that's mine."}]
          }),
          change
        ],
        %{"candidates" => [candidate]}
      )

    {:ok, capture} = Commit.commit(capture, ctx.owner)
    capture
  end

  test "a clean undo puts every card, comment and page back exactly", ctx do
    {:ok, page} =
      Wiki.create_page(
        ctx.board,
        %{"title" => "Decisions / Pricing", "body" => "- Monthly plan only\n"}, user: ctx.owner)

    before_card = snapshot(ctx.card)
    before_page = Repo.reload!(page)
    cards_before = Repo.aggregate(from(c in Card, where: is_nil(c.archived_at)), :count)

    capture = committed(ctx)
    [create | _] = capture.change_set["changes"]
    refute snapshot(ctx.card) == before_card
    assert Repo.reload!(page).body =~ "~~Monthly plan only~~"

    assert Undo.conflicts(capture) == []
    {:ok, undone} = Undo.undo(capture, ctx.owner)

    assert snapshot(ctx.card) == before_card
    assert Repo.get!(Card, create["card_id"]).archived_at
    assert Repo.aggregate(from(c in Card, where: is_nil(c.archived_at)), :count) == cards_before
    after_page = Repo.reload!(page)
    assert after_page.body == before_page.body
    assert after_page.content_hash == before_page.content_hash
    assert undone.undone_at
    assert undone.undone_by_id == ctx.owner.id
    assert undone.state == "committed"
  end

  test "a decisions page the commit made is archived by undo", ctx do
    capture = committed(ctx)
    [page_change] = Enum.filter(capture.change_set["changes"], &(&1["op"] == "decision_entry"))
    assert page_change["created_page"]
    {:ok, _} = Undo.undo(capture, ctx.owner)
    assert Repo.get!(Page, page_change["page_id"]).archived_at
  end

  test "an edit made since is listed, not thrown away; undo the rest leaves it", ctx do
    capture = committed(ctx)
    [create | _] = capture.change_set["changes"]
    new_card = Repo.get!(Card, create["card_id"])
    {:ok, _} = Boards.update_card(new_card, %{"title" => "Tell sales (and support)"})

    assert {:error, :conflicts, [conflict]} = Undo.undo(capture, ctx.owner)
    assert conflict["ref"] == "##{new_card.id}"
    assert conflict["why"] == "the card was edited since"
    # Nothing was undone.
    assert Repo.reload!(capture).undone_at == nil
    assert Repo.get!(Card, ctx.card.id).due_date == ~D[2026-10-09]

    {:ok, undone} = Undo.undo(capture, ctx.owner, rest: true)
    assert Repo.get!(Card, new_card.id).title == "Tell sales (and support)"
    assert Repo.get!(Card, new_card.id).archived_at == nil
    assert Repo.get!(Card, ctx.card.id).due_date == ~D[2026-12-01]
    assert undone.change_set["undone"]["kept"] == [create["id"]]
  end

  test "undo twice, or undo what was never committed, is refused", ctx do
    capture = committed(ctx)
    {:ok, _} = Undo.undo(capture, ctx.owner)
    assert {:error, :conflict, "this capture was undone already"} = Undo.undo(capture, ctx.owner)

    fresh = reviewed_capture(ctx.board, ctx.owner, [decision_finding()])

    assert {:error, :conflict, "this capture is ready: only a commit can be undone"} =
             Undo.undo(fresh, ctx.owner)
  end

  test "the record has every resolution with who and when, the commit and the undo", ctx do
    capture = reviewed_capture(ctx.board, ctx.owner, [action_finding("Sammy")])
    q = Repo.one!(from(q in Question, where: q.capture_id == ^capture.id))
    {:ok, _} = Review.answer(q, "user:#{ctx.sam.id}", ctx.sam)
    {:ok, capture} = Commit.commit(capture, ctx.owner)
    {:ok, _} = Undo.undo(capture, ctx.owner)

    record =
      Repo.all(
        from(e in Event, where: e.capture_id == ^capture.id, order_by: e.id, preload: :user)
      )

    kinds = Enum.map(record, & &1.kind)

    assert "received" in kinds and "found" in kinds and "answered" in kinds and
             "committed" in kinds and "undone" in kinds

    answered = Enum.find(record, &(&1.kind == "answered"))
    assert answered.user.id == ctx.sam.id
    assert answered.inserted_at
    assert answered.message =~ "Sam Smith"
  end
end
