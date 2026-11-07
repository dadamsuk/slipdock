defmodule Slipdock.WaitRoutesTest do
  @moduledoc """
  Waits go to a role (#1949, `Slipdock.WaitRoutes`): setting a board's routes
  and what is refused, a wait placed by its kind (the first person on, the
  rest told), the defaults and the fallback to the owner, a named person
  winning, a sub-board inheriting its parent's routes, the rejection-limit
  wait asking as `release`, an audit disagreement told to `release`'s
  people, a routed user leaving, and "Waiting on you" showing each their own.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Actor, Boards, Repo, Verified, WaitRoutes, Work}
  alias Slipdock.Boards.{Card, Comment, Wait}

  setup do
    owner = user_fixture("routes-owner@example.com")
    board = board_fixture(%{"name" => "Routes"}, owner: owner)
    pm = user_fixture("routes-pm@example.com")
    rel = user_fixture("routes-rel@example.com")
    ops = user_fixture("routes-ops@example.com")
    stranger = user_fixture("routes-stranger@example.com")
    for u <- [pm, rel, ops], do: {:ok, _} = Access.grant(board, u, "write", owner)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Pricing"})

    agent = %{Actor.unknown() | kind: "agent", via: "mcp", user_id: owner.id, agent: "builder"}

    %{
      owner: owner,
      board: board,
      pm: pm,
      rel: rel,
      ops: ops,
      stranger: stranger,
      todo: todo,
      doing: doing,
      card: card,
      agent: agent
    }
  end

  defp routes!(board, changes) do
    {:ok, board} = WaitRoutes.set(Repo.get!(Boards.Board, board.id), changes)
    board
  end

  defp open!(ctx, card, attrs) do
    {:ok, wait} = Boards.open_wait(card, ctx.agent, attrs)
    Repo.preload(wait, :on_user, force: true)
  end

  defp comments(card),
    do: Repo.all(from(c in Comment, where: c.card_id == ^card.id, order_by: c.id, select: c.body))

  describe "setting the routes" do
    test "starts empty, takes emails or ids in order, and merges by kind", ctx do
      assert WaitRoutes.routes(ctx.board) |> Map.values() |> Enum.all?(&(&1 == []))
      assert ctx.board.wait_routes == %{}

      board = routes!(ctx.board, %{"product" => "#{ctx.pm.email}, #{ctx.ops.email}"})
      assert board.wait_routes == %{"product" => [ctx.pm.id, ctx.ops.id]}

      board = routes!(board, %{"release" => [to_string(ctx.rel.id)], "PRODUCT" => [ctx.pm.email]})
      assert board.wait_routes == %{"product" => [ctx.pm.id], "release" => [ctx.rel.id]}
      assert Enum.map(WaitRoutes.routes(board)["release"], & &1.id) == [ctx.rel.id]

      # A blank or empty value takes a kind off; one left out stays.
      board = routes!(board, %{"product" => []})
      assert board.wait_routes == %{"release" => [ctx.rel.id]}
      board = routes!(board, %{"release" => ""})
      assert board.wait_routes == %{}
    end

    test "refuses an unknown kind, a user not on the board and an unknown address alike", ctx do
      assert {:error, "wait_routes: “finance” isn't a kind of question" <> _} =
               WaitRoutes.set(ctx.board, %{"finance" => [ctx.pm.email]})

      assert {:error, stranger} = WaitRoutes.set(ctx.board, %{"ux" => [ctx.stranger.email]})
      assert stranger == "wait_routes: #{ctx.stranger.email} isn't a user of this board"

      assert {:error, "wait_routes: nobody@example.com isn't a user of this board"} =
               WaitRoutes.set(ctx.board, %{"ux" => ["nobody@example.com"]})

      assert {:error, "wait_routes is a map" <> _} = WaitRoutes.set(ctx.board, "ux=x")
      assert {:error, "wait_routes: a kind takes" <> _} = WaitRoutes.set(ctx.board, %{"ux" => 7})

      # Nothing was saved.
      assert Repo.get!(Boards.Board, ctx.board.id).wait_routes == %{}
    end

    test "the owner may be routed", ctx do
      board = routes!(ctx.board, %{"security" => [ctx.owner.email]})
      assert board.wait_routes == %{"security" => [ctx.owner.id]}
    end
  end

  describe "where a wait goes" do
    test "a kind's first routed user is who it is on; the rest are told", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email, ctx.ops.email]})
      wait = open!(ctx, ctx.card, %{"needs" => "Which tier first?", "question" => "product"})

      assert wait.question == "product"
      assert wait.on_user_id == ctx.pm.id
      assert Wait.on_name(wait) == Slipdock.Accounts.User.display_name(ctx.pm)

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.pm.email}]
        assert email.subject =~ "is waiting on you"
      end)

      assert_email_sent(fn email ->
        assert email.to == [{"", ctx.ops.email}]
        assert email.subject =~ "(product)"
        assert email.text_body =~ "You are told about product questions"
        assert email.text_body =~ "Which tier first?"
      end)
    end

    test "no kind asks as other, and routes there when other has a route", ctx do
      routes!(ctx.board, %{"other" => [ctx.ops.email]})
      wait = open!(ctx, ctx.card, %{"needs" => "Anything?"})
      assert wait.question == "other"
      assert wait.on_user_id == ctx.ops.id
    end

    test "no kind and no route waits on anyone, as before routing", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email]})
      wait = open!(ctx, ctx.card, %{"needs" => "Anything?"})
      assert wait.question == "other"
      assert wait.on_user_id == nil
    end

    test "a kind with no route falls back to the owner", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email]})
      wait = open!(ctx, ctx.card, %{"needs" => "Is this safe?", "question" => "security"})
      assert wait.question == "security"
      assert wait.on_user_id == ctx.owner.id
    end

    test "a named person wins over the route", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email]})

      wait =
        open!(ctx, ctx.card, %{
          "needs" => "?",
          "question" => "product",
          "on_user_id" => ctx.rel.id
        })

      assert wait.on_user_id == ctx.rel.id
      assert wait.question == "product"
    end

    test "an unknown kind is refused", ctx do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Boards.open_wait(ctx.card, ctx.agent, %{"needs" => "?", "question" => "finance"})

      assert {"is product, ux, security, release or other", _} = errors[:question]
      assert Boards.current_wait(ctx.card) == nil
    end

    test "a sub-board uses its own route, else its parent's", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email], "ux" => [ctx.ops.email]})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      sub = routes!(sub, %{"ux" => [ctx.rel.email]})
      subcard = card_fixture(hd(Boards.get_board!(sub.id).columns), %{"title" => "Child"})

      assert open!(ctx, subcard, %{"needs" => "?", "question" => "product"}).on_user_id ==
               ctx.pm.id

      {:ok, _} = Boards.withdraw_wait(subcard, Actor.web(ctx.owner))
      assert open!(ctx, subcard, %{"needs" => "?", "question" => "ux"}).on_user_id == ctx.rel.id
    end

    test "a routed user who can't read the card is passed over", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email, ctx.ops.email]})
      grant = Repo.get_by!(Access.Grant, board_id: ctx.board.id, user_id: ctx.pm.id)
      # Taken away behind the table's back: the place still skips them.
      Repo.delete!(grant)
      assert {on, []} = WaitRoutes.place(Repo.get!(Card, ctx.card.id), "product")
      assert on.id == ctx.ops.id
    end
  end

  describe "the server's own questions" do
    setup ctx do
      {:ok, board} = Boards.update_board(ctx.board, %{"verify_work" => true})
      checker = %{ctx.agent | agent: "checker"}
      %{board: board, checker: checker}
    end

    defp submit(card, actor) do
      {:ok, card} =
        Boards.update_card(
          Repo.get!(Card, card.id),
          %{"completed" => true, "evidence" => "ran it", "evidence_commit" => "abc1234"},
          actor: actor
        )

      card
    end

    defp reject(card, ctx, n) do
      {:ok, card} =
        Verified.decide(
          Repo.get!(Card, card.id),
          "reject",
          %{"reason" => "bar 1: try #{n}"},
          ctx.checker,
          ctx.owner
        )

      card
    end

    test "the rejection-limit wait asks as release, on release's first person", ctx do
      routes!(ctx.board, %{"release" => [ctx.rel.email, ctx.ops.email]})
      card = card_fixture(ctx.doing, %{"title" => "Bounce"})
      for n <- 1..3, do: card |> submit(ctx.agent) |> reject(ctx, n)

      wait = Repo.get_by!(Wait, card_id: card.id)
      assert wait.purpose == "verify_limit"
      assert wait.question == "release"
      assert wait.on_user_id == ctx.rel.id
    end

    test "with no release route, the rejection-limit wait is on the owner", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Bounce"})
      for n <- 1..3, do: card |> submit(ctx.agent) |> reject(ctx, n)

      wait = Repo.get_by!(Wait, card_id: card.id)
      assert wait.question == "release"
      assert wait.on_user_id == ctx.owner.id
    end

    test "an audit disagreement is emailed to release's people", ctx do
      routes!(ctx.board, %{"release" => [ctx.rel.email, ctx.ops.email]})
      card = card_fixture(ctx.doing, %{"title" => "Accepted"})

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [
          verify_state: "accepted",
          completed: true,
          verify_by: %{"kind" => "agent", "agent" => "checker", "via" => "mcp"}
        ]
      )

      assert {:ok, _} =
               Verified.decide(
                 Repo.get!(Card, card.id),
                 "disagree",
                 %{"reason" => "bar 1: the empty case fails"},
                 Actor.web(ctx.pm),
                 ctx.pm
               )

      for person <- [ctx.rel, ctx.ops] do
        assert_email_sent(fn email ->
          assert email.to == [{"", person.email}]
          assert email.subject == "An audit disagrees with the acceptance of ##{card.id}"
          assert email.text_body =~ "bar 1: the empty case fails"
        end)
      end
    end

    test "tell sends nothing when the kind has no route", ctx do
      assert :ok = WaitRoutes.tell(ctx.card, "release", "x", "y")
      refute_email_sent()
    end
  end

  describe "a routed user leaving" do
    test "comes off the routes, and their open waits go to the owner with a comment", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email, ctx.ops.email], "ux" => [ctx.pm.email]})
      wait = open!(ctx, ctx.card, %{"needs" => "Which tier?", "question" => "product"})
      assert wait.on_user_id == ctx.pm.id

      grant = Repo.get_by!(Access.Grant, board_id: ctx.board.id, user_id: ctx.pm.id)
      {:ok, _} = Access.revoke(grant)

      assert Repo.get!(Boards.Board, ctx.board.id).wait_routes == %{"product" => [ctx.ops.id]}
      assert Repo.get!(Wait, wait.id).on_user_id == ctx.owner.id
      assert Enum.any?(comments(ctx.card), &(&1 =~ "**Wait moved** to"))
      assert Enum.any?(comments(ctx.card), &(&1 =~ "is no longer on the board"))
    end

    test "someone not routed, or still on the board, changes nothing", ctx do
      routes!(ctx.board, %{"product" => [ctx.pm.email]})
      wait = open!(ctx, ctx.card, %{"needs" => "?", "question" => "product"})
      grant = Repo.get_by!(Access.Grant, board_id: ctx.board.id, user_id: ctx.rel.id)
      {:ok, _} = Access.revoke(grant)

      assert Repo.get!(Boards.Board, ctx.board.id).wait_routes == %{"product" => [ctx.pm.id]}
      assert Repo.get!(Wait, wait.id).on_user_id == ctx.pm.id
      refute Enum.any?(comments(ctx.card), &(&1 =~ "Wait moved"))
    end
  end

  test "Waiting on you shows the routed person their own, and not the owner", ctx do
    routes!(ctx.board, %{"product" => [ctx.pm.email]})
    wait = open!(ctx, ctx.card, %{"needs" => "Which tier?", "question" => "product"})

    assert [%{reason: "wait", wait: %{id: wait_id}}] =
             ctx.pm |> Work.waiting_on_me() |> Enum.filter(&(&1.card.id == ctx.card.id))

    assert wait_id == wait.id
    refute Enum.any?(Work.waiting_on_me(ctx.owner), &(&1.wait && &1.wait.id == wait.id))
    refute Enum.any?(Work.waiting_on_me(ctx.ops), &(&1.card.id == ctx.card.id))
  end
end
