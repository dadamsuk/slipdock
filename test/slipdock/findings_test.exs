defmodule Slipdock.FindingsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Findings, Repo}
  alias Slipdock.Findings.{Block, Finding}

  setup do
    owner = user_fixture()
    board = Boards.get_board!(board_fixture(%{"name" => "Findings"}, owner: owner).id)
    [_backlog, doing | _] = board.columns
    card = card_fixture(doing, %{"title" => "Taught us"})
    %{owner: owner, board: board, card: card, doing: doing}
  end

  defp findings(card),
    do: Repo.all(from(f in Finding, where: f.card_id == ^card.id, order_by: f.id))

  @wrap_up """
  **Done.**

  - Tests: 12 passed
  - Handbook: no change (a test-only fix)
  - Findings:
    - gotcha: `mix format` can need two passes
    - rule: every new MCP tool gets a docs_test regex
    - handbook-wrong: W-1950 §Tests says async is safe, but the fixture is one user
    - tooling: the installed CLI ignores --paths
    - process: merges wait for an idle runner
    - this one has no kind at all
  - Follow-ups: none
  """

  describe "Block.parse/1" do
    test "reads each kind, and keeps an unknown line whole as a gotcha" do
      assert [
               %{kind: "gotcha", text: "`mix format` can need two passes"},
               %{kind: "rule", text: "every new MCP tool gets a docs_test regex"},
               %{kind: "handbook-wrong", text: "W-1950 §Tests says async" <> _},
               %{kind: "tooling", text: "the installed CLI ignores --paths"},
               %{kind: "process", text: "merges wait for an idle runner"},
               %{kind: "gotcha", text: "this one has no kind at all"}
             ] = Block.parse(@wrap_up)
    end

    test "none, an empty block and no block at all" do
      assert Block.parse("- Handbook: no change\n- Findings: none") == []
      assert Block.parse("**Findings:** None (a typo fix)") == []
      assert Block.parse("Findings:\n- none\n") == []
      assert Block.parse("Findings:\n\nthe end") == []
      assert Block.parse("no block here, just findings in passing") == nil
      assert Block.parse(nil) == nil
    end

    test "a bare heading takes the list after it; a bold one too, and kind aliases" do
      text = """
      **Findings:**

      - **Rule candidate:** keep the guide under its cap
      - Tool: pwsh lives in a local folder

      Something else entirely.
      """

      assert Block.parse(text) == [
               %{kind: "rule", text: "keep the guide under its cap", scope: "board"},
               %{kind: "tooling", text: "pwsh lives in a local folder", scope: "board"}
             ]
    end

    test "an inline item, a continued line, and the list ends at the next outer item" do
      assert Block.parse("- Findings: gotcha: inline one\n- Follow-ups: card #9") ==
               [%{kind: "gotcha", text: "inline one", scope: "board"}]

      text = "- Findings:\n  - gotcha: wraps\n    onto a second line\n- Commit: abc"

      assert Block.parse(text) == [
               %{kind: "gotcha", text: "wraps onto a second line", scope: "board"}
             ]
    end

    test "a malformed item with a colon but no known kind stays whole" do
      assert Block.parse("Findings:\n- Note: the size cap is close") ==
               [%{kind: "gotcha", text: "Note: the size cap is close", scope: "board"}]
    end

    test "a block that only points elsewhere is none (#1975)" do
      for said <- [
            "in the evidence",
            "In the evidence.",
            "in the subcards' evidence (#1958, #1960)",
            "in the evidence (installed CLI gaps, pg_restore version)",
            "resolves #75 and #77.",
            "recorded on #1819 and #1820.",
            "see card #12 and finding #40",
            "see W-1950 §Tests",
            "`in the closing comment`"
          ] do
        assert Block.parse("- Handbook: no change\n- Findings: #{said}") == [], said
        assert Block.parse("Findings:\n- #{said}") == [], said
      end

      assert Block.parse("Findings:\n- gotcha: in the evidence\n- see #4") == []
    end

    test "a pointer beside real items is dropped and the rest kept" do
      text =
        "Findings:\n- in the evidence\n- gotcha: `mix format` can need two passes\n- resolves #75"

      assert Block.parse(text) == [
               %{kind: "gotcha", text: "`mix format` can need two passes", scope: "board"}
             ]
    end

    test "an item that says something beside an id is not a pointer" do
      for said <- [
            "`quality_api_test.exs:82` fails locally on main (#1928)",
            "in the evidence the CLI crashed on --paths",
            "resolves #75 by retrying the merge",
            "the ones in comment #4887 stand, plus a new one",
            "evidence posted twice on #1958"
          ] do
        refute Block.pointer?(said), said
        assert [%{text: ^said}] = Block.parse("Findings:\n- #{said}")
      end
    end
  end

  describe "from a comment" do
    test "a closing comment's block becomes findings of the right kinds", %{
      card: card,
      board: board,
      owner: owner
    } do
      {:ok, comment} = Boards.add_comment(card, @wrap_up, by: owner)
      found = findings(card)

      assert Enum.map(found, & &1.kind) ==
               ~w(gotcha rule handbook-wrong tooling process gotcha)

      assert Enum.all?(found, &(&1.source == "agent" and &1.status == "open"))
      assert Enum.all?(found, &(&1.comment_id == comment.id and &1.board_id == board.id))
      assert hd(found).user_id == owner.id
      assert hd(found).by == Slipdock.Accounts.User.display_name(owner)
      assert Findings.open_count(card) == 6
    end

    test "none makes none; a comment without a block makes none", %{card: card} do
      {:ok, _} = Boards.add_comment(card, "- Handbook: no change\n- Findings: none")
      {:ok, _} = Boards.add_comment(card, "Picked up.")
      assert findings(card) == []
    end

    test "a pointer-only block makes none, on this card or counted on another (#1975)", %{
      card: card,
      doing: doing
    } do
      other = card_fixture(doing, %{"title" => "Also pointed"})
      {:ok, _} = Boards.add_comment(card, "- Handbook: no change\n- Findings: in the evidence")
      {:ok, _} = Boards.add_comment(other, "- Findings: in the evidence")
      {:ok, _} = Boards.add_comment(other, "Findings:\n- in the subcards' evidence (#1958)")

      assert findings(card) == []
      assert findings(other) == []

      {:ok, _} = Boards.add_comment(card, "Evidence\n- Findings:\n  - gotcha: the real one")
      assert [%Finding{text: "the real one", count: 1}] = findings(card)
    end

    test "a subcard's findings are kept on the root board", %{card: card, board: board} do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(card, t)
      [first | _] = Boards.get_board!(sub.id).columns
      child = card_fixture(first, %{"title" => "Child"})

      {:ok, _} = Boards.add_comment(child, "Findings:\n- gotcha: deep down")
      assert [%Finding{board_id: root}] = findings(child)
      assert root == board.id
    end

    test "parsing again after an edit replaces its open findings, and is idempotent", %{
      card: card
    } do
      {:ok, comment} = Boards.add_comment(card, "Findings:\n- gotcha: one\n- rule: two")
      assert length(findings(card)) == 2

      {:ok, _} = Findings.from_comment(comment)
      assert length(findings(card)) == 2

      edited = %{comment | body: "Findings:\n- tooling: three"}
      {:ok, _} = Findings.from_comment(edited)
      assert [%{kind: "tooling", text: "three"}] = findings(card)

      {:ok, _} = Findings.from_comment(%{comment | body: "no block any more"})
      assert findings(card) == []
    end

    test "an edit keeps a triaged finding and doesn't make it twice", %{card: card} do
      {:ok, comment} = Boards.add_comment(card, "Findings:\n- gotcha: one")
      [f] = findings(card)
      {:ok, _} = Findings.triage(f, "dismiss")

      {:ok, _} = Findings.from_comment(comment)
      assert [%{status: "dismissed"}] = findings(card)
    end

    test "the same item in the evidence and the wrap-up is kept once", %{card: card} do
      {:ok, _} = Boards.add_comment(card, "Findings:\n- gotcha: once")
      {:ok, _} = Boards.add_comment(card, "**Done.**\n- Findings:\n  - gotcha: once")
      assert [_] = findings(card)
    end

    test "deleting the comment drops its open findings, keeps triaged ones", %{card: card} do
      {:ok, comment} = Boards.add_comment(card, "Findings:\n- gotcha: one\n- rule: two")
      [one, _two] = findings(card)
      {:ok, _} = Findings.triage(one, "promote", %{"note" => "W-1950 §Tests TEST-9"})

      {:ok, _} = Boards.delete_comment(comment)
      assert [%{text: "one", status: "promoted", comment_id: nil}] = findings(card)
    end

    test "a comment on a page makes none", %{board: board} do
      {:ok, page} = Slipdock.Wiki.create_page(board, %{"title" => "Notes", "body" => "x"})
      assert {:ok, _} = Boards.add_comment(page, "Findings:\n- gotcha: on a page")
      assert Repo.aggregate(Finding, :count) == 0
    end
  end

  describe "record/1" do
    test "a system finding, then a repeat on the same card and cause counts", %{card: card} do
      attrs = %{card: card, source: "timeout", cause: "job timeout", text: "job #1 timed out"}
      {:ok, f} = Findings.record(attrs)
      assert f.kind == "process" and f.count == 1 and f.by == "Slipdock"

      {:ok, again} = Findings.record(%{attrs | text: "job #2 timed out"})
      assert again.id == f.id and again.count == 2 and again.text == "job #2 timed out"

      {:ok, other} = Findings.record(%{attrs | cause: "job failed"})
      assert other.id != f.id
    end

    test "an unknown source is refused", %{card: card} do
      assert {:error, %Ecto.Changeset{}} =
               Findings.record(%{card: card, source: "gossip", text: "x"})
    end
  end

  describe "list/2" do
    setup %{card: card} do
      {:ok, _} = Boards.add_comment(card, "Findings:\n- gotcha: one\n- rule: two")
      :ok
    end

    test "open by default, filtered by kind, status and since", %{board: board, card: card} do
      {:ok, all} = Findings.list(board)
      assert length(all) == 2
      assert {:ok, [%{kind: "rule"}]} = Findings.list(board, %{"kind" => "rule"})

      [f | _] = findings(card)
      {:ok, _} = Findings.triage(f, "dismiss")
      assert {:ok, [_]} = Findings.list(board)
      assert {:ok, [%{status: "dismissed"}]} = Findings.list(board, %{"status" => "dismissed"})
      assert {:ok, [_, _]} = Findings.list(board, %{"status" => "all"})

      assert {:ok, [_]} = Findings.list(board, %{"since" => "1"})
      assert {:ok, []} = Findings.list(board, %{"since" => "2999-01-01"})
      assert {:error, "since is" <> _} = Findings.list(board, %{"since" => "last week"})
    end

    test "another board's findings aren't listed", %{owner: owner} do
      other = Boards.get_board!(board_fixture(%{"name" => "Other"}, owner: owner).id)
      assert {:ok, []} = Findings.list(other)
    end
  end

  describe "triage/3" do
    setup %{card: card} do
      {:ok, _} = Boards.add_comment(card, "Findings:\n- gotcha: one\n- gotcha: same thing")
      [a, b] = findings(card)
      %{a: a, b: b}
    end

    test "promote and dismiss keep a note; reopen opens", %{a: a} do
      {:ok, a} = Findings.triage(a, "promote", %{"note" => "W-1950 §Tests"})
      assert a.status == "promoted" and a.note == "W-1950 §Tests"
      {:ok, a} = Findings.triage(a, "reopen")
      assert a.status == "open"
      assert {:error, "unknown change" <> _} = Findings.triage(a, "shred")
    end

    test "merge moves the count onto the other, and reopening takes it back", %{a: a, b: b} do
      {:ok, merged} = Findings.triage(b, "merge", %{"into" => to_string(a.id)})
      assert merged.status == "merged" and merged.merged_into_id == a.id
      assert Repo.get!(Finding, a.id).count == 2

      assert {:error, "it was merged" <> _} = Findings.triage(merged, "dismiss")

      assert {:error, "it is already merged" <> _} =
               Findings.triage(merged, "merge", %{"into" => a.id})

      assert {:error, "that one is merged itself" <> _} =
               Findings.triage(a, "merge", %{"into" => b.id})

      {:ok, reopened} = Findings.triage(merged, "reopen")
      assert reopened.status == "open" and is_nil(reopened.merged_into_id)
      assert Repo.get!(Finding, a.id).count == 1
    end

    test "merge needs another finding of the same tree", %{a: a, owner: owner} do
      assert {:error, "say which" <> _} = Findings.triage(a, "merge", %{})

      assert {:error, "a finding can't merge into itself"} =
               Findings.triage(a, "merge", %{"into" => a.id})

      assert {:error, "no finding" <> _} = Findings.triage(a, "merge", %{"into" => "999999999"})
      assert {:error, "no finding" <> _} = Findings.triage(a, "merge", %{"into" => "abc"})

      other = Boards.get_board!(board_fixture(%{"name" => "Elsewhere"}, owner: owner).id)
      [_, doing | _] = other.columns
      {:ok, _} = Boards.add_comment(card_fixture(doing), "Findings:\n- gotcha: far")
      far = Repo.one!(from(f in Finding, where: f.board_id == ^other.id))

      assert {:error, "that finding is on another board tree"} =
               Findings.triage(a, "merge", %{"into" => far.id})
    end
  end
end
