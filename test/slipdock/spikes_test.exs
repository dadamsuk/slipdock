defmodule Slipdock.SpikesTest do
  @moduledoc """
  The resume wait (#2350): accepting an epic's last open spike opens one
  wait on the epic, routed `product`, naming every spike and its answer
  page. A spike accepted while another is open opens none, an archived
  spike counts as answered, an epic already waiting gets no second one,
  and a spike with no epic above it opens nothing.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Repo, Spikes, Verified}
  alias Slipdock.Boards.{Card, Wait}

  @why "spike: answer on the page, prototype on card-1"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Plans", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "evidence_required" => true,
        "ship_via" => "pull_request"
      })

    [_backlog, _todo, doing, _done] = board.columns
    epic = card_fixture(doing, %{"title" => "Feature"})
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    {:ok, sub} = sub_board(epic, t)
    [column | _] = Boards.get_board!(sub.id).columns
    builder = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "builder"}
    checker = %{Actor.unknown() | kind: "agent", via: "api", user_id: owner.id, agent: "checker"}

    %{
      owner: owner,
      board: board,
      doing: doing,
      epic: epic,
      sub: sub,
      column: column,
      builder: builder,
      checker: checker
    }
  end

  defp spike(column, title) do
    card = card_fixture(column, %{"title" => title})
    {:ok, card} = Boards.Cards.update_card(card, %{"profile" => "spike"})
    card
  end

  defp fresh(card), do: Repo.get!(Card, card.id)

  defp submit(card, ctx) do
    {:ok, card} =
      Boards.Cards.update_card(
        fresh(card),
        %{"completed" => true, "evidence" => "built it", "evidence_no_code" => @why},
        actor: ctx.builder
      )

    assert card.verify_state == "pending"
    card
  end

  defp accept(card, ctx) do
    {:ok, card} = Verified.decide(fresh(card), "accept", %{}, ctx.checker, ctx.owner)
    assert card.verify_state == "accepted"
    card
  end

  defp waits(card), do: Repo.all(from(w in Wait, where: w.card_id == ^card.id))

  describe "the last spike accepted" do
    test "opens one product wait on the epic naming every spike and its answer page", ctx do
      one = spike(ctx.column, "Does the API page?")
      two = spike(ctx.column, "Is the import fast enough?")

      page =
        page_fixture(ctx.board, %{"title" => "Answer: paging", "body" => "Answers ##{one.id}."})

      {:ok, _} = Slipdock.Wiki.pin(page, {:card, ctx.epic})

      one |> submit(ctx) |> accept(ctx)
      assert waits(ctx.epic) == []

      two |> submit(ctx) |> accept(ctx)

      assert [wait] = waits(ctx.epic)
      assert wait.question == "product"
      assert wait.purpose == Spikes.purpose()
      assert is_nil(wait.closed_at)
      assert wait.needs =~ "Spikes answered (##{one.id}, ##{two.id}): resume planning"
      assert wait.needs =~ "##{one.id} #{page.code} Answer: paging"
      assert wait.needs =~ "##{two.id} (no answer page references it)"
      assert "waiting" in fresh(ctx.epic).flags
    end

    test "a spike accepted while another is submitted but open opens nothing", ctx do
      one = spike(ctx.column, "One")
      two = spike(ctx.column, "Two")
      submit(two, ctx)
      one |> submit(ctx) |> accept(ctx)
      assert waits(ctx.epic) == []
    end

    test "an archived spike counts as answered, and isn't named", ctx do
      one = spike(ctx.column, "Kept")
      dropped = spike(ctx.column, "Dropped")
      {:ok, _} = Boards.Cards.archive_card(dropped)

      one |> submit(ctx) |> accept(ctx)

      assert [wait] = waits(ctx.epic)
      assert wait.needs =~ "Spikes answered (##{one.id}): resume planning"
      refute wait.needs =~ "##{dropped.id}"
    end

    test "cards that aren't spikes don't hold it back", ctx do
      card_fixture(ctx.column, %{"title" => "Build the thing"})
      ctx.column |> spike("Only spike") |> submit(ctx) |> accept(ctx)
      assert [_] = waits(ctx.epic)
    end

    test "a hand-tagged spike counts", ctx do
      card = card_fixture(ctx.column, %{"title" => "Tagged"})
      {:ok, card} = Boards.Cards.set_card_tags(card, [tag_fixture(ctx.sub, "spike")])
      card |> submit(ctx) |> accept(ctx)
      assert [_] = waits(ctx.epic)
    end
  end

  describe "no wait" do
    test "when the epic has a wait open already", ctx do
      {:ok, _} =
        Boards.Waits.open_wait(ctx.epic, Actor.web(ctx.owner), %{
          needs: "Which way?",
          question: "ux"
        })

      ctx.column |> spike("Only") |> submit(ctx) |> accept(ctx)

      assert [wait] = waits(ctx.epic)
      assert wait.needs == "Which way?"
    end

    test "for a spike with no epic above it", ctx do
      top = spike(ctx.doing, "Top-level spike")
      top |> submit(ctx) |> accept(ctx)
      assert waits(top) == []
      assert waits(ctx.epic) == []
    end

    test "for a card that isn't a spike", ctx do
      card = card_fixture(ctx.column, %{"title" => "Plain"})

      {:ok, card} =
        Boards.Cards.update_card(card, %{"completed" => true, "evidence_no_code" => @why},
          actor: ctx.builder
        )

      accept(card, ctx)
      assert waits(ctx.epic) == []
    end

    test "on a later save of a spike already accepted, once the resume wait is answered",
         ctx do
      s = ctx.column |> spike("Only") |> submit(ctx) |> accept(ctx)
      assert [_] = waits(ctx.epic)

      {:ok, _} =
        Boards.Waits.answer_wait(fresh(ctx.epic), Actor.web(ctx.owner), %{"answer" => "Resuming"})

      assert [%Wait{closed_at: %DateTime{}}] = waits(ctx.epic)

      merging = %{fresh(s) | verify_state: "merging"}
      accepted = fresh(s)
      assert accepted.verify_state == "accepted"

      # merging -> accepted, and an accepted spike edited again: neither
      # accepts it now, so neither opens a second wait.
      assert Spikes.answered(merging, accepted) == :none
      assert Spikes.answered(accepted, %{accepted | title: "Only, renamed"}) == :none

      {:ok, _} = Boards.Cards.update_card(fresh(s), %{"title" => "Only, renamed"})

      assert [%Wait{closed_at: %DateTime{}}] = waits(ctx.epic)
    end

    test "for a spike submitted but not yet accepted", ctx do
      ctx.column |> spike("Pending") |> submit(ctx)
      assert waits(ctx.epic) == []
    end
  end

  test "on a board that doesn't verify, completing the last spike opens it", ctx do
    {:ok, _} = Boards.update_board(Repo.get!(Boards.Board, ctx.sub.id), %{"verify_work" => false})
    s = spike(ctx.column, "Unverified")
    {:ok, _} = Boards.Cards.update_card(fresh(s), %{"completed" => true})
    assert [wait] = waits(ctx.epic)
    assert wait.needs =~ "##{s.id}"
  end
end
