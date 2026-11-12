defmodule Slipdock.VerifyEvidenceStanceTest do
  @moduledoc """
  The verifier's stance (#2696): the builder's evidence says where to look,
  and each claim in it is checked, not carried. The mutation step breaks
  every guard or branch the diff adds on top of its 3 to 5, and a mutant
  the builder says it killed is carried only when re-run or plainly covered
  by a named test; an audit asks for the same guard mutants and carries
  none. The prompts stay inside the runner's prompt cap (SPEC-4).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Runners, Verified}

  @guard "On top of those, break once each guard or branch the diff adds (a new condition, clause, pattern match or early return), naming each with its line: a survivor there is a rejection like any other."

  setup %{user: user} do
    board = board_fixture(%{"name" => "Stance", "code" => unique_code()}, owner: user)
    {:ok, board} = Boards.update_board(board, %{"verify_work" => true, "profiles" => true})
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    %{board: board, doing: doing}
  end

  defp card(ctx, profile, attrs \\ %{}) do
    card = card_fixture(ctx.doing, Map.merge(%{"title" => "Work", "bar" => "1. Done"}, attrs))
    {:ok, card} = Boards.Cards.update_card(card, %{"profile" => profile})
    card
  end

  defp accepted(card), do: %{card | verify_state: "accepted", verify_note: "looked fine"}

  describe "the stance" do
    test "the evidence is where to look and each claim is checked", ctx do
      prompt = Verified.verify_prompt(card(ctx, "feature"), ctx.board)

      refute prompt =~ "redo it"
      assert prompt =~ "don't change the code or the card beyond your decision"

      assert prompt =~
               "The builder's evidence says where to look, not what to believe: check each claim in it, never carry one on its word."

      assert prompt =~
               "A test it names is read and run, a mutant it says was killed is broken again or sampled, a docs place it says it updated is opened."
    end

    test "it holds on a card with no mutation step too", ctx do
      prompt = Verified.verify_prompt(card(ctx, "docs"), ctx.board)
      refute prompt =~ "redo it"
      assert prompt =~ "says where to look, not what to believe"
      refute prompt =~ @guard
    end
  end

  describe "the guard mutants" do
    test "the verify prompt asks for one on every guard the diff adds", ctx do
      for profile <- Verified.mutation_profiles() do
        prompt = Verified.verify_prompt(card(ctx, profile), ctx.board)
        assert prompt =~ @guard, profile
        # On top of the 3 to 5, not in place of them.
        assert :binary.match(prompt, "pick 3 to 5") < :binary.match(prompt, @guard)
      end
    end

    test "the audit prompt asks for them too", ctx do
      prompt = Verified.audit_prompt(accepted(card(ctx, "feature")), ctx.board)
      assert prompt =~ @guard
    end

    test "no mutation step, no guard ask", ctx do
      {:ok, off} = Boards.update_board(ctx.board, %{"profiles" => false})
      refute Verified.verify_prompt(card(ctx, "feature"), off) =~ @guard
      refute Verified.audit_prompt(accepted(card(ctx, "feature")), off) =~ @guard
    end
  end

  describe "the builder's mutants are a map" do
    @evidence "Built it.\n- mutant:killed=lib/a.ex:42:flip > to >=\n"

    test "a verifier carries a killed one only when re-run or plainly covered", ctx do
      step = Verified.mutation_step(card(ctx, "feature", %{"evidence" => @evidence}))

      assert step =~ "`mutant:killed=lib/a.ex:42:flip > to >=`"
      assert step =~ "That list is a map, not a verdict."

      assert step =~
               "One it says was killed is carried only when you broke it again yourself (give your result) or a test the builder names plainly covers that line (`--check mutant:carried=<file>:<line>`, and say which test); otherwise break it again."

      refute step =~ "Don't break those again"
      refute step =~ "An audit carries nothing"
    end

    test "an audit is told to carry none of them", ctx do
      card = card(ctx, "feature", %{"evidence" => @evidence})
      step = Verified.mutation_step(card, audit: true)

      assert step =~
               "An audit carries nothing: break again each one it says was killed, or give your own result for its line."

      refute step =~ "mutant:carried"
      assert Verified.audit_prompt(accepted(card), ctx.board) =~ "An audit carries nothing"
    end

    test "a builder that named none gets no map note", ctx do
      step = Verified.mutation_step(card(ctx, "feature", %{"evidence" => "Built it."}))
      assert step =~ "The builder named no mutants in its evidence"
      refute step =~ "That list is a map"
    end
  end

  test "the prompts stay inside the runner's prompt cap (SPEC-4)", ctx do
    evidence =
      Enum.map_join(1..20, "\n", &"- mutant:killed=lib/a.ex:#{&1}:flip > to >=") <> "\nBuilt."

    card =
      card(ctx, "security", %{
        "evidence" => evidence,
        "description" => String.duplicate("a", 5000)
      })

    for prompt <- [
          Verified.verify_prompt(card, ctx.board),
          Verified.audit_prompt(accepted(card), ctx.board)
        ] do
      assert byte_size(prompt) <= Runners.limits().max_prompt
    end
  end

  describe "the help pages" do
    defp text(html, selector \\ "main") do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.replace(~r/\s+/u, " ")
    end

    test "HelpLive.Agents describes the mutation review as changed", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents/runners")
      text = text(html)
      assert text =~ "3 to 5 of its most consequential lines and every guard or branch it adds"
      assert text =~ "checks each claim in the builder's evidence rather than carry it"
    end

    test "HelpLive.Flow says the builder's list is a map", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help/agents/flow")
      text = text(html, "#flow-verifying")
      assert text =~ "every guard or branch the change adds"
      assert text =~ "that list is a map, not a verdict"
      refute text =~ "breaks other lines rather than repeat them"
    end
  end

  test "the manual says it", _ctx do
    manual = File.read!("docs/manual/verified-work.md") |> String.replace(~r/\s+/, " ")
    assert manual =~ "The builder's evidence says where to look, not what to believe (#2696)"
    assert manual =~ "every guard or branch the diff adds"
    assert manual =~ "An audit asks for the same guard mutants and carries none."
  end
end
