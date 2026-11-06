defmodule Slipdock.HandbookTest do
  @moduledoc """
  The built-in Handbook Tool (#1262, W-1934): installing it gives a board's
  root a `Handbook/` folder of skeleton pages with front matter and an Index
  that lists the folder by itself.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Handbook, Repo, Wiki}
  alias Slipdock.Wiki.{Folders, Page}
  alias SlipdockWeb.Wiki.Renderer

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Project"}, owner: user)
    %{user: user, board: board}
  end

  defp handbook_pages(board) do
    {:ok, folder} = Folders.find(board, "/Handbook")
    Repo.all(from(p in Page, where: p.folder_id == ^folder.id, order_by: p.id))
  end

  describe "install/3" do
    test "builds the folders and the pages, each with its front matter", %{
      user: user,
      board: board
    } do
      assert Handbook.find(board) == nil
      assert {:ok, result} = Handbook.install(user, board)
      assert result.created
      assert result.board.id == board.id

      assert {:ok, _} = Folders.find(board, "/Handbook")
      assert {:ok, _} = Folders.find(board, "/Handbook/Decisions")

      pages = handbook_pages(board)

      assert Enum.map(pages, & &1.title) == [
               "Index",
               "Specification",
               "Architecture",
               "UX & UI",
               "Components",
               "Data model",
               "Shared modules",
               "Testing & tooling",
               "Operations"
             ]

      ux = Enum.find(pages, &(&1.title == "UX & UI"))
      assert Handbook.key(ux) == "ux"
      assert Handbook.field(ux, "read_when") =~ "screen"
      assert Handbook.field(ux, "covers") == []
      assert ux.summary =~ "interface"
      assert ux.front_matter =~ ~r/\A---\n/

      found = Handbook.find(board)
      assert found.index.title == "Index"
      assert hd(found.pages).title == "Index"
      assert length(found.pages) == 9
    end

    test "installing again duplicates nothing and leaves edited pages alone",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      arch = Enum.find(handbook_pages(board), &(&1.title == "Architecture"))
      {:ok, _} = Wiki.update_page(arch, %{"body" => "# Architecture\n\nOurs now."})

      assert {:ok, again} = Handbook.install(user, board)
      refute again.created
      # The edited page keeps its text and gets back only the Rules it lost (#1773).
      assert again.report.added["pages"] == ["Architecture (Rules section added)"]
      assert length(handbook_pages(board)) == 9
      body = Repo.get!(Page, arch.id).body
      assert body =~ "Ours now."
      assert body =~ "## Rules"

      assert {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
    end

    test "a sub-board's install goes on the root board, and a subcard finds it",
         %{user: user, board: board} do
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)

      assert {:ok, result} = Handbook.install(user, sub)
      assert result.board.id == board.id
      assert Handbook.find(sub).board.id == board.id
    end

    test "refuses somebody who can't write to the board", %{board: board} do
      stranger = user_fixture("handbook-stranger@example.com")
      assert {:error, message} = Handbook.install(stranger, board)
      assert message =~ "write access"
      assert Handbook.find(board) == nil
    end
  end

  describe "the Seed and Reconcile cards (#1263)" do
    test "install makes both, the reconcile nightly and waiting on the seed",
         %{user: user, board: board} do
      {:ok, result} = Handbook.install(user, board)

      assert result.report.added["cards"] == [
               "Seed the handbook",
               "Reconcile the handbook",
               "Triage findings"
             ]

      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")

      rec =
        Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Reconcile the handbook")

      assert seed.description =~ "CLAUDE.md"
      assert seed.description =~ "covers:"
      assert seed.description =~ "Handbook/Decisions"
      # Lessons from seeding this project's own handbook (#1268).
      assert seed.description =~ "keep `covers:` narrow"
      assert seed.description =~ "slipdock page props <page> --file F"
      assert rec.description =~ "git log"
      assert rec.description =~ "## Log"

      ready = Slipdock.Flow.ready_list(Boards.get_board!(board.id).columns)
      assert seed.column_id == ready.id

      series = Slipdock.Recurrence.for_card(rec)
      assert series
      assert series.rule == "FREQ=DAILY"
      # The nightly procedure (#1787): a small range, only the pages it touches.
      assert rec.description =~ "at most 20 of those commits"
      assert rec.description =~ "--paths-from -"
      assert rec.description =~ "Handbook: no change (nothing landed)"
      assert rec.description =~ "tomorrow"

      assert Enum.map(Boards.get_card!(rec.id).blocked_by, & &1.id) == [seed.id]
    end

    test "installing again (even after the seed is done) makes no second pair",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")
      {:ok, _} = Boards.update_card(seed, %{"completed" => true})

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["cards"] == []

      assert Repo.aggregate(
               from(c in Slipdock.Boards.Card,
                 where: c.board_id == ^board.id and like(c.title, "%the handbook")
               ),
               :count
             ) == 2
    end
  end

  describe "the Index" do
    test "lists the folder's pages, including one added later", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      %{index: index, folder: folder} = Handbook.find(board)

      md = Renderer.to_markdown(index.body, board: board, as: user, page: index)
      assert md =~ "| Title | Summary | Read when |"

      assert md =~
               "Architecture (#{Repo.get_by!(Page, board_id: board.id, title: "Architecture").code})"

      assert md =~ "building or changing a screen"
      refute md =~ "| Index"
      assert md =~ "No decisions written yet."

      {:ok, _} =
        Wiki.create_page(board, %{
          "title" => "Glossary",
          "folder_id" => folder.id,
          "summary" => "Words we use",
          "front_matter" => "---\nread_when: naming things\n---\n\n"
        })

      md = Renderer.to_markdown(index.body, board: board, as: user, page: index)
      assert md =~ "Glossary"
      assert md =~ "naming things"

      html = Renderer.to_html(index.body, board: board, as: user, page: index)
      assert html =~ ~s|href="/boards/#{board.id}/wiki/|
      assert html =~ "Glossary"
    end
  end

  describe "the pages: query" do
    test "names a folder that is missing, and refuses an empty one", %{user: user, board: board} do
      md = Renderer.to_markdown("```slipdock\npages: Nowhere\n```", board: board, as: user)
      assert md =~ "no folder \"Nowhere\""

      assert {:error, message} = Slipdock.Wiki.Query.parse("pages: /")
      assert message =~ "pages names a folder"
    end

    test "an empty folder says so, or says what `empty:` asks", %{user: user, board: board} do
      {:ok, _} = Folders.create(board, %{"name" => "Empty"})

      assert Renderer.to_markdown("```slipdock\npages: Empty\n```", board: board, as: user) =~
               "No pages in this folder yet."

      assert Renderer.to_markdown("```slipdock\npages: Empty\nempty: \"none\"\n```",
               board: board,
               as: user
             ) =~ "none"
    end
  end

  describe "for_card/3 (#1264)" do
    setup %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      {:ok, t} = Boards.find_template(nil, "Simple")
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, sub} = sub_board(epic, t)
      [sub_col | _] = Boards.get_board!(sub.id).columns
      story = card_fixture(sub_col, %{"title" => "Story"})
      {:ok, subsub} = sub_board(story, t)
      [deep_col | _] = Boards.get_board!(subsub.id).columns
      %{deep_col: deep_col, col: col}
    end

    test "a subcard two sub-boards down gets the root's index and the UI sections",
         %{user: user, board: board, deep_col: deep_col} do
      card =
        card_fixture(deep_col, %{
          "title" => "UI: a reusable dropdown menu component for the card form"
        })

      reading = Handbook.for_card(card, user)
      assert reading.board == Boards.get_board!(board.id).code
      assert reading.index_page == Handbook.find(board).index.code
      assert "UX & UI" in Enum.map(reading.index, & &1.title)
      refute "Index" in Enum.map(reading.index, & &1.title)
      assert reading.more == 0

      titles = Enum.map(reading.suggested, & &1.title)
      assert length(reading.suggested) <= 5
      assert Enum.take(Enum.uniq(titles), 2) |> Enum.sort() == ["Components", "UX & UI"]
      assert Enum.find(reading.suggested, &(&1.title == "UX & UI")).section =~ "UX & UI/"
    end

    test "a board without a handbook gives nil", %{user: user} do
      other = board_fixture(%{}, owner: user)
      [col | _] = other.columns
      assert Handbook.for_card(card_fixture(col, %{"title" => "UI menu"}), user) == nil
    end

    test "a page whose covers glob matches a path the card names comes first",
         %{user: user, board: board, col: col} do
      arch = Repo.get_by!(Page, board_id: board.id, title: "Architecture")

      {:ok, _} =
        Wiki.update_page(arch, %{
          "front_matter" =>
            "---\nhandbook: architecture\nread_when: x\ncovers: [lib/app/**, priv/repo/migrations/**]\n---\n\n"
        })

      card =
        card_fixture(col, %{
          "title" => "Fix the menu",
          "description" => "The bug is in `lib/app/accounts/user.ex`."
        })

      [first | _] = Handbook.for_card(card, user).suggested
      assert first.title == "Architecture"
      assert first.section == nil
      assert first.why == "covers lib/app/accounts/user.ex"
    end

    test "the index stays under its cap however many pages the folder holds",
         %{user: user, board: board, col: col} do
      %{folder: folder} = Handbook.find(board)

      for i <- 1..40 do
        {:ok, _} =
          Wiki.create_page(board, %{
            "title" => "Extra #{i}",
            "folder_id" => folder.id,
            "summary" => String.duplicate("long summary ", 20),
            "front_matter" => "---\nread_when: #{String.duplicate("often ", 30)}\n---\n\n"
          })
      end

      reading = Handbook.for_card(card_fixture(col, %{"title" => "Anything"}), user)
      assert byte_size(Jason.encode!(reading.index)) <= Handbook.index_cap()
      assert reading.more > 0
      assert Enum.all?(reading.index, &(String.length(&1.summary || "") <= 80))
    end

    test "the eight sections always fit, however long their fields (#1283)",
         %{user: user, board: board, col: col} do
      for page <- tl(Handbook.find(board).pages) do
        {:ok, _} =
          Wiki.update_page(page, %{
            "summary" => String.duplicate("a long summary ", 10),
            "front_matter" =>
              "---\nhandbook: x\nread_when: #{String.duplicate("when changing things ", 10)}\n---\n\n"
          })
      end

      reading = Handbook.for_card(card_fixture(col, %{"title" => "Anything"}), user)
      assert length(reading.index) == 8
      assert reading.more == 0
    end

    test "a reader who can't read the root board gets nothing", %{board: board, col: col} do
      stranger = user_fixture("handbook-reader@example.com")
      card = card_fixture(col, %{"title" => "UI menu"})
      assert Handbook.for_card(card, stranger) == nil
      assert Handbook.for_board(board, stranger) == nil
    end

    test "for_board lists the index and the decisions", %{user: user, board: board} do
      {:ok, dec} = Folders.find(board, "/Handbook/Decisions")

      {:ok, _} =
        Wiki.create_page(board, %{"title" => "Decision: soft gate", "folder_id" => dec.id})

      reading = Handbook.for_board(board, user)
      assert length(reading.index) == 8
      assert Enum.map(reading.decisions, & &1.title) == ["Decision: soft gate"]
    end
  end

  describe "the Triage findings card (#1789)" do
    defp card_titled(board, title),
      do: Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: title)

    test "install makes it nightly, with the procedure, waiting on the seed", %{
      user: user,
      board: board
    } do
      {:ok, _} = Handbook.install(user, board)
      triage = card_titled(board, "Triage findings")
      seed = card_titled(board, "Seed the handbook")

      assert Slipdock.Recurrence.for_card(triage).rule == "FREQ=DAILY"
      assert triage.description =~ "slipdock findings <board> --status open"
      assert triage.description =~ "Handbook: no change (no open findings)"
      assert triage.description =~ "merge --into"
      assert triage.description =~ "dismiss --note"
      assert triage.description =~ "slipdock garden propose <board> <file.json>"
      assert triage.description =~ "a card for the test instead"
      assert triage.description =~ "`slipdock quality <board> --rules`"
      assert triage.description =~ "## Triage"
      assert Enum.map(Boards.get_card!(triage.id).blocked_by, & &1.id) == [seed.id]

      index = Handbook.find(board).index
      assert {:ok, log} = Wiki.Section.read(index.body, "Handbook/Triage")
      assert log =~ "proposals filed"
    end

    # As 1.2.0 left a handbook: no triage card, no Triage log, a seed done.
    defp as_1_2_0(user, board) do
      {:ok, _} = Handbook.install(user, board)

      {:ok, _} =
        Boards.update_card(card_titled(board, "Seed the handbook"), %{"completed" => true})

      Repo.delete!(card_titled(board, "Triage findings"))
      index = Handbook.find(board).index
      [before, _triage] = String.split(index.body, "## Triage")
      {:ok, _} = Wiki.update_page(index, %{"body" => String.trim_trailing(before) <> "\n"})
      Handbook.find(board).index.body
    end

    test "installing over 1.2.0 adds the card and the log, and touches nothing else", %{
      user: user,
      board: board
    } do
      index_before = as_1_2_0(user, board)
      reconcile = card_titled(board, "Reconcile the handbook")
      pages_before = Map.new(handbook_pages(board), &{&1.id, &1.body})

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["cards"] == ["Triage findings"]
      assert "Index (Triage log added)" in again.report.added["pages"]

      triage = card_titled(board, "Triage findings")
      assert Slipdock.Recurrence.for_card(triage).rule == "FREQ=DAILY"
      # The seed is done: nothing to wait for.
      assert Boards.get_card!(triage.id).blocked_by == []

      index = Handbook.find(board).index
      assert String.starts_with?(index.body, String.trim_trailing(index_before))
      assert index.body =~ ~r/## Triage\n\n_The triage card records/

      for page <- handbook_pages(board),
          page.id != index.id,
          do: assert(page.body == pages_before[page.id], page.title)

      assert Repo.reload!(reconcile).updated_at == reconcile.updated_at

      # Again: nothing more.
      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["cards"] == []
      refute "Index (Triage log added)" in third.report.added["pages"]
      assert length(Regex.scan(~r/^## Triage$/m, Handbook.find(board).index.body)) == 1
    end

    test "a seed still open makes the added triage wait for it", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      Repo.delete!(card_titled(board, "Triage findings"))

      {:ok, _} = Handbook.install(user, board)
      triage = card_titled(board, "Triage findings")
      seed = card_titled(board, "Seed the handbook")
      assert Enum.map(Boards.get_card!(triage.id).blocked_by, & &1.id) == [seed.id]
    end
  end

  describe "upgrading the reconcile to nightly (#1787)" do
    # As a handbook before 1.2.0 left it: a weekly series with the old text.
    defp weekly_reconcile(user, board) do
      {:ok, _} = Handbook.install(user, board)

      rec =
        Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Reconcile the handbook")

      {:ok, rec} =
        Boards.update_card(rec, %{
          "description" => "Weekly: `git log --stat <last>..HEAD`.",
          "priority" => "high",
          "due_date" => ~D[2026-11-02]
        })

      {:ok, _} = Slipdock.Recurrence.set(rec, %{"rule" => "every mon", "at" => "06:30"}, user)
      Repo.reload!(rec)
    end

    test "installing over it gives the card the nightly procedure and repeat, nothing else",
         %{user: user, board: board} do
      rec = weekly_reconcile(user, board)
      before = Slipdock.Recurrence.for_card(rec)
      assert before.rule =~ "WEEKLY"

      {:ok, again} = Handbook.install(user, board)
      assert again.upgraded
      assert "Reconcile the handbook (updated: nightly)" in again.report.added["cards"]

      after_rec = Repo.reload!(rec)
      assert after_rec.description =~ "at most 20 of those commits"
      assert after_rec.title == rec.title
      assert after_rec.priority == "high"
      assert after_rec.column_id == rec.column_id
      assert after_rec.due_date == rec.due_date

      series = Slipdock.Recurrence.for_card(after_rec)
      assert series.id == before.id
      assert series.rule == "FREQ=DAILY"
      assert series.create_at == before.create_at
      assert series.timezone == before.timezone

      # Once current, installing again leaves it be.
      {:ok, third} = Handbook.install(user, board)
      refute third.upgraded
      refute Enum.any?(third.report.added["cards"], &(&1 =~ "updated"))
    end

    test "the series' current card is the one changed, not an older copy",
         %{user: user, board: board} do
      rec = weekly_reconcile(user, board)
      {:ok, old} = Boards.copy_card(rec)
      # The copy is newer by id but not the series' instance.
      assert old.id > rec.id
      {:ok, old} = Boards.update_card(old, %{"description" => "an old week"})

      {:ok, _} = Handbook.install(user, board)
      assert Repo.reload!(rec).description =~ "at most 20 of those commits"
      assert Repo.reload!(old).description == "an old week"
    end

    test "a stopped series keeps stopped: only the description moves on",
         %{user: user, board: board} do
      rec = weekly_reconcile(user, board)
      {:ok, _} = Slipdock.Recurrence.stop(rec)

      {:ok, again} = Handbook.install(user, board)
      assert again.upgraded
      assert Repo.reload!(rec).description =~ "at most 20 of those commits"
      assert Slipdock.Recurrence.for_card(rec) == nil
    end

    test "a series already daily only gets its description", %{user: user, board: board} do
      rec = weekly_reconcile(user, board)
      {:ok, _} = Slipdock.Recurrence.set(rec, %{"rule" => "day"}, user)
      next_on = Slipdock.Recurrence.for_card(rec).next_on

      {:ok, again} = Handbook.install(user, board)
      assert again.upgraded
      assert Slipdock.Recurrence.for_card(rec).next_on == next_on
    end

    test "with no reconcile card at all there is nothing to upgrade",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)

      rec =
        Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Reconcile the handbook")

      {:ok, _} = Boards.update_card(rec, %{"title" => "Renamed by a person"})

      {:ok, again} = Handbook.install(user, board)
      refute again.upgraded
      # A card of that title is made again, as any missing blueprint card is.
      assert again.report.added["cards"] == ["Reconcile the handbook"]
    end
  end

  describe "rules (#1773)" do
    test "a new handbook's section pages each start with an empty ## Rules",
         %{user: user, board: board} do
      {:ok, result} = Handbook.install(user, board)
      assert result.version.version == Handbook.version()
      [_index | sections] = handbook_pages(board)

      for page <- sections do
        assert {:ok, rules} = Wiki.Section.read(page.body, "#{page.title}/Rules"), page.title
        prefix = Handbook.Rules.prefix(Handbook.key(page))
        assert rules =~ "**#{prefix}-1** must", page.title
        assert Handbook.Rules.parse_page(page) == {[], []}, page.title
      end

      # UX & UI had a Rules section of its own in 1.0.0: only one now.
      ux = Enum.find(sections, &(&1.title == "UX & UI"))
      assert length(Regex.scan(~r/^## Rules$/m, ux.body)) == 1

      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")
      assert seed.description =~ "`## Rules` section"
      assert seed.description =~ "`judgement`"
      assert Handbook.find(board).index.body =~ "## Rules"
    end

    test "installing over a 1.0.0 handbook adds Rules only where it is missing",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      pages = handbook_pages(board)
      by_title = Map.new(pages, &{&1.title, &1})

      # As 1.0.0 left them: no Rules on most pages, UX & UI with its own.
      for page <- pages, page.title not in ["Index", "UX & UI"] do
        {:ok, _} =
          Wiki.update_page(page, %{"body" => "# #{page.title}\n\nWritten by us.\n"})
      end

      ux_body =
        "# UX & UI\n\n## Rules\n\n- **UX-1** must · test/a_test.exs · Tokens only.\n"

      {:ok, _} = Wiki.update_page(by_title["UX & UI"], %{"body" => ux_body})
      index_body = Repo.get!(Page, by_title["Index"].id).body

      {:ok, again} = Handbook.install(user, board)

      assert Enum.sort(again.report.added["pages"]) ==
               Enum.sort(
                 ["Testing & tooling (Before you push added)"] ++
                   for(
                     t <- Map.keys(by_title),
                     t not in ["Index", "UX & UI"],
                     do: t <> " (Rules section added)"
                   )
               )

      ops = Repo.get!(Page, by_title["Operations"].id)
      assert ops.body =~ ~r/\A# Operations\n\nWritten by us.\n\n## Rules\n/
      assert ops.body =~ "**OPS-1** must"
      assert Repo.get!(Page, by_title["UX & UI"].id).body == ux_body
      assert Repo.get!(Page, by_title["Index"].id).body == index_body

      assert [%{id: "UX-1"}] = Handbook.Rules.rules(Handbook.find(board))
    end

    test "for_board counts the rules and lists what didn't parse",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      assert Handbook.for_board(board, user).rules == %{count: 0, must: 0, problems: []}

      data = Enum.find(handbook_pages(board), &(&1.title == "Data model"))

      {:ok, _} =
        Wiki.update_page(data, %{
          "body" =>
            "# Data model\n\n## Rules\n\n- **DATA-1** must · judgement · Never cast.\n" <>
              "- **DATA-2** should · judgement · Prefer soft deletes.\n" <>
              "- **DATA-3** must · Appended to, never edited.\n"
        })

      assert %{count: 2, must: 1, problems: [problem]} = Handbook.for_board(board, user).rules
      assert problem.page == data.code
      assert problem.line == 7
      assert problem.problem =~ "no check"
    end
  end

  describe "Before you push (#1878)" do
    defp testing(board), do: Enum.find(handbook_pages(board), &(Handbook.key(&1) == "testing"))

    test "a new Testing & tooling page has the section, after CI, with its hint",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      page = testing(board)

      assert {:ok, section} =
               Wiki.Section.read(page.body, "Testing & tooling/Before you push")

      assert section =~ "The one command that runs locally what CI enforces on a pull request"
      assert section =~ "no local equivalent"
      assert section =~ "with why"

      titles = for h <- Wiki.Section.headings(page.body), h.level == 2, do: h.title
      assert titles == ["Tests", "CI", "Before you push", "Local setup", "Rules"]

      assert Handbook.before_you_push(board) ==
               %{page: page.code, path: "Testing & tooling/Before you push"}
    end

    test "before_you_push/1 is nil with no handbook, or no such section",
         %{user: user, board: board} do
      assert Handbook.before_you_push(board) == nil
      assert Handbook.before_you_push(nil) == nil

      {:ok, _} = Handbook.install(user, board)
      {:ok, _} = Wiki.update_page(testing(board), %{"body" => "# Testing & tooling\n\n## CI\n"})
      assert Handbook.before_you_push(board) == nil
    end

    test "the seed gathers every pull-request check into one command, proposed if missing",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      seed = card_titled(board, "Seed the handbook")

      assert seed.description =~
               "for every check CI runs on a pull request (each job and step the workflows run for one), write on Testing & tooling's `## Before you push` how to run it locally, and gather them into the one command that runs them all"

      assert seed.description =~
               "A check with no local equivalent (a Windows runner, a hosted service) is named there, with why."

      assert seed.description =~ "Where the repo has no such command, don't add one unasked"

      assert seed.description =~
               "propose the one command (an alias, a make target or a script, with the steps it would run) in the closing comment"

      assert seed.description =~ "Before you push names the one command"
      # The steps stay numbered in order.
      numbers = for [_, n] <- Regex.scan(~r/^(\d+)\. /m, seed.description), do: n
      assert numbers == Enum.map(1..8, &to_string/1)
    end

    test "the reconcile checks Before you push when the range touches CI config",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      rec = card_titled(board, "Reconcile the handbook")

      assert rec.description =~
               "A range that touches CI config (`.github/workflows/**`, `.gitlab-ci.yml`"

      assert rec.description =~
               "read Testing & tooling's `## Before you push` against the workflows as they now are, and fix the drift there"

      assert rec.description =~ "propose the change to the command in the closing comment"
      numbers = for [_, n] <- Regex.scan(~r/^(\d+)\. /m, rec.description), do: n
      assert numbers == Enum.map(1..9, &to_string/1)
    end

    test "installing over a 1.3.0 handbook adds it after CI, and the CI step to the reconcile",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      page = testing(board)

      old =
        "# Testing & tooling\n\n## CI\n\n- **test**: the suite.\n\n## Local setup\n\nOurs.\n\n## Rules\n\n- **TEST-1** must · judgement · Green.\n"

      {:ok, _} = Wiki.update_page(page, %{"body" => old})
      rec = card_titled(board, "Reconcile the handbook")
      {:ok, _} = Boards.update_card(rec, %{"description" => "The 1.3.0 procedure."})
      others = for p <- handbook_pages(board), p.id != page.id, into: %{}, do: {p.id, p.body}

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["pages"] == ["Testing & tooling (Before you push added)"]

      body = Repo.get!(Page, page.id).body

      assert body ==
               "# Testing & tooling\n\n## CI\n\n- **test**: the suite.\n\n" <>
                 Handbook.before_you_push_skeleton() <>
                 "\n## Local setup\n\nOurs.\n\n## Rules\n\n- **TEST-1** must · judgement · Green.\n"

      for p <- handbook_pages(board), p.id != page.id, do: assert(p.body == others[p.id], p.title)
      assert Repo.reload!(rec).description =~ "A range that touches CI config"

      # Again: nothing more.
      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
      assert Repo.get!(Page, page.id).body == body
    end

    test "a page with no CI section gets it at the end; one with the section is left alone",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      page = testing(board)
      {:ok, _} = Wiki.update_page(page, %{"body" => "# Testing & tooling\n\nWritten by us.\n"})

      {:ok, again} = Handbook.install(user, board)
      assert "Testing & tooling (Before you push added)" in again.report.added["pages"]
      body = Repo.get!(Page, page.id).body
      assert body =~ ~r/\A# Testing & tooling\n\nWritten by us.\n\n## Before you push\n/
      # Before the Rules this install also appended.
      assert body =~ ~r/## Before you push\n.*## Rules/s

      ours = "# Testing & tooling\n\n## Before you push\n\n`make check`.\n"
      {:ok, _} = Wiki.update_page(page, %{"body" => ours})
      {:ok, third} = Handbook.install(user, board)
      refute "Testing & tooling (Before you push added)" in third.report.added["pages"]
      assert Repo.get!(Page, page.id).body =~ ~r/\A#{Regex.escape(ours)}/
    end
  end

  describe "suggestions read as real sections (#1281)" do
    test "a chunk's part number and the page's lone top heading are not sections" do
      page = %Page{body: "# Operations\n\nIntro.\n\n## Deploy\n\nPush.\n"}
      assert Handbook.section_path("Operations/Deploy#2", page) == "Operations/Deploy"
      assert Handbook.section_path("Operations/Deploy", page) == "Operations/Deploy"
      assert Handbook.section_path("Operations#4", page) == nil
      assert Handbook.section_path("Operations", page) == nil
      assert Handbook.section_path("", page) == nil
      assert Handbook.section_path(nil, page) == nil

      flat = %Page{body: "## Deploy\n\nPush.\n"}
      assert Handbook.section_path("Deploy#1", flat) == "Deploy"
    end

    test "no page takes more than two of the five", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      ux = Repo.get_by!(Page, board_id: board.id, title: "UX & UI")

      body =
        "# UX & UI\n\n" <>
          Enum.map_join(1..6, "\n\n", &"## Dropdown menu #{&1}\n\nDropdown menu rules.")

      {:ok, _} = Wiki.update_page(ux, %{"body" => body})
      [col | _] = board.columns
      card = card_fixture(col, %{"title" => "Dropdown menu component on the card form"})

      suggested = Handbook.for_card(card, user).suggested
      assert Enum.count(suggested, &(&1.title == "UX & UI")) == 2
      assert length(suggested) > 2
    end
  end

  describe "glob_match?/2 and mentioned_paths/1" do
    test "** crosses folders, * doesn't, and a folder matches what is under it" do
      assert Handbook.glob_match?("lib/app/**", "lib/app/a/b.ex")
      assert Handbook.glob_match?("lib/*.ex", "lib/a.ex")
      refute Handbook.glob_match?("lib/*.ex", "lib/a/b.ex")
      assert Handbook.glob_match?("lib/app/**", "lib/app/")
      refute Handbook.glob_match?("lib/app/**", "test/app/x.exs")
      refute Handbook.glob_match?(nil, "lib/a.ex")
    end

    test "finds paths and files, not urls" do
      paths =
        Handbook.mentioned_paths(
          "See lib/app/x.ex and mix.exs, https://example.com/a/b, and assets/css/"
        )

      assert "lib/app/x.ex" in paths
      assert "mix.exs" in paths
      assert "assets/css/" in paths
      refute Enum.any?(paths, &String.contains?(&1, "example.com"))
    end
  end
end
