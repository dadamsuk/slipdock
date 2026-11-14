defmodule SlipdockWeb.AsyncActorTest do
  @moduledoc """
  A LiveView's `start_async/3` runs its function in a task, a process of its
  own with no actor, so a write it makes would be asked of `Slipdock.Policy`
  as nobody's and refused (#3169: the header's quick add was). Every one
  hands its function through `Slipdock.Actor.carry/1`, which takes the page's
  actor along.

  A repo check (`test/repo_checks.txt`): it reads `lib/slipdock_web/**`.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, Boards, Policy}
  alias Slipdock.Policy.Refused

  @root Path.expand("../..", __DIR__)

  test "every start_async in the web layer carries the actor" do
    bare =
      for path <- Path.wildcard(Path.join(@root, "lib/slipdock_web/**/*.ex")),
          source = File.read!(path),
          {start, _} <- Regex.scan(~r/start_async\(/, source, return: :index) |> List.flatten(),
          # The call's name, then its function: `Actor.carry(fn` before the
          # first `fn` after the name.
          not (binary_part(source, start, min(200, byte_size(source) - start)) =~
                 ~r/\Astart_async\(\s*(\{[^}]*\}|[^,{]+),\s*(Slipdock\.)?Actor\.carry\(fn/),
          do: "#{Path.relative_to(path, @root)}:#{line_of(source, start)}"

    assert bare == [],
           "start_async/3 without Slipdock.Actor.carry/1 (the task would write as nobody): " <>
             Enum.join(bare, ", ")
  end

  defp line_of(source, offset),
    do: source |> binary_part(0, offset) |> String.split("\n") |> length()

  describe "carry/1" do
    setup do
      owner = user_fixture("carry.owner@example.com")
      board = board_fixture(%{"name" => "Carried"}, owner: owner)
      reader = user_fixture("carry.reader@example.com")
      {:ok, _} = Access.grant(board, reader, "read", owner)
      Policy.forbid_nobody()
      %{owner: owner, column: hd(board.columns), reader: reader}
    end

    defp in_task(fun), do: fun |> Task.async() |> Task.await()

    test "a task writes as the person the page acts for", ctx do
      Actor.put(Actor.web(ctx.owner), "Owner", {ctx.owner, nil})

      assert {:ok, card} =
               in_task(
                 Actor.carry(fn -> Boards.Cards.create_card(ctx.column, %{"title" => "T"}) end)
               )

      assert card.title == "T"
    end

    test "and is refused as that person when they may not", ctx do
      Actor.put(Actor.web(ctx.reader), nil, {ctx.reader, nil})

      assert {:error, %Refused{by: :user}} =
               in_task(
                 Actor.carry(fn -> Boards.Cards.create_card(ctx.column, %{"title" => "T"}) end)
               )
    end

    test "without it, the task is nobody and is refused", ctx do
      Actor.put(Actor.web(ctx.owner), nil, {ctx.owner, nil})

      assert {:error, %Refused{by: :nobody}} =
               in_task(fn -> Boards.Cards.create_card(ctx.column, %{"title" => "T"}) end)
    end
  end
end
