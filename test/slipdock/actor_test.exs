defmodule Slipdock.ActorTest do
  @moduledoc """
  Who moved a card, and through which door (`Slipdock.Actor`): how a request
  is classified, the fallback for a move nobody named, and the moves made by
  rules, Recovery and the board's own code paths.
  """
  use Slipdock.DataCase, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Actor, Boards, MoveRecorder, Repo, Runners}
  alias Slipdock.Boards.Card

  setup do
    MoveRecorder.attach()
    owner = user_fixture()
    board = board_fixture(%{"name" => "Actors"}, owner: owner)
    [backlog, todo, doing, done] = board.columns
    %{owner: owner, board: board, backlog: backlog, todo: todo, doing: doing, done: done}
  end

  defp conn(user, token \\ nil, headers \\ []) do
    conn = %Plug.Conn{
      Phoenix.ConnTest.build_conn()
      | assigns: %{current_user: user, api_token: token}
    }

    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  defp token(user, label) do
    {_secret, token} = Accounts.create_api_token(user, label)
    token
  end

  describe "from_conn/1" do
    test "a signed-in browser with no token is a person on the web", %{owner: owner} do
      assert %{kind: "human", via: "web", user_id: id, agent: nil, job_id: nil} =
               Actor.from_conn(conn(owner))

      assert id == owner.id
    end

    test "a token with no client header is an agent over the API", %{owner: owner} do
      t = token(owner, "deploy-script")

      assert %{kind: "agent", via: "api", agent: "deploy-script", job_id: nil} =
               Actor.from_conn(conn(owner, t))
    end

    test "the CLI is a person, unless it says it is an agent", %{owner: owner} do
      t = token(owner, "laptop")

      assert %{kind: "human", via: "cli", agent: "laptop"} =
               Actor.from_conn(conn(owner, t, [{"x-slipdock-client", "cli"}]))

      assert %{kind: "agent", via: "cli", agent: "laptop", job_id: 42} =
               Actor.from_conn(
                 conn(owner, t, [
                   {"x-slipdock-client", "cli"},
                   {"x-slipdock-agent", "1"},
                   {"x-slipdock-job", "42"}
                 ])
               )
    end

    test "an agent header of 0 or false is no agent, and a bad job id is dropped",
         %{owner: owner} do
      t = token(owner, "laptop")

      for off <- ["0", "false", ""] do
        assert %{kind: "human"} =
                 Actor.from_conn(
                   conn(owner, t, [{"x-slipdock-client", "cli"}, {"x-slipdock-agent", off}])
                 )
      end

      for bad <- ["nope", "-3", "0", "4x"] do
        assert %{kind: "agent", job_id: nil} =
                 Actor.from_conn(
                   conn(owner, t, [
                     {"x-slipdock-client", "cli"},
                     {"x-slipdock-agent", "1"},
                     {"x-slipdock-job", bad}
                   ])
                 )
      end
    end

    test "an actor already worked out wins, as MCP hands CardWrites", %{owner: owner} do
      actor = Actor.mcp(%{user: owner, token: token(owner, "claude")})
      assert Actor.from_conn(%{assigns: %{current_user: owner, actor: actor}}) == actor
      assert %{kind: "agent", via: "mcp", agent: "claude"} = actor
    end
  end

  describe "resolve/1" do
    test "takes an actor as given, or builds one from by/via/agent/job_id", %{owner: owner} do
      assert Actor.resolve(actor: Actor.automation()) == Actor.automation()

      assert %{kind: "human", via: "web", user_id: id} = Actor.resolve(by: owner, via: "web")
      assert id == owner.id

      assert %{kind: "agent", via: "runner", agent: "box", job_id: 7} =
               Actor.resolve(by: owner, via: "runner", agent: "box", job_id: 7)

      assert %{kind: "automation"} = Actor.resolve(via: "automation")
      assert %{kind: "agent", via: "cli"} = Actor.resolve(via: "cli", kind: "agent")
    end

    test "with nothing given: automation inside a rule, else unknown" do
      assert Actor.resolve([]) == Actor.unknown()

      Process.put(:automation_depth, 1)

      try do
        assert %{kind: "automation", via: "automation"} = Actor.resolve([])
      after
        Process.delete(:automation_depth)
      end
    end
  end

  describe "moves carry their actor" do
    test "move_card/4 to another list, with the person who did it", ctx do
      card = card_fixture(ctx.todo)
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))
      id = card.id
      owner_id = ctx.owner.id
      doing = ctx.doing.id

      assert_receive {:moved,
                      %{
                        card_id: ^id,
                        to_column_id: ^doing,
                        actor: %{kind: "human", via: "web", user_id: ^owner_id}
                      }}
    end

    test "a reorder inside one list is no move", ctx do
      card = card_fixture(ctx.todo)
      card_fixture(ctx.todo)
      :ok = Boards.move_card_to_index(card, ctx.todo, :bottom, actor: Actor.web(ctx.owner))
      id = card.id
      refute_receive {:moved, %{card_id: ^id}}
    end

    test "a move nobody names, inside a rule, is automation's", ctx do
      card = card_fixture(ctx.todo)
      id = card.id
      Process.put(:automation_depth, 1)

      try do
        :ok = Boards.move_card(card.id, ctx.doing.id)
      after
        Process.delete(:automation_depth)
      end

      assert_receive {:moved, %{card_id: ^id, actor: %{kind: "automation"}}}
    end

    test "a move nobody names, outside one, is unknown", ctx do
      card = card_fixture(ctx.todo)
      id = card.id
      :ok = Boards.move_card(card.id, ctx.doing.id)
      assert_receive {:moved, %{card_id: ^id, actor: %{kind: nil, via: nil}}}
    end

    test "the card_moved event rules see carries it too", ctx do
      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "card_moved", "to" => ctx.doing.name},
          "actions" => [%{"type" => "move_card", "column" => ctx.done.name}]
        })

      card = card_fixture(ctx.todo)
      id = card.id
      done = ctx.done.id
      :ok = Boards.move_card(card.id, ctx.doing.id, nil, actor: Actor.web(ctx.owner))

      # The person's move first, then the rule's, which is automation's.
      assert_receive {:moved, %{card_id: ^id, actor: %{kind: "human"}}}

      assert_receive {:moved, %{card_id: ^id, to_column_id: ^done, actor: %{kind: "automation"}}}

      assert Repo.get!(Card, id).column_id == ctx.done.id
      assert rule.id
    end

    test "move_card_to_board/3 to another board, and within the same one", ctx do
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      card = card_fixture(ctx.todo)
      id = card.id

      {:ok, _} =
        Boards.move_card_to_board(card, hd(other.columns), actor: Actor.assistant(ctx.owner))

      assert_receive {:moved, %{card_id: ^id, actor: %{kind: "agent", via: "assistant"}}}

      back = Repo.get!(Card, id)
      [_, todo2 | _] = Boards.get_board!(other.id).columns

      {:ok, _} = Boards.move_card_to_board(back, todo2, actor: Actor.web(ctx.owner))
      assert_receive {:moved, %{card_id: ^id, actor: %{kind: "human", via: "web"}}}
    end

    test "a list_top rule's move_card action is automation's", ctx do
      {:ok, _runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "list_top", "column" => ctx.todo.name},
        "actions" => [
          %{"type" => "runner", "pool" => "loop"},
          %{"type" => "move_card", "column" => ctx.doing.name}
        ]
      })

      card = card_fixture(ctx.todo)
      id = card.id
      doing = ctx.doing.id
      Slipdock.Automations.feed_board(ctx.board.id)

      assert_receive {:moved, %{card_id: ^id, to_column_id: ^doing, actor: %{kind: "automation"}}}
    end

    test "Recovery's requeue is automation's", ctx do
      {:ok, runner, _} = Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "loop"})

      rule_fixture(ctx.board, %{
        "trigger" => %{"type" => "list_top", "column" => ctx.todo.name},
        "actions" => [%{"type" => "runner", "pool" => "loop", "requeue_stuck" => 1}]
      })

      card = card_fixture(ctx.todo)
      id = card.id
      todo = ctx.todo.id
      job = Runners.claim(runner)
      assert job.card_id == id

      :ok =
        Boards.move_card_to_index(Repo.get!(Card, id), ctx.doing, :top,
          actor: Actor.runner(ctx.owner, job.id, "box")
        )

      assert_receive {:moved, %{card_id: ^id, actor: %{kind: "agent", via: "runner"}}}

      {:ok, _} = Runners.finish(runner, job.id, %{status: "failed"})

      assert_receive {:moved,
                      %{
                        card_id: ^id,
                        to_column_id: ^todo,
                        actor: %{kind: "automation", via: "automation"}
                      }}
    end
  end

  describe "Card.changeset/2" do
    test "update_card can't move a card by column_id", ctx do
      card = card_fixture(ctx.todo)

      {:ok, updated} =
        Boards.update_card(card, %{"column_id" => ctx.doing.id, "title" => "Renamed"})

      assert updated.title == "Renamed"
      assert Repo.get!(Card, card.id).column_id == ctx.todo.id
      id = card.id
      refute_receive {:moved, %{card_id: ^id}}
    end

    test "create_card still puts a card in its list", ctx do
      card = card_fixture(ctx.doing, %{"title" => "New"})
      assert card.column_id == ctx.doing.id
    end
  end
end
