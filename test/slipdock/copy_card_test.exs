defmodule Slipdock.CopyCardTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Repo, Settings}
  alias Slipdock.Boards.{Attachment, Card}

  setup do
    owner = user_fixture()
    other = user_fixture("other@example.com")
    board = board_fixture(%{}, owner: owner)
    share_fixture(board, other)
    [backlog, todo | _] = board.columns
    %{owner: owner, other: other, board: board, backlog: backlog, todo: todo}
  end

  defp full_card(ctx) do
    urgent = tag_fixture(ctx.board, "urgent")

    card =
      card_fixture(ctx.backlog, %{
        "title" => "Review invoices",
        "description" => "Check every one",
        "priority" => "high",
        "color" => "red",
        "flags" => ["starred", "blocked", "waiting", "review"],
        "time_unit" => "hours",
        "time_estimate" => "2",
        "time_spent" => "1",
        "percent_complete" => 40,
        "due_date" => "2030-01-10",
        "assignee_ids" => [ctx.owner.id, ctx.other.id]
      })

    {:ok, _} = Boards.set_card_tags(card, [urgent])
    {:ok, a} = Boards.add_checklist_item(card, "Open the inbox")
    {:ok, _} = Boards.add_checklist_item(card, "File them")
    {:ok, _} = Boards.toggle_checklist_item(a)
    Boards.get_card!(card.id)
  end

  test "copies what the card is, and leaves behind what it has done", ctx do
    card = full_card(ctx)
    {:ok, _} = Boards.add_comment(card, "Did January", by: ctx.owner)
    {:ok, _} = Boards.add_dependency(card, card_fixture(ctx.backlog))

    assert {:ok, copy} = Boards.copy_card(card)

    assert copy.id != card.id
    assert copy.column_id == card.column_id
    assert copy.title == "Review invoices"
    assert copy.description == "Check every one"
    assert copy.priority == "high"
    assert copy.color == "red"
    assert Enum.sort(copy.flags) == ["review", "starred"]
    assert copy.time_estimate == 120
    assert copy.time_unit == "hours"
    assert copy.time_spent in [nil, 0]
    assert copy.percent_complete == nil
    assert copy.due_date == nil
    refute copy.completed
    assert Enum.map(copy.tags, & &1.name) == ["urgent"]
    assert Boards.assignee_ids(copy) == [ctx.owner.id, ctx.other.id]

    assert [{"Open the inbox", false}, {"File them", false}] =
             Enum.map(copy.checklist_items, &{&1.text, &1.done})

    assert copy.comments == []
    assert copy.blocked_by == []
    # The original is untouched.
    assert [%{done: true}, %{done: false}] = Boards.get_card!(card.id).checklist_items
  end

  test "attachments are not copied", ctx do
    card = card_fixture(ctx.backlog, %{"title" => "With a file"})

    Repo.insert!(%Attachment{
      card_id: card.id,
      filename: "a.txt",
      content_type: "text/plain",
      size: 1,
      key: "k-#{System.unique_integer([:positive])}"
    })

    {:ok, copy} = Boards.copy_card(Boards.get_card!(card.id))
    assert Repo.aggregate(from(a in Attachment, where: a.card_id == ^copy.id), :count) == 0
  end

  test "attrs override, and :top / :after place it", ctx do
    first = card_fixture(ctx.todo, %{"title" => "First"})
    card = card_fixture(ctx.todo, %{"title" => "Second"})
    _last = card_fixture(ctx.todo, %{"title" => "Third"})

    {:ok, top} =
      Boards.copy_card(card, ctx.todo,
        at: :top,
        attrs: %{"due_date" => "2031-02-03", "title" => "Second (Feb)"}
      )

    assert top.due_date == ~D[2031-02-03]
    assert top.title == "Second (Feb)"

    {:ok, after_it} = Boards.copy_card(card, nil, at: :after)

    ids = ctx.todo.id |> Boards.active_items() |> Enum.map(fn {:card, id} -> id end)
    assert Enum.take(ids, 4) == [top.id, first.id, card.id, after_it.id]
  end

  test "copies into another list, and into another board's tree by tag name", ctx do
    card = full_card(ctx)
    {:ok, copy} = Boards.copy_card(card, ctx.todo)
    assert copy.column_id == ctx.todo.id

    elsewhere = board_fixture(%{}, owner: ctx.owner)
    {:ok, moved} = Boards.copy_card(card, hd(elsewhere.columns))
    assert moved.board_id == elsewhere.id
    assert [%{name: "urgent", board_id: board_id}] = moved.tags
    assert board_id == elsewhere.id
  end

  test "subcards come along, reopened, in the sub-board's ready list", ctx do
    epic = card_fixture(ctx.backlog, %{"title" => "Month end"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    [first_list | rest] = sub.columns
    last_list = List.last(rest)

    a = card_fixture(first_list, %{"title" => "A", "flags" => ["blocked"]})
    {:ok, _} = Boards.add_checklist_item(a, "a1")
    b = card_fixture(last_list, %{"title" => "B", "completed" => true})
    {:ok, _} = Boards.archive_card(card_fixture(first_list, %{"title" => "Gone"}))

    # A grandchild, done.
    {:ok, subsub} = sub_board(b, t)
    subsub = Boards.get_board!(subsub.id)
    card_fixture(List.last(subsub.columns), %{"title" => "B1", "completed" => true})

    {:ok, copy} = Boards.copy_card(Boards.get_card!(epic.id))

    new_sub = Boards.get_board!(copy.sub_board.id)
    assert new_sub.id != sub.id
    assert new_sub.parent_card_id == copy.id
    assert Enum.map(new_sub.columns, & &1.name) == Enum.map(sub.columns, & &1.name)

    ready = SlipdockWeb.APIGuide.list_roles(new_sub.columns).ready
    cards = Repo.all(from(c in Card, where: c.board_id == ^new_sub.id, order_by: c.position))
    assert Enum.map(cards, & &1.title) == ["A", "B"]
    assert Enum.all?(cards, &(&1.column_id == ready.id and not &1.completed))
    assert hd(cards).flags == []
    assert [%{text: "a1", done: false}] = Boards.get_card!(hd(cards).id).checklist_items

    b_copy = Boards.get_card!(List.last(cards).id)

    assert [%{title: "B1", completed: false}] =
             Repo.all(from(c in Card, where: c.board_id == ^b_copy.sub_board.id))

    # The original tree is as it was.
    assert Repo.aggregate(from(c in Card, where: c.board_id == ^sub.id), :count) == 3
  end

  test "a copy the card limit stops part-way leaves nothing behind" do
    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "free_card_limit" => 4})

    owner = user_fixture("limited@example.com")
    board = board_fixture(%{}, owner: owner)
    epic = card_fixture(hd(board.columns), %{"title" => "Epic"})
    {:ok, t} = Boards.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    sub = Boards.get_board!(sub.id)
    card_fixture(hd(sub.columns), %{"title" => "One"})
    card_fixture(hd(sub.columns), %{"title" => "Two"})

    before = Repo.aggregate(Card, :count)
    boards_before = Repo.aggregate(Slipdock.Boards.Board, :count)

    assert {:error, changeset} = Boards.copy_card(Boards.get_card!(epic.id))
    assert Slipdock.Quota.limit_reached?(changeset)
    assert Repo.aggregate(Card, :count) == before
    assert Repo.aggregate(Slipdock.Boards.Board, :count) == boards_before
  end
end
