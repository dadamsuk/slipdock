defmodule Slipdock.VerifyPromptFitTest do
  @moduledoc """
  The verify and audit prompts fit the runners' prompt cap by construction
  (#2705): the parts that grow with the card (the evidence, the last
  verdict's parts and reason, the description, the bar, the board's audit
  misses) are cut, in that order, with a pointer to the card, until the
  prompt fits; a card that fits is never cut. #2692 and #2698 sat stuck
  because their verify prompts were refused for size.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Findings, Handbook, Repo, Runners, Verified}
  alias Slipdock.Boards.{Board, Card}

  @cut "cut short to fit the prompt: the rest is on the card"
  # The prompts' last sentences: a cut of the prompt itself would take them.
  @verify_end "so say exactly what to fix.\n"
  @audit_end "or when it failed a part that holds.\n"

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "Fit", "code" => unique_code()}, owner: owner)
    {:ok, _} = Handbook.install(owner, board)

    Repo.update_all(from(b in Board, where: b.id == ^board.id),
      set: [
        verify_work: true,
        verify_pool: "verify",
        ship_via: "pull_request",
        profiles: true,
        verify_audit: 1
      ]
    )

    board = Boards.get_board!(board.id)
    doing = Enum.find(board.columns, &(&1.category == "doing"))
    %{owner: owner, board: board, doing: doing}
  end

  defp max, do: Runners.limits().max_prompt

  # Thirty mutant lines, then prose: the shape #2635 asks a builder for.
  defp evidence(bytes) do
    mutants =
      Enum.map_join(1..30, "\n", &"- mutant:killed=lib/slipdock/verified.ex:#{&1}:drop the guard")

    mutants <> "\n" <> String.duplicate("Checked the thing in detail. ", div(bytes, 29))
  end

  defp card(ctx, attrs) do
    card = card_fixture(ctx.doing, %{"title" => "Fit"})

    card
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          profile: "feature",
          verify_state: "pending",
          evidence_commit: String.duplicate("a", 40),
          evidence_pr: "https://github.com/example/repo/pull/1",
          evidence_tests: ["test/a_test.exs"]
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  # A last verdict with many parts, judged at a commit: a resubmission.
  defp rejected(card, parts, reason_bytes) do
    mutants =
      for n <- 1..parts,
          do: %{
            "file" => "lib/slipdock/runners.ex",
            "line" => n,
            "mutation" => "flip the condition on line #{n}",
            "result" => "killed"
          }

    checks = %{
      "ask" => "ok",
      "bar" => [%{"item" => "1", "result" => "fail", "note" => String.duplicate("why ", 50)}],
      "mutants" => mutants,
      "decision" => "reject",
      "judged_at" => String.duplicate("b", 40)
    }

    card =
      card |> Ecto.Changeset.change(verify_checks: checks, verify_rejections: 1) |> Repo.update!()

    {:ok, _} =
      Boards.add_comment(
        card,
        "**Rejected** by a verifier.\n\nbar 1: " <>
          String.duplicate("falls short ", div(reason_bytes, 12))
      )

    card
  end

  defp misses(ctx, n) do
    for i <- 1..n do
      other = card_fixture(ctx.doing, %{"title" => "Missed #{i}"})

      {:ok, _} =
        Findings.record(%{
          card: other,
          source: "audit",
          cause: "audit disagrees",
          text: "An audit disagrees with the acceptance: " <> String.duplicate("missed it ", 40)
        })
    end
  end

  describe "the worst case" do
    test "a verify prompt with every part at its largest fits, cut with pointers", ctx do
      misses(ctx, 5)

      card =
        ctx
        |> card(%{
          # Multi-byte: 4,000 characters are 8,000 bytes.
          description: String.duplicate("é", 4000),
          bar: Enum.map_join(1..20, " ", &"#{&1}. #{String.duplicate("a part of done ", 25)}"),
          evidence: evidence(30_000)
        })
        |> rejected(60, 5000)

      prompt = Verified.verify_prompt(card, ctx.board)

      assert byte_size(prompt) <= max()
      assert String.valid?(prompt)
      assert prompt =~ "#{@cut}, `slipdock card #{card.id}`"
      # Cut by its parts, not at its end: the decision step is whole.
      assert prompt =~ @verify_end
      assert prompt =~ "A rejection cites what it fails"
      assert prompt =~ "This card was judged before"
      assert prompt =~ "What audits on this board caught recently"
    end

    test "an audit prompt with a long verdict and evidence fits", ctx do
      card =
        card(ctx, %{
          description: String.duplicate("d", 4000),
          bar: String.duplicate("b", 6000),
          evidence: evidence(30_000),
          verify_state: "accepted",
          verify_note: String.duplicate("checked ", 1500)
        })

      card = rejected(card, 60, 100)
      card = %{card | verify_state: "accepted"}

      prompt = Verified.audit_prompt(card, ctx.board)

      assert byte_size(prompt) <= max()
      assert prompt =~ @cut
      assert prompt =~ @audit_end
      assert prompt =~ "Disagree when any part fails"
    end
  end

  describe "what is cut" do
    test "a card that fits is not cut", ctx do
      card = card(ctx, %{description: "Do it.", bar: "1. Done", evidence: evidence(500)})
      prompt = Verified.verify_prompt(card, ctx.board)

      refute prompt =~ @cut
      assert prompt =~ card.evidence
      assert prompt =~ "1. Done"
    end

    test "a little over cuts the evidence only, and keeps its head", ctx do
      base = card(ctx, %{description: "Do it.", bar: "1. Done", evidence: "x"})
      room = max() - byte_size(Verified.verify_prompt(base, ctx.board))

      # The evidence shows once as prose; its mutant lines show twice (the
      # evidence and the mutation step's map), so plain prose sizes it.
      text = "Evidence starts here. " <> String.duplicate("p", room + 500)
      card = card(ctx, %{description: "Do it.", bar: "1. Done", evidence: text})
      prompt = Verified.verify_prompt(card, ctx.board)

      assert byte_size(prompt) <= max()
      assert prompt =~ "Evidence starts here. ppp"
      assert prompt =~ @cut
      assert prompt =~ "1. Done"
      assert prompt =~ "Do it."
      assert length(String.split(prompt, @cut)) == 2
    end

    test "each part is cut when it alone is too long", ctx do
      small = %{description: "Do it.", bar: "1. Done", evidence: "Built."}
      huge = String.duplicate("long words ", 3000)

      cases = [
        evidence: fn -> card(ctx, %{small | evidence: huge}) end,
        parts: fn -> ctx |> card(small) |> rejected(400, 100) end,
        # (The last rejection's reason is read back cut to 400 characters,
        # so it never takes a verify prompt over alone; the audit's can.)
        # Over the description's own cap: cut as the prompt shows it.
        ask: fn -> card(ctx, %{small | description: String.duplicate("𝄞", 4000) <> "x"}) end,
        bar: fn -> card(ctx, %{small | bar: huge}) end
      ]

      for {part, make} <- cases do
        card = make.()
        prompt = Verified.verify_prompt(card, ctx.board)

        assert byte_size(prompt) <= max(), "#{part}"
        assert prompt =~ @cut, "#{part}"
        assert prompt =~ @verify_end, "#{part}"
      end
    end

    test "a description far over 4,000 characters is cut as the prompt shows it", ctx do
      small = %{description: "Do it.", bar: "1. Done", evidence: "Built."}

      # Three- and four-byte characters: the description's own 4,000
      # character cap leaves 12,000 and 16,000 bytes, and a cut of the raw
      # text past that cap would shrink nothing.
      for description <- [String.duplicate("中", 5000), String.duplicate("𝄞", 8000)] do
        card = card(ctx, %{small | description: description})

        for {prompt, ending} <- [
              {Verified.verify_prompt(card, ctx.board), @verify_end},
              {Verified.audit_prompt(%{card | verify_state: "accepted"}, ctx.board), @audit_end}
            ] do
          assert byte_size(prompt) <= max()
          assert String.valid?(prompt)
          # Cut in the description, once, and the prompt ends whole.
          assert String.ends_with?(prompt, ending)
          assert length(String.split(prompt, @cut)) == 2
          [ask, _] = String.split(prompt, "The bar (what done means):", parts: 2)
          assert ask =~ "#{@cut}, `slipdock card #{card.id}`"
          assert prompt =~ "1. Done"
          assert prompt =~ "Built."
        end
      end
    end

    test "the last verdict's reason is cut, with the pointer in it", ctx do
      card =
        ctx
        |> card(%{description: "Do it.", bar: "1. Done", evidence: "Built."})
        |> rejected(1, 400)

      whole = Verified.verify_prompt(card, ctx.board)
      refute whole =~ @cut
      assert whole =~ "The last verdict's reason: bar 1: falls short"

      # More than the parts give: the reason is cut too.
      prompt = Verified.verify_prompt(card, ctx.board, max: byte_size(whole) - 500)

      assert byte_size(prompt) <= byte_size(whole) - 500
      assert prompt =~ @verify_end
      [_, after_reason] = String.split(prompt, "The last verdict's reason: ", parts: 2)
      [reason, _] = String.split(after_reason, "\nIts parts:", parts: 2)
      assert reason =~ "falls short"
      assert String.ends_with?(reason, "#{@cut}, `slipdock card #{card.id}`)")
      assert prompt =~ "1. Done"
      assert prompt =~ "Built."
    end

    test "the audited verdict's reason and parts are cut when too long", ctx do
      small = %{description: "Do it.", bar: "1. Done", evidence: "Built."}

      for {part, card} <- [
            reason: card(ctx, Map.put(small, :verify_note, String.duplicate("checked ", 4000))),
            parts: ctx |> card(small) |> rejected(400, 100)
          ] do
        prompt = Verified.audit_prompt(%{card | verify_state: "accepted"}, ctx.board)

        assert byte_size(prompt) <= max(), "#{part}"
        assert prompt =~ @cut, "#{part}"
        assert prompt =~ @audit_end, "#{part}"
      end
    end

    test "the audit misses are cut last, once every other part is", ctx do
      misses(ctx, 5)
      card = card(ctx, %{description: "Do it.", bar: "1. Done", evidence: "Built."})
      whole = Verified.verify_prompt(card, ctx.board)
      assert whole =~ "missed it missed it"
      refute whole =~ @cut

      prompt = Verified.verify_prompt(card, ctx.board, max: byte_size(whole) - 400)

      assert byte_size(prompt) <= byte_size(whole) - 400
      assert prompt =~ "What audits on this board caught recently"
      assert prompt =~ @verify_end
      # The card's parts are shorter than a pointer, so they stay: only the
      # misses could give room, and they are cut, not dropped.
      assert prompt =~ "1. Done"
      assert prompt =~ "Built."
      assert length(String.split(prompt, @cut)) == 2
    end

    test "the order: what the card shows is cut first, the audit misses last" do
      assert Verified.prompt_cuts(:verify) == [:evidence, :parts, :reason, :ask, :bar, :misses]
      assert Verified.prompt_cuts(:audit) == [:evidence, :parts, :reason, :ask, :bar]
    end
  end

  describe "fit_prompt/4" do
    setup do
      %{card: %Card{id: 7}}
    end

    test "cuts each part in turn by what is over, re-rendering each time", %{card: card} do
      render = fn cuts ->
        a = Verified.cut(String.duplicate("a", 500), cuts[:a], card)
        b = Verified.cut(String.duplicate("b", 500), cuts[:b], card)
        "head " <> a <> " " <> b
      end

      # Fits: unchanged, nothing cut.
      assert Verified.fit_prompt(card, [:a, :b], render, 2000) == render.(%{})

      # Over by little: only the first part is cut.
      fitted = Verified.fit_prompt(card, [:a, :b], render, 900)
      assert byte_size(fitted) <= 900
      assert fitted =~ String.duplicate("b", 500)
      refute fitted =~ String.duplicate("a", 500)
      assert fitted =~ "head aaa"
    end

    test "with every part cut and still over, the prompt itself is cut short", %{card: card} do
      render = fn _cuts -> String.duplicate("fixed ", 100) end
      fitted = Verified.fit_prompt(card, [:a], render, 150)

      assert byte_size(fitted) <= 150
      assert String.ends_with?(fitted, "`slipdock card 7`)")
    end
  end

  describe "cut/3" do
    test "nothing to remove leaves the text as it is" do
      card = %Card{id: 1}
      assert Verified.cut("text", nil, card) == "text"
      assert Verified.cut("text", 0, card) == "text"
      long = String.duplicate("y", 500)
      assert Verified.cut(long, 0, card) == long
      assert Verified.cut(long, -5, card) == long
      assert Verified.cut(nil, 10, card) == nil
    end

    test "keeps every byte that fits: exactly `remove` bytes come off" do
      card = %Card{id: 1}
      pointer = "\n… (#{@cut}, `slipdock card 1`)"
      cut = Verified.cut(String.duplicate("x", 500), 100, card)

      assert byte_size(cut) == 500 - 100
      assert cut == String.duplicate("x", 500 - 100 - byte_size(pointer)) <> pointer
    end

    test "never splits a character, and a part cut whole is only the pointer" do
      card = %Card{id: 1}
      cut = Verified.cut(String.duplicate("é", 200), 101, card)

      assert String.valid?(cut)
      assert byte_size(cut) <= 400 - 101
      assert String.starts_with?(cut, "é")

      long = String.duplicate("x", 120)
      assert Verified.cut(long, 500, card) == "… (#{@cut}, `slipdock card 1`)"
      # Never longer than it was: a part shorter than the pointer stays.
      assert Verified.cut("short", 500, card) == "short"
    end
  end
end
