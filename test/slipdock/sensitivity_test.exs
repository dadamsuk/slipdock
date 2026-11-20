defmodule Slipdock.SensitivityTest do
  @moduledoc """
  A board tree's sensitivity (#3552): low, medium (the default) or high,
  kept on the root and read from it; a sub-board's write refused. What it
  changes beyond the human tier (`profiles_tier_test.exs`): a card job's
  prompt says how to decide or ask at low and high and nothing at medium,
  and approval waits never go ahead by their default at high. Export and
  import carry it.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners, Sensitivity, WaitDefaults}
  alias Slipdock.Boards.Board

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Sense", "code" => unique_code()}, owner: owner)
    [_backlog, todo, _doing, _done] = board.columns
    %{owner: owner, board: board, todo: todo}
  end

  defp level!(board, level) do
    {:ok, board} = Boards.update_board(Repo.get!(Board, board.id), %{"sensitivity" => level})
    board
  end

  defp sub!(todo) do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(card_fixture(todo, %{"title" => "Epic"}), t)
    Boards.get_board!(sub.id)
  end

  describe "the setting" do
    test "is medium by default, and takes each level, any case", ctx do
      assert ctx.board.sensitivity == "medium"
      assert Sensitivity.of(ctx.board) == "medium"
      assert level!(ctx.board, " High ").sensitivity == "high"
      assert level!(ctx.board, "low").sensitivity == "low"
      # Blank or default puts it back.
      assert level!(ctx.board, "default").sensitivity == "medium"
    end

    test "refuses anything that isn't a level", ctx do
      assert {:error, cs} = Boards.update_board(ctx.board, %{"sensitivity" => "paranoid"})
      assert {"must be low, medium or high", _} = cs.errors[:sensitivity]
      assert Repo.get!(Board, ctx.board.id).sensitivity == "medium"
    end

    test "a sub-board reads the root's, and a write to it is refused naming the root", ctx do
      sub = sub!(ctx.todo)
      level!(ctx.board, "high")
      assert Sensitivity.of(sub) == "high"
      assert Sensitivity.of(card_fixture(hd(sub.columns), %{"title" => "Task"})) == "high"

      assert {:error, cs} = Boards.update_board(sub, %{"sensitivity" => "low"})
      {message, _} = cs.errors[:sensitivity]
      assert message =~ "root board (##{ctx.board.id})"
      assert Repo.get!(Board, sub.id).sensitivity == "medium"
      assert Sensitivity.of(sub) == "high"
    end

    test "export and import carry a root's level; an unknown one imports as medium", ctx do
      level!(ctx.board, "high")
      doc = Slipdock.Portable.export(ctx.owner, boards: [Boards.get_board!(ctx.board.id)])
      [tree] = doc.boards
      assert tree.root.sensitivity == "high"

      {:ok, report} = Slipdock.Portable.import(ctx.owner, Jason.encode!(doc))
      assert Boards.get_board!(hd(report.boards).id).sensitivity == "high"

      odd = put_in(doc.boards, [Map.update!(tree, :root, &Map.put(&1, :sensitivity, "max"))])
      {:ok, report} = Slipdock.Portable.import(ctx.owner, Jason.encode!(odd))
      assert Boards.get_board!(hd(report.boards).id).sensitivity == "medium"
    end
  end

  describe "a card job's prompt" do
    defp prompt(ctx) do
      card = card_fixture(ctx.todo, %{"title" => "Jokes"})
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
      Runners.claimed_prompt(Repo.reload!(job))
    end

    test "says nothing at medium", ctx do
      refute prompt(ctx) =~ "sensitivity"
    end

    test "at low, says to decide for itself and still ask security", ctx do
      level!(ctx.board, "low")
      text = prompt(ctx)
      assert text =~ "This board's sensitivity is low"
      assert text =~ "choose the option you would recommend yourself"
      assert text =~ "Still open a `security` wait"
    end

    test "at high, says to ask before any material choice", ctx do
      level!(ctx.board, "high")
      text = prompt(ctx)
      assert text =~ "This board's sensitivity is high"
      assert text =~ "open a wait"
      assert text =~ "personal or customer data"
    end

    test "a subcard's job goes by the root's level", ctx do
      sub = sub!(ctx.todo)
      level!(ctx.board, "low")
      card = card_fixture(hd(sub.columns), %{"title" => "Task"})
      {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
      assert Runners.claimed_prompt(Repo.reload!(job)) =~ "sensitivity is low"
    end
  end

  describe "approvals that go ahead by default" do
    test "go ahead at low and medium, never at high", ctx do
      {:ok, _} = Boards.update_board(ctx.board, %{"wait_default_after" => "4h"})
      card = card_fixture(ctx.todo, %{"title" => "Copy"})
      assert WaitDefaults.after_minutes(card) == 240

      level!(ctx.board, "low")
      assert WaitDefaults.after_minutes(card) == 240

      level!(ctx.board, "high")
      assert WaitDefaults.after_minutes(card) == nil
    end
  end
end
