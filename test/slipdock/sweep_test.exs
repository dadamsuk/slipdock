defmodule Slipdock.SweepTest do
  @moduledoc """
  The built-in Sweep Tool (#1793, W-2310 §Sweeps and static checks):
  installing it gives a board's root a `Sweeps` rotation page, a `Triage`
  list and a daily *Sweep the code* card; and nothing feeds the loop from
  the Triage list.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Handbook, Repo, Sweep, Wiki}
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Runners.Job
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.APIGuide

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Project"}, owner: user)
    %{user: user, board: board}
  end

  defp triage(board),
    do: Repo.one(from(c in Column, where: c.board_id == ^board.id and c.name == "Triage"))

  defp sweep_cards(board),
    do: Repo.all(from(c in Card, where: c.board_id == ^board.id and c.title == "Sweep the code"))

  defp rotation_pages(board),
    do: Repo.all(from(p in Page, where: p.board_id == ^board.id and p.title == "Sweeps"))

  describe "install/3" do
    test "makes the page, the Triage list and the daily card", %{user: user, board: board} do
      assert Sweep.find(board) == nil
      assert {:ok, result} = Sweep.install(user, board)
      assert result.created
      assert result.board.id == board.id
      assert result.install.version == Sweep.version()

      assert result.report.added["lists"] == ["Triage"]
      assert result.report.added["pages"] == ["Sweeps"]
      assert result.report.added["cards"] == ["Sweep the code"]

      list = triage(board)
      assert list.category == "triage"
      assert Column.triage?(list)

      [page] = rotation_pages(board)
      assert page.front_matter =~ "sweep: rotation"

      for {lens, _} <- Sweep.lenses() do
        assert page.body =~ "| #{lens}" or page.body =~ " #{lens} |"
        assert page.body =~ "- **#{lens}**"
      end

      assert page.body =~ "## Rotation"
      assert page.body =~ "## Log"
      assert page.body =~ "no areas yet"

      [card] = sweep_cards(board) |> Repo.preload(:column)
      refute card.column.category == "triage"
      assert card.description =~ "One area and one lens per run"
      # Fixes and investigations to Housekeeping, design questions to Triage,
      # everything to Triage with no Housekeeping list (#2779).
      assert card.description =~ "--column Housekeeping --origin sweep"
      assert card.description =~ "--column Triage --origin sweep"
      assert card.description =~ "On a board with no Housekeeping list, everything goes to Triage"
      # The description says where, why and the fix: a heredoc on stdin (#2686).
      assert card.description =~ "--column Housekeeping --origin sweep --desc - <<'EOF'"
      assert card.description =~ "`--desc -` reads it from stdin"
      assert card.description =~ "--tag security"
      assert card.description =~ "clean tree"

      found = Sweep.find(board)
      assert found.page.id == page.id
      assert found.card.id == card.id
    end

    test "the card repeats every day", %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [card] = sweep_cards(board)
      assert Slipdock.Recurrence.for_card(card).rule == "FREQ=DAILY"
    end

    test "installing again adds only what is missing", %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [page] = rotation_pages(board)
      {:ok, _} = Wiki.update_page(page, %{"body" => "# Sweeps\n\nOur table."})

      assert {:ok, again} = Sweep.install(user, board)
      refute again.created
      assert again.report.added == %{again.report.added | "lists" => [], "pages" => []}
      assert again.report.added["cards"] == []
      assert length(sweep_cards(board)) == 1
      assert Repo.aggregate(from(c in Column, where: c.name == "Triage"), :count) == 1
      assert Repo.get!(Page, page.id).body =~ "Our table."

      # A deleted list comes back; nothing else is added twice.
      list = triage(board)
      Repo.delete!(list)

      assert {:ok, third} = Sweep.install(user, board)
      assert third.report.added["lists"] == ["Triage"]
      assert third.report.added["pages"] == []
      assert triage(board).category == "triage"
    end

    test "installing 1.1.0 over an older sweep gives its card the current procedure (#2779)",
         %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [card] = sweep_cards(board)
      old = "File each issue as a card in the `Triage` list, never in the ready list."
      {:ok, _} = Boards.update_card(card, %{"description" => old, "priority" => "high"})

      assert {:ok, again} = Sweep.install(user, board)
      assert again.upgraded
      assert again.report.added["cards"] == ["Sweep the code (updated: procedure)"]
      [after_card] = sweep_cards(board)
      assert after_card.id == card.id
      assert after_card.description =~ "--column Housekeeping --origin sweep"
      assert after_card.priority == "high"

      # Once current, installing again leaves it be.
      assert {:ok, third} = Sweep.install(user, board)
      refute third.upgraded
      assert third.report.added["cards"] == []
    end

    test "a Triage list made by hand gets the category; one with its own keeps it",
         %{user: user, board: board} do
      {:ok, hand} = Boards.create_column(board, %{"name" => "triage"})
      assert hand.category in [nil, ""]

      assert {:ok, result} = Sweep.install(user, board)
      assert result.report.added["lists"] == ["triage (category set)"]
      assert Repo.get!(Column, hand.id).category == "triage"
      assert Repo.aggregate(from(c in Column, where: c.board_id == ^board.id), :count) == 5

      other = board_fixture(%{"name" => "Other"}, owner: user)
      {:ok, own} = Boards.create_column(other, %{"name" => "Triage", "category" => "todo"})
      assert {:ok, result} = Sweep.install(user, other)
      assert result.report.added["lists"] == []
      assert Repo.get!(Column, own.id).category == "todo"
    end

    test "the areas are the handbook's pages that say what they cover",
         %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      %{pages: pages} = Handbook.find(board)
      arch = Enum.find(pages, &(&1.title == "Architecture"))
      ops = Enum.find(pages, &(&1.title == "Operations"))

      {:ok, _} =
        Wiki.update_page(arch, %{
          "front_matter" =>
            "---\nhandbook: architecture\ncovers: [lib/app/**, lib/a|b.ex]\n---\n\n"
        })

      {:ok, _} =
        Wiki.update_page(ops, %{
          "front_matter" => "---\nhandbook: operations\ncovers: config/**\n---\n\n"
        })

      assert Sweep.areas(board) == [
               {"Architecture", ["lib/app/**", "lib/a|b.ex"]},
               {"Operations", ["config/**"]}
             ]

      {:ok, _} = Sweep.install(user, board)
      [page] = rotation_pages(board)
      assert page.body =~ "| Architecture | `lib/app/**`, `lib/a\\|b.ex` | —"
      assert page.body =~ "| Operations | `config/**` | —"
      refute page.body =~ "no areas yet"
      refute page.body =~ "| Specification |"
    end

    test "with no handbook there are no areas", %{board: board} do
      assert Sweep.areas(board) == []
    end

    test "a sub-board's install goes on the root board", %{user: user, board: board} do
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)

      assert {:ok, result} = Sweep.install(user, sub)
      assert result.board.id == board.id
      assert Sweep.find(sub).board.id == board.id
      assert triage(board)
      refute triage(sub)
    end

    test "refuses somebody who can't write to the board", %{board: board} do
      stranger = user_fixture("sweep-stranger@example.com")
      assert {:error, message} = Sweep.install(stranger, board)
      assert message =~ "write access"
      assert Sweep.find(board) == nil
      refute triage(board)
    end

    test "an archived page is not the rotation", %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [page] = rotation_pages(board)

      Repo.update_all(from(p in Page, where: p.id == ^page.id),
        set: [archived_at: DateTime.utc_now()]
      )

      assert Sweep.find(board) == nil
    end
  end

  describe "the card's bar (#2611)" do
    # The previous instance as its run leaves it: the bar reworded for the
    # day's cell, locked, the card done.
    defp swept(card, bar) do
      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [bar: bar, bar_locked_at: DateTime.utc_now(:second)]
      )

      {:ok, card} = Boards.update_card(Repo.get!(Card, card.id), %{"completed" => true})
      card
    end

    # `days` on from now: far enough that the series' next occurrence has come.
    defp next_instance(card, days \\ 3) do
      series = Slipdock.Recurrence.for_card(card)
      assert Slipdock.Recurrence.tick(DateTime.add(DateTime.utc_now(), days, :day)) == 1
      Boards.get_card!(Repo.get!(Slipdock.Recurrence.Series, series.id).card_id)
    end

    test "is the template at install: the page's code and no cell", %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [card] = sweep_cards(board)
      [page] = rotation_pages(board)

      assert card.bar == Sweep.card_bar(page.code)
      assert card.bar =~ "the stalest cell of #{page.code}'s Rotation table"
      assert is_nil(card.bar_locked_at)

      for {lens, _} <- Sweep.lenses(), do: refute(card.bar =~ lens)
    end

    test "the next instance starts from the template, not the cell its run named",
         %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [card] = sweep_cards(board)
      [page] = rotation_pages(board)

      yesterday =
        "Swept Architecture × test gaps (the stalest cell) at abc1234\nW-1 cell updated"

      new = card |> swept(yesterday) |> next_instance()

      refute new.id == card.id
      assert new.title == "Sweep the code"
      assert new.bar == Sweep.card_bar(page.code)
      refute new.bar =~ "Architecture"
      refute new.bar =~ "test gaps"
      assert is_nil(new.bar_locked_at)

      # And the day after, from a run that named another cell.
      newer = new |> swept("Swept Accounts × dead code at def5678") |> next_instance(6)
      assert newer.bar == Sweep.card_bar(page.code)
      refute newer.bar =~ "Accounts"
    end

    test "an older install's card with no bar gets it; a bar somebody wrote is kept",
         %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [card] = sweep_cards(board)
      [page] = rotation_pages(board)

      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [bar: nil])
      {:ok, _} = Sweep.install(user, board)
      assert Repo.get!(Card, card.id).bar == Sweep.card_bar(page.code)

      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [bar: "Our own bar"])
      {:ok, _} = Sweep.install(user, board)
      assert Repo.get!(Card, card.id).bar == "Our own bar"
    end

    test "is only for the sweep's own card on a board with the sweep", %{
      user: user,
      board: board
    } do
      [_backlog, todo | _] = board.columns

      # The same title on a board with no sweep installed keeps its own bar.
      lookalike = card_fixture(todo, %{"title" => "Sweep the code", "bar" => "Ours"})
      assert Sweep.template_bar(lookalike) == nil

      {:ok, _} = Sweep.install(user, board)
      other = card_fixture(todo, %{"title" => "Another chore", "bar" => "Its own"})
      assert Sweep.template_bar(other) == nil
      assert Sweep.template_bar(Repo.get!(Card, lookalike.id)) =~ "the stalest cell of W-"

      # Another chore's series carries its own bar, as before (#2081).
      {:ok, _} = Slipdock.Recurrence.set(other, %{"rule" => "every day"}, user)
      new = other |> swept("Its own, reworded") |> next_instance()
      assert new.bar == "Its own, reworded"
    end

    test "a card of the same title on a sub-board of a swept board keeps its own bar",
         %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [col | _] = board.columns
      epic = card_fixture(col, %{"title" => "Epic"})
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(epic, t)
      [sub_col | _] = Boards.get_board!(sub.id).columns

      # Sweep.find(sub) finds the root's sweep, but the template is the root
      # card's, not this one's.
      assert Sweep.find(sub).board.id == board.id
      lookalike = card_fixture(sub_col, %{"title" => "Sweep the code", "bar" => "Sub's own"})
      assert Sweep.template_bar(lookalike) == nil

      {:ok, series} = Slipdock.Recurrence.set(lookalike, %{"rule" => "every day"}, user)
      swept(lookalike, "Sub's own, reworded")
      # The root's own Sweep the code series is due too: two instances.
      assert Slipdock.Recurrence.tick(DateTime.add(DateTime.utc_now(), 3, :day)) == 2
      new = Boards.get_card!(Repo.get!(Slipdock.Recurrence.Series, series.id).card_id)
      refute new.id == lookalike.id
      assert new.board_id == sub.id
      assert new.bar == "Sub's own, reworded"
    end

    test "a locked card with no bar is left alone at reinstall", %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      [card] = sweep_cards(board)
      locked_at = DateTime.utc_now(:second)

      Repo.update_all(from(c in Card, where: c.id == ^card.id),
        set: [bar: "", bar_locked_at: locked_at]
      )

      {:ok, _} = Sweep.install(user, board)
      card = Repo.get!(Card, card.id)
      assert card.bar == ""
      assert card.bar_locked_at == locked_at
    end
  end

  describe "tool?/1" do
    test "names the built-in Tool, whatever the case" do
      assert Sweep.tool?("sweep")
      assert Sweep.tool?(" Sweep ")
      refute Sweep.tool?("handbook")
      refute Sweep.tool?(nil)
    end
  end

  describe "the Triage list is never fed (#1793)" do
    setup %{user: user, board: board} do
      {:ok, _} = Sweep.install(user, board)
      %{triage: triage(board)}
    end

    test "the guide's ready list and backlog skip it, even placed first",
         %{board: board, triage: triage} do
      Repo.update_all(from(c in Column, where: c.id == ^triage.id), set: [position: -1])
      columns = Boards.get_board!(board.id).columns
      assert hd(columns).id == triage.id

      roles = APIGuide.list_roles(columns)
      assert roles.ready.name == "To Do"
      refute roles.backlog.id == triage.id
      assert APIGuide.role(columns, triage) == nil
    end

    test "a list named like a ready list is still triage when its category says so" do
      columns = [
        %Column{id: 1, name: "To Do triage", category: "triage"},
        %Column{id: 2, name: "Later", category: nil}
      ]

      assert APIGuide.role(columns, hd(columns)) == nil
      assert APIGuide.list_roles(columns).ready.id == 2
    end

    test "on a board without categories the other lists keep their reading" do
      columns = [
        %Column{id: 1, name: "Triage", category: "triage"},
        %Column{id: 2, name: "Ideas pile", category: nil}
      ]

      assert APIGuide.role(columns, Enum.at(columns, 1)) == "todo"
      assert APIGuide.list_roles(columns).ready.id == 2
    end

    test "the guide says what the list is for", %{user: user} do
      guide = APIGuide.markdown(user: user)
      assert guide =~ "Triage (triage: for a person, never take work from it"
    end

    test "a list_top rule on it sends nothing", %{board: board, triage: triage} do
      {:ok, _runner, _} =
        Slipdock.Runners.create_runner(board, %{"name" => "box", "pool" => "loop"})

      card_fixture(triage, %{"title" => "A finding"})

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "list_top", "column" => "Triage"},
          "actions" => [%{"type" => "runner", "pool" => "loop"}]
        })

      assert Automations.next_card(rule) == nil
      assert {:idle, :empty} = Automations.feed(rule)
      assert Repo.aggregate(Job, :count) == 0
    end

    test "a rule's runner action skips a card arriving in it, and still sends from elsewhere",
         %{board: board, triage: triage} do
      [_backlog, todo | _] = Boards.get_board!(board.id).columns

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_entered", "column" => "Triage"},
        "actions" => [%{"type" => "runner", "pool" => "dev"}]
      })

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_entered", "column" => "To Do"},
        "actions" => [%{"type" => "runner", "pool" => "dev"}]
      })

      card = card_fixture(todo, %{"title" => "Found"})
      Repo.delete_all(Job)

      Boards.move_card(card.id, triage.id)
      assert Repo.aggregate(Job, :count) == 0

      Boards.move_card(card.id, todo.id)
      assert [%Job{card_id: id}] = Repo.all(Job)
      assert id == card.id
    end
  end
end
