defmodule Slipdock.Boards.ActivityTest do
  @moduledoc """
  Who each activity entry is by (#1735): `Activity.stamp/2` for every kind of
  actor, the process's actor as the board's code paths see it, an entry whose
  user has since been deleted, and paging through a board's log.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, Repo, Wiki}
  alias Slipdock.Boards.Activity

  setup do
    owner = user_fixture("activity.owner@example.com")
    owner = Repo.update!(Ecto.Changeset.change(owner, name: "Dana Owner"))
    board = board_fixture(%{"name" => "Activity actors"}, owner: owner)
    %{owner: owner, board: board, todo: hd(board.columns)}
  end

  defp latest(board), do: board.id |> Boards.ActivityLog.list_activities(1) |> hd()

  describe "stamp/2" do
    test "a person: their id and the name given with them", %{owner: owner} do
      a = Activity.stamp(%Activity{}, Map.put(Actor.web(owner), :name, "Dana"))
      assert {a.actor_kind, a.user_id, a.actor_name} == {"person", owner.id, "Dana"}
    end

    test "a person given without a name has theirs looked up", %{owner: owner} do
      a = Activity.stamp(%Activity{}, Actor.web(owner))
      assert {a.actor_kind, a.user_id, a.actor_name} == {"person", owner.id, "Dana Owner"}
    end

    test "a person who no longer exists is a person with no link and no name" do
      a = Activity.stamp(%Activity{}, Actor.web(-1))
      assert {a.actor_kind, a.user_id, a.actor_name} == {"person", nil, nil}
    end

    test "a person who emailed it in is email", %{owner: owner} do
      a = Activity.stamp(%Activity{}, Actor.email(owner))
      assert {a.actor_kind, a.user_id, a.actor_name} == {"email", owner.id, "Dana Owner"}
    end

    test "an agent is named by its token's label", %{owner: owner} do
      {_secret, token} = Accounts.create_api_token(owner, "claude-laptop")
      a = Activity.stamp(%Activity{}, Actor.mcp(%{user: owner, token: token}))
      assert {a.actor_kind, a.user_id, a.actor_name} == {"agent", owner.id, "claude-laptop"}
    end

    test "an agent with no label is named by its door", %{owner: owner} do
      assert Activity.stamp(%Activity{}, Actor.assistant(owner)).actor_name == "Assistant"
      assert Activity.stamp(%Activity{}, Actor.runner(owner, nil)).actor_name == "Runner"

      assert Activity.stamp(%Activity{}, %{kind: "agent", via: "api", user_id: nil}).actor_name ==
               "Agent"
    end

    test "an automation is named by its rule, when it has one" do
      named = Activity.stamp(%Activity{}, Map.put(Actor.automation(), :name, "Triage"))
      assert {named.actor_kind, named.user_id, named.actor_name} == {"automation", nil, "Triage"}

      assert %{actor_kind: "automation", actor_name: nil} =
               Activity.stamp(%Activity{}, Actor.automation())
    end

    test "nobody, or nothing at all, is the system" do
      for actor <- [Actor.unknown(), nil, %{}] do
        a = Activity.stamp(%Activity{}, actor)
        assert {a.actor_kind, a.user_id, a.actor_name} == {"system", nil, nil}
      end
    end

    test "an entry that already names its actor keeps it", %{owner: owner} do
      given = %Activity{actor_kind: "email", actor_name: "Kept"}
      assert Activity.stamp(given, Actor.web(owner)) == given
    end

    test "with no actor given it uses the process's", %{owner: owner} do
      Actor.put(Actor.web(owner), "From the process")
      assert %{actor_kind: "person", actor_name: "From the process"} = Activity.stamp(%Activity{})
    end
  end

  describe "the board's own writes" do
    test "are by the process's actor", %{owner: owner, board: board, todo: todo} do
      Actor.put(Actor.web(owner), "Dana Owner")
      card_fixture(todo, %{"title" => "By Dana"})

      assert %{actor_kind: "person", user_id: id, actor_name: "Dana Owner", message: msg} =
               latest(board)

      assert id == owner.id
      assert msg =~ "By Dana"
    end

    test "are the system's when nobody set an actor", %{board: board, todo: todo} do
      card_fixture(todo, %{"title" => "Nobody's"})
      assert %{actor_kind: "system", user_id: nil, actor_name: nil} = latest(board)
    end

    test "a page and a comment are stamped too", %{owner: owner, board: board, todo: todo} do
      card = card_fixture(todo, %{"title" => "Talked about"})
      Actor.put(Actor.email(owner), "Dana Owner")
      {:ok, _} = Boards.Comments.add_comment(card, "Noted", by: owner)
      assert %{kind: "comment", actor_kind: "email"} = latest(board)

      Actor.put(Actor.web(owner), "Dana Owner")
      {:ok, _} = Wiki.create_page(board, %{"title" => "Pricing decision"}, user: owner)
      assert %{kind: "page_created", actor_kind: "person", message: "wrote " <> _} = latest(board)
    end

    test "made by a rule are the rule's, even inside a person's process", ctx do
      rule_fixture(
        ctx.board,
        %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "log", "message" => "saw a new card"}]
        },
        %{"name" => "Watcher"}
      )

      Actor.put(Actor.web(ctx.owner), "Dana Owner")
      card_fixture(ctx.todo, %{"title" => "Watched"})

      [logged] =
        ctx.board.id
        |> Boards.ActivityLog.list_activities()
        |> Enum.filter(&(&1.message == "saw a new card"))

      assert {logged.actor_kind, logged.actor_name, logged.message} ==
               {"automation", "Watcher", "saw a new card"}

      # The card itself was the person's, and the rule's name is gone after.
      assert Enum.any?(
               Boards.ActivityLog.list_activities(ctx.board.id),
               &(&1.actor_kind == "person")
             )

      assert Actor.current().kind == "human"
    end
  end

  describe "a deleted user" do
    test "leaves their entries naming them, with the link gone", ctx do
      gone = user_fixture("activity.gone@example.com")
      gone = Repo.update!(Ecto.Changeset.change(gone, name: "Gone Person"))
      Actor.put(Actor.web(gone))
      card_fixture(ctx.todo, %{"title" => "Left behind"})
      entry = latest(ctx.board)
      assert entry.user_id == gone.id

      {:ok, _} = Accounts.delete_user(gone)

      entry = Repo.get!(Activity, entry.id)
      assert {entry.actor_kind, entry.user_id, entry.actor_name} == {"person", nil, "Gone Person"}
    end
  end

  describe "page_activities/2" do
    defp entries(board, n) do
      base = ~U[2026-11-01 12:00:00Z]

      for i <- 1..n do
        Repo.insert!(%Activity{
          board_id: board.id,
          kind: "card",
          message: "entry #{i}",
          # Two to a second, so the cursor has ties to break on id.
          inserted_at: DateTime.add(base, div(i, 2), :second)
        })
      end
    end

    test "pages newest first, with the users loaded and more? said", %{board: board} do
      entries(board, 7)
      {first, more?} = Boards.ActivityLog.page_activities(board.id, limit: 3)
      assert more?
      assert length(first) == 3
      refute Enum.any?(first, &match?(%Ecto.Association.NotLoaded{}, &1.user))

      {second, more?} =
        Boards.ActivityLog.page_activities(board.id, limit: 3, before: List.last(first))

      assert more?

      {third, more?} =
        Boards.ActivityLog.page_activities(board.id, limit: 3, before: List.last(second))

      refute more?

      all = Enum.map(first ++ second ++ third, & &1.message)
      own = board.id |> Boards.ActivityLog.list_activities(100) |> Enum.map(& &1.message)
      assert all == own
      assert length(Enum.uniq(all)) == length(all)
    end

    test "down_to brings what is showing up to date, newest first", %{board: board} do
      all = entries(board, 5)
      {shown, true} = Boards.ActivityLog.page_activities(board.id, limit: 3)

      {again, more?} = Boards.ActivityLog.page_activities(board.id, down_to: List.last(shown))
      assert Enum.map(again, & &1.id) == Enum.map(shown, & &1.id)
      assert more?

      newer = Repo.insert!(%Activity{board_id: board.id, kind: "card", message: "newer"})

      {again, true} =
        Boards.ActivityLog.page_activities(board.id, down_to: List.last(shown), limit: 1)

      assert Enum.map(again, & &1.id) == [newer.id | Enum.map(shown, & &1.id)]

      assert {everything, false} = Boards.ActivityLog.page_activities(board.id, down_to: hd(all))
      # The five, the newer one and the board's own "created board".
      assert length(everything) == 7
    end

    test "an empty board is one empty page", ctx do
      Repo.delete_all(from(a in Activity, where: a.board_id == ^ctx.board.id))
      assert Boards.ActivityLog.page_activities(ctx.board.id) == {[], false}
    end

    test "a limit below one is one", %{board: board} do
      entries(board, 2)
      assert {[_], true} = Boards.ActivityLog.page_activities(board.id, limit: 0)
    end

    test "only the board's own entries", %{board: board} do
      other =
        board_fixture(%{"name" => "Elsewhere"}, owner: user_fixture("activity.other@example.com"))

      entries(other, 3)
      {page, _} = Boards.ActivityLog.page_activities(board.id, limit: 50)
      assert Enum.all?(page, &(&1.board_id == board.id))
    end
  end
end
