defmodule Slipdock.WorkDismissTest do
  @moduledoc """
  Waiting on you, trimmed by its person (#2069): a dismissal takes one item
  off one person's list, held on the card and its cause, so the same cause
  stays off and a new one shows again; a mute keeps a board's tree off one
  person's list. `Work.waiting/2` says how much is hidden.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners, Work}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("owner@example.com")
    dana = user_fixture("dana@example.com")
    board = board_fixture(%{"name" => "Waiting"}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    %{owner: owner, dana: dana, board: board, todo: todo}
  end

  defp agent(user), do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id}

  defp open_wait(card, by, attrs \\ %{}) do
    {:ok, wait} =
      Boards.Waits.open_wait(card, agent(by), Map.merge(%{"needs" => "Which region?"}, attrs))

    wait
  end

  defp failed_job(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    at = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

    from(j in Job, where: j.id == ^job.id)
    |> Repo.update_all(set: [status: "failed", finished_at: at])

    Repo.get!(Job, job.id)
  end

  defp ids(user), do: user |> Work.waiting_on_me() |> Enum.map(& &1.card.id)

  defp sub_board_card(card) do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card, t)
    sub = Boards.get_board!(sub.id)
    {sub, card_fixture(hd(sub.columns), %{"title" => "Deep"})}
  end

  describe "dismissing an item" do
    test "takes it off my list only, and it stays off for the same cause", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Shared"})
      Boards.Cards.update_card(card, %{"assignee_ids" => [ctx.dana.id]})
      wait = open_wait(card, ctx.dana)

      assert ids(ctx.owner) == [card.id]
      assert ids(ctx.dana) == [card.id]

      assert {:ok, item} = Work.dismiss(ctx.owner, card)
      assert item.cause == "wait:#{wait.id}"

      assert ids(ctx.owner) == []
      assert Work.waiting_count(ctx.owner) == 0
      # Dana's list is hers: the owner's dismissal doesn't touch it.
      assert ids(ctx.dana) == [card.id]

      # Asked again later, the same wait is still dismissed.
      assert ids(ctx.owner) == []
      assert %{items: [], dismissed: [d], muted: 0, muted_boards: 0} = Work.waiting(ctx.owner)
      assert d.card.id == card.id
      assert d.path == ["Waiting"]

      # Off the list, there is nothing left to dismiss.
      assert {:error, :not_waiting} = Work.dismiss(ctx.owner, card)
    end

    test "a second failed job is a new cause, and comes back", ctx do
      card = card_fixture(ctx.todo)
      first = failed_job(card)

      assert {:ok, %{cause: cause}} = Work.dismiss(ctx.owner, card)
      assert cause == "job:#{first.id}"
      assert ids(ctx.owner) == []

      second = failed_job(card)
      assert [item] = Work.waiting_on_me(ctx.owner)
      assert item.job.id == second.id
      assert Work.waiting(ctx.owner).dismissed == []
    end

    test "a new wait on the card comes back", ctx do
      card = card_fixture(ctx.todo)
      open_wait(card, ctx.dana)
      {:ok, _} = Work.dismiss(ctx.owner, card)
      assert ids(ctx.owner) == []

      {:ok, _} =
        Boards.Waits.answer_wait(Boards.Cards.get_card!(card.id), Actor.web(ctx.owner), %{
          "answer" => "EU"
        })

      second = open_wait(Boards.Cards.get_card!(card.id), ctx.dana, %{"needs" => "Which zone?"})

      assert [item] = Work.waiting_on_me(ctx.owner)
      assert item.wait.id == second.id
    end

    test "with the top reason dismissed, the card's next reason shows", ctx do
      card = card_fixture(ctx.todo)
      job = failed_job(card)
      open_wait(card, ctx.dana)

      assert [%{reason: "wait_anyone"}] = Work.waiting_on_me(ctx.owner)
      {:ok, _} = Work.dismiss(ctx.owner, card)

      assert [%{reason: "failed", job: %{id: id}}] = Work.waiting_on_me(ctx.owner)
      assert id == job.id
      assert Work.waiting(ctx.owner).dismissed == []
    end

    test "a card not on my list can't be dismissed", ctx do
      card = card_fixture(ctx.todo)
      assert {:error, :not_waiting} = Work.dismiss(ctx.owner, card)
    end

    test "undo brings it back; undoing nothing says so", ctx do
      card = card_fixture(ctx.todo)
      failed_job(card)
      {:ok, _} = Work.dismiss(ctx.owner, card)
      assert [%{card: %{id: id}}] = Work.dismissed(ctx.owner)
      assert id == card.id

      assert {:ok, 1} = Work.undismiss(ctx.owner, card)
      assert ids(ctx.owner) == [card.id]
      assert Work.dismissed(ctx.owner) == []
      assert {:error, :not_dismissed} = Work.undismiss(ctx.owner, card)
    end
  end

  describe "muting a board" do
    test "keeps its whole tree off my list, and nobody else's", ctx do
      top = card_fixture(ctx.todo, %{"title" => "Top"})
      open_wait(top, ctx.dana)
      {sub, deep} = sub_board_card(top)
      failed_job(deep)

      assert Enum.sort(ids(ctx.owner)) == Enum.sort([top.id, deep.id])

      assert {:ok, _} = Work.mute(ctx.owner, ctx.board)
      assert {:ok, _} = Work.mute(ctx.owner, ctx.board)

      assert ids(ctx.owner) == []
      assert %{items: [], dismissed: [], muted: 2, muted_boards: 1} = Work.waiting(ctx.owner)
      assert Work.waiting_count(ctx.owner) == 0
      assert Work.muted_boards(ctx.owner) |> Enum.map(& &1.id) == [ctx.board.id]

      # The sub-board is quiet because of the board above it.
      assert Work.muted_by(ctx.owner, Boards.get_board!(sub.id)).id == ctx.board.id
      assert Work.muted_by(ctx.owner, ctx.board).id == ctx.board.id
      assert Work.muted_by(ctx.dana, ctx.board) == nil

      # A wait on anyone on a card assigned to Dana is still hers.
      Boards.Cards.update_card(top, %{"assignee_ids" => [ctx.dana.id]})
      assert ids(ctx.dana) == [top.id]

      assert {:ok, _} = Work.unmute(ctx.owner, ctx.board)
      assert Enum.sort(ids(ctx.owner)) == Enum.sort([top.id, deep.id])
      assert {:error, :not_muted} = Work.unmute(ctx.owner, ctx.board)
    end

    test "a muted sub-board leaves the board above it alone", ctx do
      top = card_fixture(ctx.todo, %{"title" => "Top"})
      open_wait(top, ctx.dana)
      {sub, deep} = sub_board_card(top)
      failed_job(deep)

      {:ok, _} = Work.mute(ctx.owner, Boards.get_board!(sub.id))

      assert ids(ctx.owner) == [top.id]
      assert Work.muted_by(ctx.owner, ctx.board) == nil
      assert %{muted: 1, muted_boards: 1} = Work.waiting(ctx.owner)
    end

    test "a muted card counts as muted, not dismissed", ctx do
      card = card_fixture(ctx.todo)
      failed_job(card)
      {:ok, _} = Work.dismiss(ctx.owner, card)
      {:ok, _} = Work.mute(ctx.owner, ctx.board)

      assert %{items: [], dismissed: [], muted: 1} = Work.waiting(ctx.owner)
    end
  end
end
