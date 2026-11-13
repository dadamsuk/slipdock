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
               "Operations",
               "Principles",
               "Playbook"
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
      assert length(found.pages) == 11
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
      assert length(handbook_pages(board)) == 11
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
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
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
      assert rec.description =~ "about 20 of those commits"
      assert rec.description =~ "--paths-from -"
      assert rec.description =~ "Handbook: no change (nothing landed)"
      assert rec.description =~ "tomorrow"

      assert Enum.map(Boards.Cards.get_card!(rec.id).blocked_by, & &1.id) == [seed.id]
    end

    test "installing again (even after the seed is done) makes no second pair",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")
      {:ok, _} = Boards.Cards.update_card(seed, %{"completed" => true})

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
      {:ok, t} = Boards.Templates.find_template(nil, "Simple")
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

    test "the ten sections always fit, however long their fields (#1283)",
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
      assert length(reading.index) == 10
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
      assert length(reading.index) == 10
      assert Enum.map(reading.decisions, & &1.title) == ["Decision: soft gate"]
    end
  end

  describe "pages_for/2 and pages_for_each/2 (#1977)" do
    setup %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      pages = Handbook.find(board).pages
      data = Enum.find(pages, &(&1.title == "Data model"))
      ux = Enum.find(pages, &(&1.title == "UX & UI"))

      {:ok, data} =
        Wiki.update_page(data, %{
          "front_matter" =>
            "---\nhandbook: data-model\ncovers: [priv/repo/**, lib/app/*.ex]\n---\n"
        })

      {:ok, ux} =
        Wiki.update_page(ux, %{
          "front_matter" => "---\nhandbook: ux\ncovers: [lib/app_web/**, lib/app/*.ex]\n---\n"
        })

      %{handbook: Handbook.find(board), data: data, ux: ux}
    end

    test "the pages covering most of the paths come first, each with its count", ctx do
      %{handbook: handbook, data: data, ux: ux} = ctx

      assert [%{code: d, title: "Data model", paths: 2}, %{code: u, title: "UX & UI", paths: 1}] =
               Handbook.pages_for(handbook, [
                 "priv/repo/migrations/1.exs",
                 "lib/app/user.ex",
                 " ",
                 "lib/app/user.ex"
               ])

      assert {d, u} == {data.code, ux.code}

      # A tie goes in the handbook's order; nothing covered is no page.
      assert [%{title: first}, %{title: second}] = Handbook.pages_for(handbook, ["lib/app/a.ex"])

      order = Enum.map(handbook.pages, & &1.title)

      assert Enum.find_index(order, &(&1 == first)) <
               Enum.find_index(order, &(&1 == second))

      assert Handbook.pages_for(handbook, ["somewhere/else.txt"]) == []
      assert Handbook.pages_for(handbook, []) == []
      assert Handbook.pages_for(handbook, nil) == []
      assert Handbook.pages_for(nil, ["lib/app/a.ex"]) == []
    end

    test "each list gets what pages_for/2 gives it, in order", %{handbook: handbook} do
      lists = [
        ["lib/app_web/live/x.ex"],
        [],
        ["priv/repo/a.exs", "lib/app_web/y.ex", "priv/repo/b.exs"],
        nil,
        ["lib/app_web/live/x.ex", "nowhere.md"]
      ]

      assert Handbook.pages_for_each(handbook, lists) ==
               Enum.map(lists, &Handbook.pages_for(handbook, &1))

      assert [[%{title: "UX & UI", paths: 1}], [], [%{title: "Data model", paths: 2} | _], [], _] =
               Handbook.pages_for_each(handbook, lists)

      assert Handbook.pages_for_each(handbook, []) == []
      assert Handbook.pages_for_each(nil, [["a"], []]) == [[], []]
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
      # A finding left open at the last triage is decided now (#2122), and counted.
      assert triage.description =~ "never left open a second time"
      assert triage.description =~ "<n> leftovers decided; <n> left open (<ids>: why)"
      # A literal `--desc -` from an old CLI is refused (#2686): it says the stdin form.
      assert triage.description =~ "`--desc -` with a heredoc for more than a line"
      # Fixes to Housekeeping, design questions to Triage (#2779).
      assert triage.description =~ "--column Housekeeping --origin findings"
      assert triage.description =~ "--column Triage --origin findings"
      assert triage.description =~ "or the backlog on a board with no Housekeeping list"

      assert triage.description =~
               "Only a finding that arrived since the last triage may stay open"

      assert Enum.map(Boards.Cards.get_card!(triage.id).blocked_by, & &1.id) == [seed.id]

      index = Handbook.find(board).index
      assert {:ok, log} = Wiki.Section.read(index.body, "Handbook/Triage")
      assert log =~ "proposals filed"
    end

    # As 1.2.0 left a handbook: no triage card, no Triage log, a seed done.
    defp as_1_2_0(user, board) do
      {:ok, _} = Handbook.install(user, board)

      {:ok, _} =
        Boards.Cards.update_card(card_titled(board, "Seed the handbook"), %{"completed" => true})

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
      assert Boards.Cards.get_card!(triage.id).blocked_by == []

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
      assert Enum.map(Boards.Cards.get_card!(triage.id).blocked_by, & &1.id) == [seed.id]
    end
  end

  describe "upgrading the triage card (#2779)" do
    test "installing over an older one gives it the current procedure, once",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      triage = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Triage findings")

      {:ok, _} =
        Boards.Cards.update_card(triage, %{"description" => "It becomes a card in Backlog."})

      {:ok, again} = Handbook.install(user, board)
      assert again.upgraded
      assert "Triage findings (updated: procedure)" in again.report.added["cards"]
      assert Repo.reload!(triage).description =~ "--column Housekeeping --origin findings"

      {:ok, third} = Handbook.install(user, board)
      refute "Triage findings (updated: procedure)" in third.report.added["cards"]
    end

    # 1.9.2 (#2767): a finding an open proposal names waits on the person,
    # so the procedure says triage leaves it.
    test "installing over 1.9.1 tells triage a finding waiting on a proposal isn't its",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      triage = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Triage findings")
      current = triage.description
      assert current =~ "it is waiting on the person deciding the proposal (`--status waiting`)"
      assert current =~ "A finding waiting on a proposal is none of these"

      as_1_9_1 =
        current
        |> String.replace(~r/ A finding an open proposal names is not in that list:[^\n]*/, "")
        |> String.replace(~r/ A finding waiting on a proposal is none of these[^\n]*/, "")

      refute as_1_9_1 =~ "waiting"
      {:ok, _} = Boards.Cards.update_card(triage, %{"description" => as_1_9_1})

      {:ok, again} = Handbook.install(user, board)
      assert "Triage findings (updated: procedure)" in again.report.added["cards"]
      assert Repo.reload!(triage).description == current
    end

    test "a done triage card is left alone", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      triage = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Triage findings")

      Repo.update_all(from(c in Slipdock.Boards.Card, where: c.id == ^triage.id),
        set: [description: "Old.", completed: true]
      )

      {:ok, again} = Handbook.install(user, board)
      refute "Triage findings (updated: procedure)" in again.report.added["cards"]
      assert Repo.reload!(triage).description == "Old."
    end
  end

  describe "upgrading the reconcile to nightly (#1787)" do
    # As a handbook before 1.2.0 left it: a weekly series with the old text.
    defp weekly_reconcile(user, board) do
      {:ok, _} = Handbook.install(user, board)

      rec =
        Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Reconcile the handbook")

      {:ok, rec} =
        Boards.Cards.update_card(rec, %{
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
      assert after_rec.description =~ "about 20 of those commits"
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

    test "installing over 1.9.0 ends the reconcile's range on a first-parent commit (#2911)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      rec = card_titled(board, "Reconcile the handbook")
      current = rec.description
      before = Slipdock.Recurrence.for_card(rec)

      # As 1.9.0 wrote step 3: a range that ends on the list's 20th line.
      [step3] = Regex.run(~r/^3\. .*$/m, current)

      old =
        String.replace(
          current,
          step3,
          "3. Take at most 20 of those commits, oldest first: the range is `<to>..<the 20th>`. The rest wait for the next night."
        )

      {:ok, rec} = Boards.Cards.update_card(rec, %{"description" => old, "priority" => "high"})
      assert rec.description =~ "<the 20th>"

      {:ok, again} = Handbook.install(user, board)
      assert again.upgraded
      assert "Reconcile the handbook (updated: nightly)" in again.report.added["cards"]

      after_rec = Repo.reload!(rec)
      assert after_rec.description == current
      refute after_rec.description =~ "<the 20th>"
      assert after_rec.description =~ "git rev-list --first-parent --reverse <to>..origin/"
      assert after_rec.priority == "high"
      assert Slipdock.Recurrence.for_card(after_rec).rule == before.rule

      {:ok, third} = Handbook.install(user, board)
      refute third.upgraded
    end

    test "the series' current card is the one changed, not an older copy",
         %{user: user, board: board} do
      rec = weekly_reconcile(user, board)
      {:ok, old} = Boards.Cards.copy_card(rec)
      # The copy is newer by id but not the series' instance.
      assert old.id > rec.id
      {:ok, old} = Boards.Cards.update_card(old, %{"description" => "an old week"})

      {:ok, _} = Handbook.install(user, board)
      assert Repo.reload!(rec).description =~ "about 20 of those commits"
      assert Repo.reload!(old).description == "an old week"
    end

    test "a stopped series keeps stopped: only the description moves on",
         %{user: user, board: board} do
      rec = weekly_reconcile(user, board)
      {:ok, _} = Slipdock.Recurrence.stop(rec)

      {:ok, again} = Handbook.install(user, board)
      assert again.upgraded
      assert Repo.reload!(rec).description =~ "about 20 of those commits"
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

      {:ok, _} = Boards.Cards.update_card(rec, %{"title" => "Renamed by a person"})

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
        # Principles alone starts with a rule: its worked example (1.5.0).
        unless page.title == "Principles",
          do: assert(Handbook.Rules.parse_page(page) == {[], []}, page.title)
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
                 [
                   "Testing & tooling (Before you push added)",
                   "Testing & tooling (A runner machine added)"
                 ] ++
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
      # The Principles page's three baseline principles (#2041), `should`s.
      assert Handbook.for_board(board, user).rules == %{count: 3, must: 0, problems: []}

      data = Enum.find(handbook_pages(board), &(&1.title == "Data model"))

      {:ok, _} =
        Wiki.update_page(data, %{
          "body" =>
            "# Data model\n\n## Rules\n\n- **DATA-1** must · judgement · Never cast.\n" <>
              "- **DATA-2** should · judgement · Prefer soft deletes.\n" <>
              "- **DATA-3** must · Appended to, never edited.\n"
        })

      assert %{count: 5, must: 1, problems: [problem]} = Handbook.for_board(board, user).rules
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

    test "the seed's Local setup ends with a runner machine stub, and local_setup/1 names it (#2579)",
         %{user: user, board: board} do
      assert Handbook.local_setup(board) == nil
      assert Handbook.local_setup(nil) == nil

      {:ok, _} = Handbook.install(user, board)
      page = testing(board)
      {:ok, local} = Wiki.Section.read(page.body, "Testing & tooling/Local setup")
      assert local =~ "_From a clean checkout to a running app._"
      assert local =~ "### A runner machine"
      assert local =~ "Set up this machine with Claude"

      assert Handbook.local_setup(board) ==
               %{page: page.code, path: "Testing & tooling/Local setup"}

      {:ok, _} = Wiki.update_page(page, %{"body" => "# Testing & tooling\n\n## CI\n"})
      assert Handbook.local_setup(board) == nil
    end

    test "installing over a handbook without the stub adds it, with a Local setup if missing (#2579)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      page = testing(board)

      {:ok, _} =
        Wiki.update_page(page, %{
          "body" => "# Testing & tooling\n\n#{Handbook.before_you_push_skeleton()}"
        })

      {:ok, again} = Handbook.install(user, board)
      assert "Testing & tooling (A runner machine added)" in again.report.added["pages"]
      body = Repo.get!(Page, page.id).body
      assert body =~ "## Local setup\n\n" <> Handbook.runner_machine_skeleton()
      assert Handbook.local_setup(board).path == "Testing & tooling/Local setup"

      # Written by the team at another level: left alone, and not added twice.
      ours = "# Testing & tooling\n\n## Local setup\n\nOurs.\n\n## A runner machine\n\nGo 1.22.\n"
      {:ok, _} = Wiki.update_page(Repo.get!(Page, page.id), %{"body" => ours})
      {:ok, third} = Handbook.install(user, board)
      refute "Testing & tooling (A runner machine added)" in third.report.added["pages"]
      assert Repo.get!(Page, page.id).body =~ "## A runner machine\n\nGo 1.22.\n"
      refute Repo.get!(Page, page.id).body =~ "### A runner machine"
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
      {:ok, _} = Boards.Cards.update_card(rec, %{"description" => "The 1.3.0 procedure."})
      others = for p <- handbook_pages(board), p.id != page.id, into: %{}, do: {p.id, p.body}

      {:ok, again} = Handbook.install(user, board)

      assert again.report.added["pages"] == [
               "Testing & tooling (Before you push added)",
               "Testing & tooling (A runner machine added)"
             ]

      body = Repo.get!(Page, page.id).body

      assert body ==
               "# Testing & tooling\n\n## CI\n\n- **test**: the suite.\n\n" <>
                 Handbook.before_you_push_skeleton() <>
                 "\n## Local setup\n\nOurs.\n\n" <>
                 Handbook.runner_machine_skeleton() <>
                 "\n## Rules\n\n- **TEST-1** must · judgement · Green.\n"

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

  describe "Principles and Playbook (#2040)" do
    defp page_titled(board, title), do: Enum.find(handbook_pages(board), &(&1.title == title))

    test "a fresh install has both, listed by the Index, with their keys and prefixes",
         %{user: user, board: board} do
      {:ok, result} = Handbook.install(user, board)
      assert result.version.version == Handbook.version()

      for {title, key, prefix} <- [
            {"Principles", "principles", "PRIN"},
            {"Playbook", "playbook", "PLAY"}
          ] do
        page = page_titled(board, title)
        assert Handbook.key(page) == key, title
        assert Handbook.Rules.prefix(key) == prefix, title
        assert Handbook.field(page, "covers") == [], title
        assert Handbook.field(page, "read_when") =~ "planning", title
      end

      assert Handbook.section_keys() |> Enum.take(-2) == ["principles", "playbook"]

      # The Index lists the folder by itself: both pages are in its query's answer.
      index = Handbook.find(board).index
      html = Renderer.to_markdown(index.body, board: board, as: user, page: index)

      assert html =~ "Principles"
      assert html =~ "Playbook"
    end

    test "the Principles seed says how to write one, and its baseline items are rules (#2041)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      page = page_titled(board, "Principles")

      assert {:ok, how} = Wiki.Section.read(page.body, "Principles/How to write one")
      assert how =~ "the two ways, the one this project takes, and why"
      assert how =~ "`- **PRIN-n** should · judgement · <the rule, in one line>`"
      assert how =~ "a person's call"
      assert how =~ "edit them or delete them"

      assert {:ok, baseline} = Wiki.Section.read(page.body, "Principles/Baseline")

      for name <- [
            "One place for each concern",
            "The obvious reading",
            "Extend before adding, and split when it grows"
          ],
          do: assert(baseline =~ "**#{name}.**", name)

      # PRIN-3 brakes growth as well as starting new things (#2112).
      assert baseline =~
               "the change that extends it refactors it first, so it ends as two things each " <>
                 "about one thing and never as one huge object. (PRIN-3)"

      refute baseline =~ "**Extend before adding.**"

      assert {rules, []} = Handbook.Rules.parse_page(page)
      assert Enum.map(rules, & &1.id) == ["PRIN-1", "PRIN-2", "PRIN-3"]

      for rule <- rules do
        assert %{severity: "should", check: "judgement", scope: ["**"]} = rule
        assert rule.section == "Principles/Rules"
      end

      assert List.last(rules).text ==
               "An existing page, module or component is extended before a new one is " <>
                 "written beside it; one that has grown big or hard to follow is split in " <>
                 "the same change, each part about one thing."

      # Counted like any other page's rules, and given for any path.
      assert Handbook.for_board(board, user).rules == %{count: 3, must: 0, problems: []}

      assert ["PRIN-1", "PRIN-2", "PRIN-3"] =
               Handbook.find(board) |> Handbook.rules_for(["README.md"]) |> Enum.map(& &1.id)
    end

    test "the Playbook seed sizes, then gives each stage its skill, output and page (#2041)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      page = page_titled(board, "Playbook")
      read = fn section -> elem(Wiki.Section.read(page.body, "Playbook/#{section}"), 1) end

      applies = read.("When this applies")
      assert applies =~ "never by the server"
      assert applies =~ "A card-sized ask gets one card"

      sizing = read.("Sizing")

      for {size, stages} <- [
            {"System", "Grill, Spike (when one is needed), Decide, Principles, Spec, Cards."},
            {"Feature", "Grill, Spike (when one is needed), Spec, Cards."},
            {"Card", "No stages."}
          ],
          do: assert(sizing =~ ~r/\*\*#{size}\*\*:.*#{Regex.escape(stages)}/, size)

      assert sizing =~
               "a new deployable or service, a new repository, or a board with no code yet"

      assert sizing =~ "a change to the data model"

      for stage <- ["Grill", "Spike", "Decide", "Principles", "Spec", "Cards"] do
        text = read.(stage)

        for part <- [
              "**Asks:**",
              "**Skill:** the plan skill's #{stage}",
              "**Produces:**",
              "**Writes to:**"
            ],
            do: assert(text =~ part, "#{stage}: #{part}")
      end

      assert read.("Grill") =~ "add `skill: <its name>` here"
      assert read.("Decide") =~ "`Handbook/Decisions` titled `Decision: <what was chosen>`"
      assert read.("Principles") =~ "Unattended, it goes in as a proposal"
      assert read.("Spec") =~ "a wiki page on the epic"
      assert read.("Card shape") =~ "until this board edits it here"
      assert read.("Defaults") =~ "defaults: none"
      assert read.("Defaults") =~ "A default is never imposed"

      # Hints for a rule only: the Playbook seeds no rules.
      assert Handbook.Rules.parse_page(page) == {[], []}
    end

    test "the seeds fit the gardener's section limit (#2041)", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)

      for title <- ["Principles", "Playbook"] do
        page = page_titled(board, title)
        lines = String.split(page.body, "\n")
        heads = Wiki.Section.headings(page.body) |> Enum.filter(&(&1.level == 2))
        stops = Enum.map(tl(heads), & &1.line) ++ [length(lines)]

        for {h, stop} <- Enum.zip(heads, stops), h.title != "Rules" do
          text = lines |> Enum.slice(h.line..(stop - 1)//1) |> Enum.join("\n") |> String.trim()
          assert String.length(text) < 1500, "#{title}/#{h.title}: #{String.length(text)}"
        end
      end
    end

    test "installing over a 1.5.0 skeleton puts the seed in its place (#2041)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      prin = page_titled(board, "Principles")
      play = page_titled(board, "Playbook")
      seeded = {prin.body, play.body}

      # As 1.5.0 first left them: the skeletons, nobody's words on either.
      for {page, key} <- [{prin, "principles"}, {play, "playbook"}],
          do: {:ok, _} = Wiki.update_page(page, %{"body" => Handbook.skeleton_body(key)})

      assert {[%{id: "PRIN-1", text: "Every date is formatted" <> _}], []} =
               Handbook.Rules.parse_page(Repo.get!(Page, prin.id))

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["pages"] == ["Principles (seed added)", "Playbook (seed added)"]
      assert {Repo.get!(Page, prin.id).body, Repo.get!(Page, play.id).body} == seeded

      # Seeded now: a third install has nothing to do.
      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
      refute Enum.any?(third.report.skipped["pages"], &(&1 =~ "edited"))
    end

    test "an edited 1.5.0 page is left alone, and the report says so (#2041)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      prin = page_titled(board, "Principles")
      play = page_titled(board, "Playbook")

      {:ok, _} = Wiki.update_page(play, %{"body" => Handbook.skeleton_body("playbook")})
      ours = Handbook.skeleton_body("principles") <> "\n**Boring tech.** Postgres first.\n"
      {:ok, _} = Wiki.update_page(prin, %{"body" => ours})

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["pages"] == ["Playbook (seed added)"]
      assert "Principles (edited: left alone)" in again.report.skipped["pages"]
      refute "Principles" in again.report.skipped["pages"]
      assert Repo.get!(Page, prin.id).body == ours
    end

    test "installing 1.6.0 over an unedited 1.5.0 seed rewords PRIN-3 (#2112)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      prin = page_titled(board, "Principles")
      seeded = prin.body

      # As 1.5.0 seeded it: PRIN-3 extends, with no brake on growth.
      old = Handbook.seed_1_5_body("principles")
      assert old =~ "**Extend before adding.** A new page"
      refute old =~ "split when it grows"
      {:ok, _} = Wiki.update_page(prin, %{"body" => old})

      assert {[_, _, %{id: "PRIN-3", text: "An existing page, module or component is " <> t}], []} =
               Handbook.Rules.parse_page(Repo.get!(Page, prin.id))

      assert t == "extended before a new one is written beside it."

      {:ok, again} = Handbook.install(user, board)
      assert again.version.version == Handbook.version()
      assert again.report.added["pages"] == ["Principles (seed updated)"]
      assert Repo.get!(Page, prin.id).body == seeded

      # The ids stay PRIN-1 to PRIN-3, with the new PRIN-3.
      assert {rules, []} = Handbook.Rules.parse_page(Repo.get!(Page, prin.id))
      assert Enum.map(rules, & &1.id) == ["PRIN-1", "PRIN-2", "PRIN-3"]
      assert List.last(rules).text =~ "is split in the same change, each part about one thing."

      # Updated now: a third install has nothing to do.
      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
      refute Enum.any?(third.report.skipped["pages"], &(&1 =~ "edited"))
    end

    test "an edited 1.5.0 seed is left alone by 1.6.0 (#2112)", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      prin = page_titled(board, "Principles")

      # The old PRIN-3 kept, with one principle of the board's own beside it.
      ours =
        String.replace(
          Handbook.seed_1_5_body("principles"),
          "\n## Rules",
          "\n**Boring tech.** Postgres first. (PRIN-4)\n\n## Rules"
        )

      assert ours =~ "**Boring tech.**"
      {:ok, _} = Wiki.update_page(prin, %{"body" => ours})

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["pages"] == []
      assert "Principles (edited: left alone)" in again.report.skipped["pages"]
      assert Repo.get!(Page, prin.id).body == ours
      assert Repo.get!(Page, prin.id).body =~ "**Extend before adding.** A new page"
    end

    defp proposals(board) do
      Repo.all(
        from s in Slipdock.Gardener.Suggestion,
          where: s.board_id == ^board.id and s.check == "proposal",
          order_by: s.id
      )
    end

    defp h2s(body), do: for(h <- Wiki.Section.headings(body), h.level == 2, do: h.title)

    test "a fresh install's Playbook has the Spike stage between Grill and Spec (#2352)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      body = page_titled(board, "Playbook").body

      stages = Enum.filter(h2s(body), &(&1 in ~w(Grill Spike Decide Principles Spec Cards)))
      assert stages == ~w(Grill Spike Decide Principles Spec Cards)

      {:ok, spike} = Wiki.Section.read(body, "Playbook/Spike")
      assert spike =~ "only building answers it (not a person, not reading)"
      assert spike =~ ~s{a "no" changes the spec (say how)}

      assert spike =~
               "a late \"no\" costs more than the spike, counting flow time and lane contention"

      assert spike =~ "gets its card first in build order instead"
      assert spike =~ "None pass: the stage is skipped, and the agent says why."
      assert spike =~ "one `product` wait on the epic"
      assert spike =~ "tagged `spike`"
      assert spike =~ "resumes at Spec once every spike is accepted"

      {:ok, sizing} = Wiki.Section.read(body, "Playbook/Sizing")

      assert sizing =~
               "Stages: Grill, Spike (when one is needed), Decide, Principles, Spec, Cards."

      assert sizing =~ "Stages: Grill, Spike (when one is needed), Spec, Cards."

      assert sizing =~
               "**Card**: anything else. One sitting, one agent, one PR, said in a sentence. Make the card, as Card shape says. No stages."

      assert proposals(board) == []
    end

    test "installing 1.7.0 or later over an unedited 1.6.0 or 1.5.0 Playbook seed updates it (#2352)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")
      seeded = play.body

      for version <- ["1.6.0", "1.5.0"] do
        old = Handbook.seed_body("playbook", version)
        refute old =~ "## Spike"
        assert old =~ "## Grill"
        assert old =~ "made moot" == (version == "1.6.0")
        {:ok, _} = Wiki.update_page(Repo.get!(Page, play.id), %{"body" => old})

        {:ok, again} = Handbook.install(user, board)
        assert again.version.version == Handbook.version()
        assert again.report.added["pages"] == ["Playbook (seed updated)"], version
        assert Repo.get!(Page, play.id).body == seeded
      end

      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
      refute Enum.any?(third.report.skipped["pages"], &(&1 =~ "edited"))
      assert proposals(board) == []
    end

    test "installing over an unedited 1.7.0 Playbook seed names the registry in Grill (#2601)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")
      seeded = play.body

      old = Handbook.seed_body("playbook", "1.7.0")
      assert old =~ "## Spike"
      assert old =~ "To use an installed skill instead, add `skill: <its name>` here."
      refute old =~ "skills registry"
      # Only the Grill's Skill line differs from the seed that replaced it.
      assert [{_, [new_line]}] =
               String.split(old, "\n")
               |> List.myers_difference(
                 String.split(Handbook.seed_body("playbook", "1.8.0"), "\n")
               )
               |> Enum.filter(&(elem(&1, 0) == :ins))

      assert new_line =~ "- **Skill:** the plan skill's Grill."

      {:ok, _} = Wiki.update_page(Repo.get!(Page, play.id), %{"body" => old})
      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["pages"] == ["Playbook (seed updated)"]
      assert Repo.get!(Page, play.id).body == seeded
      assert seeded =~ "the one enabled on this board from the skills registry"
      assert proposals(board) == []
    end

    test "installing over an unedited earlier Playbook seed grills in numbered rounds (#2065)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")
      seeded = play.body
      {:ok, grill} = Slipdock.Wiki.Section.read(seeded, "Playbook/Grill")
      assert grill =~ "- **Asks:** in numbered rounds."
      refute seeded =~ "one question at a time"

      # 1.8.0's seed differs from today's in the Grill's Asks and Skill lines only.
      latest = Handbook.seed_body("playbook", "1.8.0")

      assert [{:ins, [asks, skill]}] =
               String.split(latest, "\n")
               |> List.myers_difference(String.split(String.trim(seeded), "\n"))
               |> Enum.filter(&(elem(&1, 0) == :ins))

      assert asks =~ "- **Asks:** in numbered rounds."
      assert skill =~ "- **Skill:** the plan skill's Grill."

      for version <- ["1.8.0", "1.7.0", "1.6.0", "1.5.0"] do
        old = Handbook.seed_body("playbook", version)
        assert old =~ "- **Asks:** one question at a time, until the agent can say back", version
        refute old =~ "numbered rounds"
        refute old =~ "`grilling`"
        {:ok, _} = Wiki.update_page(Repo.get!(Page, play.id), %{"body" => old})

        {:ok, again} = Handbook.install(user, board)
        assert again.report.added["pages"] == ["Playbook (seed updated)"], version
        refute Enum.any?(again.report.skipped["pages"], &(&1 =~ "edited")), version
        assert Repo.get!(Page, play.id).body == seeded
      end

      # Once it holds today's seed, installing again changes nothing.
      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
      refute Enum.any?(third.report.skipped["pages"], &(&1 =~ "edited"))
      assert Repo.get!(Page, play.id).body == seeded
      assert proposals(board) == []
    end

    test "an edited 1.8.0 or 1.5.0 Playbook keeps asking one at a time (#2065)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")

      for {version, note} <- [
            {"1.8.0", "Playbook (edited: left alone)"},
            {"1.5.0", "Playbook (edited: left alone; Spike stage proposed)"}
          ] do
        ours =
          String.replace(
            Handbook.seed_body("playbook", version),
            "\n## Decide",
            "\nWe grill over coffee.\n\n## Decide"
          )

        {:ok, _} = Wiki.update_page(Repo.get!(Page, play.id), %{"body" => ours})
        {:ok, again} = Handbook.install(user, board)

        assert again.report.added["pages"] == [], version
        assert note in again.report.skipped["pages"], version
        body = Repo.get!(Page, play.id).body
        assert body == ours
        assert body =~ "- **Asks:** one question at a time"
        refute body =~ "numbered rounds"
      end
    end

    test "an edited 1.7.0 Playbook keeps its Grill line and gets no proposal (#2601)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")

      ours =
        String.replace(
          Handbook.seed_body("playbook", "1.7.0"),
          "\n## Decide",
          "\nWe grill over coffee.\n\n## Decide"
        )

      {:ok, _} = Wiki.update_page(play, %{"body" => ours})
      {:ok, again} = Handbook.install(user, board)

      assert again.report.added["pages"] == []
      assert "Playbook (edited: left alone)" in again.report.skipped["pages"]
      assert Repo.get!(Page, play.id).body == ours
      assert proposals(board) == []
    end

    test "an edited Playbook is left alone and gets one proposal adding Spike (#2352)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")

      ours =
        String.replace(
          Handbook.seed_body("playbook", "1.6.0"),
          "\n## Decide",
          "\nWe grill over coffee.\n\n## Decide"
        )

      {:ok, _} = Wiki.update_page(play, %{"body" => ours})

      {:ok, again} = Handbook.install(user, board)
      assert again.report.added["pages"] == []

      assert "Playbook (edited: left alone; Spike stage proposed)" in again.report.skipped[
               "pages"
             ]

      assert Repo.get!(Page, play.id).body == ours

      assert [proposal] = proposals(board)
      assert proposal.state == "open"
      assert proposal.explanation =~ "Spike stage"

      assert [%{"op" => "edit_section", "page" => page_id, "section" => "Playbook/Grill"}] =
               proposal.proposal

      assert page_id == play.id

      # Installing again files no second one, and still leaves the page alone.
      {:ok, third} = Handbook.install(user, board)
      assert "Playbook (edited: left alone)" in third.report.skipped["pages"]
      assert [_] = proposals(board)
      assert Repo.get!(Page, play.id).body == ours

      # Applied, it keeps the board's Grill and puts Spike after it.
      assert {:ok, _} = Slipdock.Gardener.apply(proposal, user, actor: Slipdock.Actor.web(user))
      body = Repo.get!(Page, play.id).body
      assert body =~ "We grill over coffee."
      assert Enum.take(Enum.drop_while(h2s(body), &(&1 != "Grill")), 3) == ~w(Grill Spike Decide)
      assert body =~ "only building answers it (not a person, not reading)"

      # With Spike on the page now, installing proposes nothing more.
      {:ok, fourth} = Handbook.install(user, board)
      assert "Playbook (edited: left alone)" in fourth.report.skipped["pages"]
      assert [_] = proposals(board)
    end

    test "an edited Playbook with no Grill gets Spike proposed before its Spec (#2352)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")

      ours =
        "# Playbook\n\nOurs.\n\n## Spec\n\nA page.\n\n## Cards\n\nSubcards.\n\n" <>
          Handbook.rules_skeleton("playbook")

      {:ok, _} = Wiki.update_page(play, %{"body" => ours})

      {:ok, _} = Handbook.install(user, board)
      assert [proposal] = proposals(board)
      assert [%{"section" => "Playbook/Spec"}] = proposal.proposal
      assert {:ok, _} = Slipdock.Gardener.apply(proposal, user, actor: Slipdock.Actor.web(user))
      assert h2s(Repo.get!(Page, play.id).body) == ~w(Spike Spec Cards Rules)
    end

    test "an edited Playbook with a Spike already, or with neither Grill nor Spec, gets none (#2352)",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      play = page_titled(board, "Playbook")

      for ours <- [
            "# Playbook\n\n## Grill\n\nAsk.\n\n## Spike\n\nOur own.\n\n## Spec\n\nWrite.\n",
            "# Playbook\n\nWe plan on a whiteboard.\n"
          ],
          ours = ours <> "\n" <> Handbook.rules_skeleton("playbook") do
        {:ok, _} = Wiki.update_page(Repo.get!(Page, play.id), %{"body" => ours})
        {:ok, again} = Handbook.install(user, board)
        assert "Playbook (edited: left alone)" in again.report.skipped["pages"]
        assert Repo.get!(Page, play.id).body == ours
      end

      assert proposals(board) == []
    end

    test "the seed card leaves them to a person", %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      seed = Repo.get_by!(Slipdock.Boards.Card, board_id: board.id, title: "Seed the handbook")
      assert seed.description =~ "Principles and Playbook say how this project decides and plans"
      assert seed.description =~ "leave them as they are"
    end

    test "installing over 1.4.0 adds only the two pages, and a third install adds nothing",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)

      # As 1.4.0 left it: no Principles, no Playbook, and a page written by us.
      for title <- ["Principles", "Playbook"],
          do: {:ok, _} = Wiki.delete_page(page_titled(board, title))

      arch = page_titled(board, "Architecture")
      {:ok, _} = Wiki.update_page(arch, %{"body" => arch.body <> "\nOurs now.\n"})
      before = Map.new(handbook_pages(board), &{&1.id, {&1.body, &1.updated_at}})

      {:ok, again} = Handbook.install(user, board)
      assert again.version.version == Handbook.version()
      # The report names what it added.
      assert again.report.added["pages"] == ["Principles", "Playbook"]
      assert again.report.added["cards"] == []

      for page <- handbook_pages(board),
          Map.has_key?(before, page.id),
          do: assert({page.body, page.updated_at} == before[page.id], page.title)

      assert length(handbook_pages(board)) == 11

      assert {[%{id: "PRIN-1"}, %{id: "PRIN-2"}, %{id: "PRIN-3"}], []} =
               Handbook.Rules.parse_page(page_titled(board, "Principles"))

      {:ok, third} = Handbook.install(user, board)
      assert third.report.added["pages"] == []
      assert third.report.added["cards"] == []
      assert length(handbook_pages(board)) == 11
    end

    test "an edited Principles or Playbook is the board's own: installing again leaves it",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      prin = page_titled(board, "Principles")
      play = page_titled(board, "Playbook")

      ours =
        "# Principles\n\n## Principles\n\n**Boring tech.** Postgres first.\n\n## Rules\n\n" <>
          "- **PRIN-1** should · judgement · Postgres before another store.\n"

      {:ok, _} = Wiki.update_page(prin, %{"body" => ours})

      {:ok, _} =
        Wiki.update_page(play, %{"body" => "# Playbook\n\n## Sizing\n\nEverything is a card.\n"})

      {:ok, again} = Handbook.install(user, board)
      # A page that lost its Rules gets them back, as every section page does (#1773).
      assert again.report.added["pages"] == ["Playbook (Rules section added)"]
      assert Repo.get!(Page, prin.id).body == ours

      assert Repo.get!(Page, play.id).body =~
               ~r/\A# Playbook\n\n## Sizing\n\nEverything is a card.\n/

      assert [%{id: "PRIN-1", text: "Postgres before another store."}] =
               Handbook.Rules.rules(Handbook.find(board))
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

    test "a path followed by a non-ASCII character comes back whole characters" do
      paths =
        Handbook.mentioned_paths(
          "Touches priv/repo/migrations/… and lib/é.ex → docs/x.md, see https://example.com/é/…"
        )

      assert "priv/repo/migrations/" in paths
      assert "lib/é.ex" in paths
      assert "docs/x.md" in paths
      assert Enum.all?(paths, &String.valid?/1)
      refute Enum.any?(paths, &String.contains?(&1, "example.com"))
    end
  end
end
