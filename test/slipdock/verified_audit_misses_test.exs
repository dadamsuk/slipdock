defmodule Slipdock.VerifiedAuditMissesTest do
  @moduledoc """
  The verify prompt's recent audit misses (#2695): on a tree with audits on,
  the verify prompt lists the last five audit disagreements of the last 30
  days (the rework card's title and the parts it failed), newest first, and
  tells the verifier to check those first. No block with audits off or
  nothing caught, and never in the audit prompt. A rework since accepted
  keeps its miss.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Findings, Repo, Verified}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.{Finding, Signals}

  @heading "What audits on this board caught recently"

  setup do
    owner = user_fixture("misses-owner@example.com")
    board = board_fixture(%{"name" => "Misses", "code" => unique_code()}, owner: owner)

    {:ok, board} =
      Boards.update_board(board, %{
        "verify_work" => true,
        "verify_pool" => "loop",
        "verify_audit" => 3
      })

    doing = Enum.find(board.columns, &(&1.category == "doing"))
    %{owner: owner, board: board, doing: doing}
  end

  # An accepted card on `column`, then an audit's disagreement with it.
  defp disagree(ctx, column, title, reason, checks) do
    card = card_fixture(column, %{"title" => title})

    {:ok, card} =
      card
      |> Ecto.Changeset.change(
        verify_state: "accepted",
        verify_by: %{"kind" => "agent", "agent" => "checker", "user_id" => ctx.owner.id}
      )
      |> Repo.update()

    {:ok, _} =
      Verified.decide(
        card,
        "disagree",
        %{"reason" => reason, "checks" => checks},
        Actor.web(ctx.owner),
        ctx.owner
      )

    card
  end

  defp finding(card),
    do: Repo.one!(from(f in Finding, where: f.card_id == ^card.id and f.source == "audit"))

  defp age!(card, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second) |> DateTime.truncate(:second)
    card |> finding() |> Ecto.Changeset.change(updated_at: at) |> Repo.update!()
  end

  defp prompt(ctx, column \\ nil) do
    card = card_fixture(column || ctx.doing, %{"title" => "Under review"})
    card = Repo.get!(Card, card.id)
    Verified.verify_prompt(card, Boards.get_board!(card.board_id))
  end

  describe "the verify prompt" do
    test "lists two disagreements, newest first, with titles and failed parts", ctx do
      older =
        disagree(ctx, ctx.doing, "Older", "the docs deferral misses the lane", [
          "bar:4=fail:HelpLive.Agents not updated",
          "ask=ok"
        ])

      age!(older, 2)

      newer =
        disagree(ctx, ctx.doing, "Newer", "a mutant on the new guard lives\nmore detail", [
          "mutant:survived=lib/a.ex:12:drop the guard:a test for the empty list"
        ])

      prompt = prompt(ctx)

      assert prompt =~ @heading
      assert prompt =~ "check these first on this card"

      newer_line =
        "- “Audit of ##{newer.id}: a mutant on the new guard lives” (##{newer.id}, " <>
          "#{Date.to_iso8601(Date.utc_today())}) — failed: mutant — lib/a.ex:12; drop the guard; " <>
          "a test for the empty list"

      older_line =
        "- “Audit of ##{older.id}: the docs deferral misses the lane” (##{older.id}, " <>
          "#{Date.to_iso8601(Date.add(Date.utc_today(), -2))}) — failed: bar 4 — " <>
          "HelpLive.Agents not updated"

      assert prompt =~ newer_line
      assert prompt =~ older_line
      # Newest first; a passing part (the ask) isn't listed.
      assert :binary.match(prompt, newer_line) < :binary.match(prompt, older_line)
      refute prompt =~ "the ask — "
      # Before the card's own checks, so they're read first.
      assert :binary.match(prompt, @heading) < :binary.match(prompt, "What the card asks")
    end

    test "keeps the last five of the last 30 days", ctx do
      cards =
        for i <- 1..7 do
          card = disagree(ctx, ctx.doing, "Card #{i}", "miss #{i}", ["bar:1=fail"])
          # Card 1 is oldest; card 7 is outside the window entirely.
          age!(card, if(i == 7, do: 31, else: 10 - i))
          card
        end

      misses = Verified.recent_audit_misses(Repo.get!(Card, hd(cards).id))

      assert Enum.map(misses, & &1.title) ==
               for(i <- 6..2//-1, do: "Audit of ##{Enum.at(cards, i - 1).id}: miss #{i}")

      prompt = prompt(ctx)
      refute prompt =~ "miss 1”"
      refute prompt =~ "miss 7”"
      assert prompt =~ "miss 6”"
    end

    test "one older than 30 days is left out, even with room for it", ctx do
      old = disagree(ctx, ctx.doing, "Long ago", "an old miss", ["bar:1=fail"])
      age!(old, 31)
      assert Verified.recent_audit_misses(old) == []
      refute prompt(ctx) =~ @heading

      age!(old, 29)
      assert [%{card_id: id}] = Verified.recent_audit_misses(old)
      assert id == old.id
    end

    test "a rework since accepted still appears", ctx do
      card = disagree(ctx, ctx.doing, "Done since", "bar 2 was skipped", ["bar:2=fail"])
      rework = Verified.open_rework(card)
      {:ok, _} = Boards.update_card(rework, %{"completed" => true})
      refute Verified.open_rework(card)

      assert prompt(ctx) =~ "“Audit of ##{card.id}: bar 2 was skipped”"
      assert prompt(ctx) =~ "failed: bar 2"
    end

    test "a sub-board's card reads its root's misses", ctx do
      card = disagree(ctx, ctx.doing, "Root work", "the bar dropped a part", ["ask=misses"])
      epic = card_fixture(ctx.doing, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      [column | _] = Boards.get_board!(sub.id).columns

      assert prompt(ctx, column) =~ "“Audit of ##{card.id}: the bar dropped a part”"
      assert prompt(ctx, column) =~ "failed: the ask"
    end

    test "no block with none caught, or with only other findings and other trees", ctx do
      refute prompt(ctx) =~ @heading

      other = board_fixture(%{"name" => "Other", "code" => unique_code()}, owner: ctx.owner)
      {:ok, other} = Boards.update_board(other, %{"verify_audit" => 1})
      other_doing = Enum.find(other.columns, &(&1.category == "doing"))
      disagree(ctx, other_doing, "Elsewhere", "another tree's miss", ["bar:1=fail"])

      here = card_fixture(ctx.doing, %{"title" => "Rejected once"})

      {:ok, _} =
        Findings.record(%{card: here, source: "rejection", cause: "rejected: bar 1", text: "x"})

      assert Verified.recent_audit_misses(here) == []
      refute prompt(ctx) =~ @heading
    end

    test "no block with audits off", ctx do
      disagree(ctx, ctx.doing, "Caught", "a miss", ["bar:1=fail"])
      assert prompt(ctx) =~ @heading

      {:ok, _} = Boards.update_board(ctx.board, %{"verify_audit" => 0})
      refute prompt(ctx) =~ @heading
    end

    test "never in the audit prompt", ctx do
      disagree(ctx, ctx.doing, "Caught", "a miss", ["bar:1=fail"])
      card = Repo.get!(Card, card_fixture(ctx.doing, %{"title" => "Audited"}).id)

      refute Verified.audit_prompt(card, ctx.board) =~ @heading
      refute Verified.audit_prompt(card, ctx.board) =~ "Audit of #"
    end

    test "each line is kept short", ctx do
      long_note = String.duplicate("n", 400)
      disagree(ctx, ctx.doing, "Long", "short reason", ["bar:1=fail:#{long_note}"])

      [line] =
        prompt(ctx) |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- “Audit"))

      assert String.length(line) <= 300
      assert String.ends_with?(line, "…")
    end
  end

  describe "an audit finding's parts" do
    test "the text keeps the failing parts and the rework; audit_failed reads them back", ctx do
      card =
        disagree(ctx, ctx.doing, "Parts", "two parts fail", [
          "bar:1=fail:no header\nrow",
          "bar:2=ok",
          "rule:UX-4=broken"
        ])

      f = finding(card)
      rework = Verified.open_rework(card)
      assert f.text =~ "two parts fail Rework: ##{rework.id}."

      assert Signals.audit_failed(f) == %{
               failed: "bar 1 — no header row; UX-4",
               rework_id: rework.id
             }
    end

    test "a disagreement with no failing parts keeps none", ctx do
      card = disagree(ctx, ctx.doing, "No parts", "just wrong", nil)
      f = finding(card)
      refute f.text =~ "Failed:"
      assert %{failed: nil} = Signals.audit_failed(f)
      [miss] = Verified.recent_audit_misses(card)
      # Its rework's description has no failed list either.
      assert miss.failed == nil
      refute prompt(ctx) =~ "— failed:"
    end

    test "an older finding's parts are read from its rework card", ctx do
      card = disagree(ctx, ctx.doing, "Old style", "bar 3 missed", ["bar:3=fail:gone"])
      f = finding(card)
      rework = Verified.open_rework(card)
      # As written before #2695: no parts line.
      f
      |> Ecto.Changeset.change(
        text: "An audit disagrees with the acceptance: bar 3 missed Rework: ##{rework.id}."
      )
      |> Repo.update!()

      [miss] = Verified.recent_audit_misses(card)
      assert miss.title == rework.title
      assert miss.failed == "bar 3"
    end

    test "with no rework card, the title is made from the reason", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Lone"})
      :ok = record_ok(Signals.audit_disagreed(card, "the bar dropped part 3\nmore", nil))

      assert [%{title: title, failed: nil}] = Verified.recent_audit_misses(card)
      assert title == "Audit of ##{card.id}: the bar dropped part 3"
    end
  end

  defp record_ok({:ok, %Finding{}}), do: :ok
end
