defmodule Slipdock.WorkWaitingTest do
  @moduledoc """
  Waiting on you (#1118, R14): `Work.waiting_on_me/2` gathers, for one
  person and oldest first, the open waits on them, waits on anyone on their
  cards, their cards flagged review or waiting, runner trouble on the trees
  they own and cards in progress with nobody on them — only on cards they
  may read.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Runners, Work}
  alias Slipdock.Boards.{Activity, CardMove}
  alias Slipdock.Runners.Job

  setup do
    owner = user_fixture("owner@example.com")

    dana =
      "dana@example.com"
      |> user_fixture()
      |> Ecto.Changeset.change(name: "Dana")
      |> Repo.update!()

    board = board_fixture(%{"name" => "Waiting"}, owner: owner)
    [_backlog, todo, doing, _done] = board.columns
    {:ok, _} = Slipdock.Access.grant(board, dana, "write", owner)
    %{owner: owner, dana: dana, board: board, todo: todo, doing: doing}
  end

  defp agent(user), do: %{Actor.unknown() | kind: "agent", via: "mcp", user_id: user.id}

  defp open_wait(card, by, attrs) do
    {:ok, wait} =
      Boards.open_wait(card, agent(by), Map.merge(%{"needs" => "Which region?"}, attrs))

    wait
  end

  defp assign(card, users),
    do: {:ok, _} = Boards.update_card(card, %{"assignee_ids" => Enum.map(users, & &1.id)})

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp reasons(user, opts \\ []),
    do: user |> Work.waiting_on_me(opts) |> Enum.map(&{&1.card.id, &1.reason})

  # Puts the card's ledger entry into its list `seconds` ago.
  defp entered(card, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)
    from(m in CardMove, where: m.card_id == ^card.id) |> Repo.update_all(set: [inserted_at: at])
  end

  defp job(card, status, extra \\ []) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})

    from(j in Job, where: j.id == ^job.id)
    |> Repo.update_all(set: [status: status, finished_at: ago(600)] ++ extra)

    Repo.get!(Job, job.id)
  end

  describe "who sees what" do
    test "a wait on Dana is Dana's, not the board owner's", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Deploy"})
      wait = open_wait(card, ctx.owner, %{"on_user_id" => ctx.dana.id})

      assert [item] = Work.waiting_on_me(ctx.dana)
      assert item.card.id == card.id
      assert item.reason == "wait"
      assert item.text == "Waiting on you: Which region?"
      assert item.since == wait.inserted_at
      assert item.wait.id == wait.id
      assert item.path == ["Waiting"]

      assert reasons(ctx.owner) == []
    end

    test "a wait on anyone is the root owner's and the assignees'", ctx do
      carol = user_fixture("carol@example.com")
      {:ok, _} = Slipdock.Access.grant(ctx.board, carol, "write", ctx.owner)
      card = card_fixture(ctx.todo)
      assign(card, [ctx.dana])
      open_wait(card, ctx.dana, %{})

      assert reasons(ctx.owner) == [{card.id, "wait_anyone"}]
      assert reasons(ctx.dana) == [{card.id, "wait_anyone"}]
      assert reasons(carol) == []
    end

    test "a wait on a sub-board's card is the root owner's", ctx do
      parent = card_fixture(ctx.todo)
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(parent, t)
      sub = Boards.get_board!(sub.id)
      card = card_fixture(hd(sub.columns))
      open_wait(card, ctx.dana, %{})

      assert [item] = Work.waiting_on_me(ctx.owner)
      assert item.card.id == card.id
      assert item.path == ["Waiting", parent.title]
    end

    test "a person asking anyone themselves doesn't wait on themselves", ctx do
      card = card_fixture(ctx.todo)
      {:ok, _} = Boards.open_wait(card, Actor.web(ctx.owner), %{"needs" => "Anyone?"})

      assert reasons(ctx.owner) == []
    end

    test "a review-flagged card assigned to me counts from when the flag went on", ctx do
      card = card_fixture(ctx.todo)
      assign(card, [ctx.dana])
      {:ok, card} = Boards.update_card(card, %{"flags" => ["review"]})
      {:ok, _} = Boards.update_card(card, %{"flags" => ["review", "blocked"]})

      # The flag went on a while ago; the second change kept it on.
      [first, _second] =
        from(a in Activity, where: a.card_id == ^card.id and like(a.message, "set flags%"))
        |> order_by(:id)
        |> Repo.all()

      # One clock reading, so a second ticking over can't split it.
      went_on = ago(7200)

      from(a in Activity, where: a.id == ^first.id)
      |> Repo.update_all(set: [inserted_at: went_on])

      assert [item] = Work.waiting_on_me(ctx.dana)
      assert item.reason == "review"
      assert item.text == "Flagged review"
      assert item.since == went_on
      # Not assigned to the owner, who sees nothing.
      assert reasons(ctx.owner) == []
    end

    test "a flag taken off and put back counts from when it went back on", ctx do
      card = card_fixture(ctx.todo)
      assign(card, [ctx.dana])
      {:ok, card} = Boards.update_card(card, %{"flags" => ["waiting"]})
      {:ok, card} = Boards.update_card(card, %{"flags" => []})
      {:ok, _} = Boards.update_card(card, %{"flags" => ["waiting"]})

      [on, off, back] =
        from(a in Activity, where: a.card_id == ^card.id and like(a.message, "set flags%"))
        |> order_by(:id)
        |> Repo.all()

      went_back = ago(300)

      for {a, at} <- [{on, ago(9000)}, {off, ago(8000)}, {back, went_back}],
          do:
            from(x in Activity, where: x.id == ^a.id)
            |> Repo.update_all(set: [inserted_at: at])

      assert [%{reason: "waiting", since: since}] = Work.waiting_on_me(ctx.dana)
      assert since == went_back
    end

    test "a waiting flag that an open wait set is the wait, not the flag", ctx do
      card = card_fixture(ctx.todo)
      assign(card, [ctx.owner])
      open_wait(card, ctx.owner, %{"on_user_id" => ctx.dana.id})

      assert reasons(ctx.owner) == []
      assert reasons(ctx.dana) == [{card.id, "wait"}]
    end

    test "a card the runner gave up on is the board owner's", ctx do
      card = card_fixture(ctx.doing)
      {:ok, _} = Boards.update_card(card, %{"flags" => ["blocked"]})
      job = job(card, "done", recovery: "gave_up")

      assert [item] = Work.waiting_on_me(ctx.owner)
      assert item.reason == "gave_up"
      assert item.text == "The runner gave up on it after job ##{job.id}"
      assert item.since == job.finished_at
      assert reasons(ctx.dana) == []

      # Unblocked by hand, it no longer needs anybody.
      {:ok, _} = Boards.update_card(Boards.get_card!(card.id), %{"flags" => []})
      assert reasons(ctx.owner) == []
    end

    test "a card whose newest job failed shows until a newer job is queued", ctx do
      card = card_fixture(ctx.todo)
      job = job(card, "failed")

      assert [%{reason: "failed", text: text, job: %{id: id}}] = Work.waiting_on_me(ctx.owner)
      assert text == "Job ##{job.id} failed"
      assert id == job.id

      {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "again"})
      assert reasons(ctx.owner) == []
    end

    test "a timed-out job reads so", ctx do
      card = card_fixture(ctx.todo)
      job = job(card, "timeout")
      assert [%{text: text}] = Work.waiting_on_me(ctx.owner)
      assert text == "Job ##{job.id} timed out"
    end

    test "an unassigned card two hours into Doing needs an owner, for the root owner only",
         ctx do
      card = card_fixture(ctx.doing)
      entered(card, 7200)

      assert [item] = Work.waiting_on_me(ctx.owner)
      assert item.reason == "needs_owner"
      assert item.text == "In progress with nobody on it"
      assert DateTime.diff(DateTime.utc_now(), item.since) in 7199..7201
      assert reasons(ctx.dana) == []
    end

    test "half an hour into Doing is not yet anyone's problem", ctx do
      card = card_fixture(ctx.doing)
      entered(card, 1800)
      assert reasons(ctx.owner) == []
    end

    test "a card in Doing with someone on it, an open job or an open wait needs no owner",
         ctx do
      assigned = card_fixture(ctx.doing)
      assign(assigned, [ctx.dana])
      running = card_fixture(ctx.doing)
      {:ok, _} = Runners.queue(running, %{pool: "dev", kind: "claude", prompt: "go"})
      asked = card_fixture(ctx.doing)
      open_wait(asked, ctx.owner, %{"on_user_id" => ctx.dana.id})
      for c <- [assigned, running, asked], do: entered(c, 7200)

      assert reasons(ctx.owner) == []
    end

    test "cards on boards the user cannot read never appear", ctx do
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs"}, owner: stranger)
      card = card_fixture(Enum.at(theirs.columns, 1))
      # A wait naming me, and my name on the card, on a board I was never shared.
      open_wait(card, stranger, %{"on_user_id" => ctx.dana.id})
      assign(card, [ctx.dana])

      assert reasons(ctx.dana) == []
    end

    test "completed and archived cards drop out", ctx do
      done = card_fixture(ctx.todo)
      open_wait(done, ctx.owner, %{"on_user_id" => ctx.dana.id})
      {:ok, _} = Boards.toggle_completed(Boards.get_card!(done.id))
      archived = card_fixture(ctx.todo)
      assign(archived, [ctx.dana])
      {:ok, _} = Boards.update_card(Boards.get_card!(archived.id), %{"flags" => ["review"]})
      {:ok, _} = Boards.archive_card(Boards.get_card!(archived.id))

      assert reasons(ctx.dana) == []
    end
  end

  describe "ordering and scope" do
    test "items are oldest first across buckets, one per card", ctx do
      waited = card_fixture(ctx.todo, %{"title" => "Waited"})
      wait = open_wait(waited, ctx.dana, %{"on_user_id" => ctx.owner.id})

      from(w in Slipdock.Boards.Wait, where: w.id == ^wait.id)
      |> Repo.update_all(set: [inserted_at: ago(300)])

      failed = card_fixture(ctx.todo, %{"title" => "Failed"})
      job(failed, "failed")

      stuck = card_fixture(ctx.doing, %{"title" => "Stuck"})
      entered(stuck, 7200)

      reviewed = card_fixture(ctx.todo, %{"title" => "Reviewed"})
      assign(reviewed, [ctx.owner])
      {:ok, _} = Boards.update_card(reviewed, %{"flags" => ["review"]})
      # The review card is also waited on: one item, the wait.
      open_wait(reviewed, ctx.dana, %{"on_user_id" => ctx.owner.id})

      assert reasons(ctx.owner) == [
               {stuck.id, "needs_owner"},
               {failed.id, "failed"},
               {waited.id, "wait"},
               {reviewed.id, "wait"}
             ]

      assert Work.waiting_count(ctx.owner) == 4
    end

    test ":board_id and :roots keep to a tree", ctx do
      card = card_fixture(ctx.todo)
      open_wait(card, ctx.dana, %{"on_user_id" => ctx.owner.id})
      other = board_fixture(%{"name" => "Other"}, owner: ctx.owner)
      card2 = card_fixture(Enum.at(other.columns, 1))
      open_wait(card2, ctx.dana, %{"on_user_id" => ctx.owner.id})

      assert reasons(ctx.owner, board_id: other.id) == [{card2.id, "wait"}]
      assert reasons(ctx.owner, roots: [ctx.board.id]) == [{card.id, "wait"}]
      assert length(reasons(ctx.owner)) == 2
    end

    test "nothing waiting is an empty list and a zero", ctx do
      assert Work.waiting_on_me(ctx.dana) == []
      assert Work.waiting_count(ctx.dana) == 0
    end

    test "answering a wait removes it", ctx do
      card = card_fixture(ctx.todo)
      open_wait(card, ctx.owner, %{"on_user_id" => ctx.dana.id})
      assert Work.waiting_count(ctx.dana) == 1

      {:ok, _} = Boards.answer_wait(card, Actor.web(ctx.dana), %{"answer" => "eu"})
      assert Work.waiting_count(ctx.dana) == 0
    end
  end
end
