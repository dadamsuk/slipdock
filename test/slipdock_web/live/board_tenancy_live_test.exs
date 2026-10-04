defmodule SlipdockWeb.BoardTenancyLiveTest do
  @moduledoc """
  A board's LiveView acts only on what is on that board. Write access to your
  own board is no reason to touch a row on somebody else's, so every handler
  that takes an id from the client is pushed an id from a stranger's board
  here — the way anyone could from DevTools — and must leave it alone.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo, Sprints}
  alias Slipdock.Boards.{Card, ChecklistItem, Column, Comment, Tag}
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.BoardLive.Show

  setup %{user: user} do
    # The attacker: the signed-in user, with a board and a card of their own.
    mine = board_fixture(%{"name" => "Mine"}, owner: user)
    [my_col | _] = mine.columns
    my_card = card_fixture(my_col, %{"title" => "My card"})

    # The victim, who has shared nothing.
    victim = user_fixture("victim@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: victim)
    [their_col, their_other_col | _] = theirs.columns
    their_card = card_fixture(their_col, %{"title" => "Their card"})
    archived = card_fixture(their_col, %{"title" => "Their archived card"})
    {:ok, archived} = Boards.archive_card(archived)
    {:ok, check} = Boards.add_checklist_item(their_card, "Their step")
    {:ok, comment} = Boards.add_comment(their_card, "Their comment")
    tag = tag_fixture(theirs, "theirs")

    %{
      mine: mine,
      my_col: my_col,
      my_card: my_card,
      victim: victim,
      theirs: theirs,
      their_col: their_col,
      their_other_col: their_other_col,
      their_card: their_card,
      archived: archived,
      check: check,
      comment: comment,
      tag: tag
    }
  end

  defp board_view(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}")
    view
  end

  defp card_view(conn, board, card) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/cards/#{card.id}")
    view
  end

  # The Automations panel is a LiveComponent with events of its own; a hook
  # pushed with it as the target goes to it rather than to the board.
  defp automations_panel(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
    with_target(view, "#board-automations")
  end

  # The card panel is a LiveComponent; what it is pushed goes to it.
  defp card_panel(view), do: with_target(view, "#board-card")

  defp archive_panel(conn, board) do
    {:ok, view, _} = live(conn, ~p"/boards/#{board}/archive")
    with_target(view, "#board-archive")
  end

  describe "lists" do
    test "can't be renamed, recoloured or deleted from another board", ctx do
      view = board_view(ctx.conn, ctx.mine)
      id = to_string(ctx.their_col.id)

      render_hook(view, "rename_column", %{"column_id" => id, "name" => "Pwned"})

      # List settings are a component of their own.
      settings = with_target(view, "#board-column")
      render_hook(settings, "edit_column", %{"id" => id})
      render_hook(settings, "set_column_color", %{"color" => "rose"})
      render_hook(settings, "save_column", %{"column" => %{"name" => "Pwned"}})
      render_hook(settings, "delete_column", %{"id" => id})

      column = Repo.get!(Column, ctx.their_col.id)
      assert column.name == ctx.their_col.name
      assert column.color == ctx.their_col.color
      assert Repo.get(Card, ctx.their_card.id)
    end

    test "still work on your own board", ctx do
      view = board_view(ctx.conn, ctx.mine)

      render_hook(view, "rename_column", %{"column_id" => "#{ctx.my_col.id}", "name" => "Renamed"})

      assert Repo.get!(Column, ctx.my_col.id).name == "Renamed"
    end
  end

  describe "archived cards" do
    test "another board's can't be restored or deleted", ctx do
      view = archive_panel(ctx.conn, ctx.mine)

      render_hook(view, "restore_card", %{"id" => "#{ctx.archived.id}"})
      assert Repo.get!(Card, ctx.archived.id).archived_at

      render_hook(view, "delete_archived", %{"id" => "#{ctx.archived.id}"})
      assert Repo.get(Card, ctx.archived.id)
    end

    test "nor can a live card be deleted through delete_archived", ctx do
      {:ok, mine_archived} = Boards.archive_card(card_fixture(ctx.my_col))
      view = archive_panel(ctx.conn, ctx.mine)

      render_hook(view, "delete_archived", %{"id" => "#{ctx.my_card.id}"})
      assert Repo.get(Card, ctx.my_card.id)

      render_hook(view, "delete_archived", %{"id" => "#{mine_archived.id}"})
      refute Repo.get(Card, mine_archived.id)
    end
  end

  describe "the open card's contents" do
    test "another card's checklist items and comments are left alone", ctx do
      view = card_view(ctx.conn, ctx.mine, ctx.my_card)

      render_hook(card_panel(view), "toggle_check", %{"id" => "#{ctx.check.id}"})
      refute Repo.get!(ChecklistItem, ctx.check.id).done

      render_hook(card_panel(view), "delete_check", %{"id" => "#{ctx.check.id}"})
      assert Repo.get(ChecklistItem, ctx.check.id)

      render_hook(card_panel(view), "delete_comment", %{"id" => "#{ctx.comment.id}"})
      assert Repo.get(Comment, ctx.comment.id)
    end

    test "the open card's own still work", ctx do
      {:ok, check} = Boards.add_checklist_item(ctx.my_card, "Mine")
      {:ok, comment} = Boards.add_comment(ctx.my_card, "Mine")
      view = card_view(ctx.conn, ctx.mine, ctx.my_card)

      render_hook(card_panel(view), "toggle_check", %{"id" => "#{check.id}"})
      assert Repo.get!(ChecklistItem, check.id).done

      render_hook(card_panel(view), "delete_comment", %{"id" => "#{comment.id}"})
      refute Repo.get(Comment, comment.id)
    end

    test "a subcard can't be added to a stranger's list", ctx do
      {:ok, t} = Boards.find_template("Simple")
      {:ok, _} = Boards.create_sub_board(ctx.my_card, t)
      view = card_view(ctx.conn, ctx.mine, ctx.my_card)

      render_hook(card_panel(view), "quick_add_subcard", %{
        "column_id" => "#{ctx.their_col.id}",
        "title" => "Planted"
      })

      refute Repo.get_by(Card, title: "Planted")
    end

    test "another board's tag can't be put on the card", ctx do
      view = card_view(ctx.conn, ctx.mine, ctx.my_card)
      render_hook(card_panel(view), "toggle_tag", %{"id" => "#{ctx.tag.id}"})
      assert Repo.preload(Repo.get!(Card, ctx.my_card.id), :tags).tags == []
    end

    test "remove_assignee needs write access to the card, and an open one", ctx do
      {:ok, _} = Boards.update_card(ctx.their_card, %{"assignee_id" => ctx.victim.id})
      {:ok, _} = Access.grant(ctx.theirs, ctx.user, "read", ctx.victim)

      view = card_view(ctx.conn, ctx.theirs, ctx.their_card)

      render_hook(card_panel(view), "remove_assignee", %{"id" => "#{ctx.victim.id}"})
      assert render(view) =~ "read-only"

      assert Boards.get_card!(ctx.their_card.id).assignee_id == ctx.victim.id

      # With no card open there is no card panel, and the board itself
      # knows no such event.
      view = board_view(ctx.conn, ctx.mine)
      refute has_element?(view, "#board-card")

      assert render_hook(view, "remove_assignee", %{"id" => "#{ctx.victim.id}"}) =~
               "isn&#39;t something this page can do"
    end

    test "a wiki page you can't read can't be attached", ctx do
      page = page_fixture(ctx.theirs, %{"title" => "Their secret page"}, user: ctx.victim)
      view = card_view(ctx.conn, ctx.mine, ctx.my_card)

      render_hook(card_panel(view), "attach_doc", %{"page" => "#{page.id}"})
      html = render(view)
      refute html =~ page.code
      assert html =~ "couldn"
      assert Slipdock.Wiki.pages_for_card(ctx.my_card, ctx.victim) == []
    end
  end

  describe "tags" do
    test "another board's can't be recoloured, renamed or deleted", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.mine}/tags")
      panel = with_target(view, "#board-tags")
      id = "#{ctx.tag.id}"

      render_hook(panel, "set_tag_color", %{"id" => id, "color" => "rose"})
      render_hook(panel, "rename_tag", %{"tag_id" => id, "name" => "pwned"})
      render_hook(panel, "delete_tag", %{"id" => id})

      tag = Repo.get!(Tag, ctx.tag.id)
      assert tag.name == "theirs" and tag.color == "sky"
    end
  end

  describe "moves" do
    test "a stranger's card can't be dragged onto your board", ctx do
      view = board_view(ctx.conn, ctx.mine)

      render_hook(view, "move_card", %{"id" => "#{ctx.their_card.id}", "to" => "#{ctx.my_col.id}"})

      card = Repo.get!(Card, ctx.their_card.id)
      assert card.board_id == ctx.theirs.id and card.column_id == ctx.their_col.id
    end

    test "nor moved around their board from yours", ctx do
      view = board_view(ctx.conn, ctx.mine)

      render_hook(view, "move_card", %{
        "id" => "#{ctx.their_card.id}",
        "to" => "#{ctx.their_other_col.id}"
      })

      assert Repo.get!(Card, ctx.their_card.id).column_id == ctx.their_col.id
    end

    test "your card can't be sent into a stranger's list", ctx do
      view = board_view(ctx.conn, ctx.mine)

      render_hook(view, "move_card", %{"id" => "#{ctx.my_card.id}", "to" => "#{ctx.their_col.id}"})

      assert Repo.get!(Card, ctx.my_card.id).column_id == ctx.my_col.id

      view = card_view(ctx.conn, ctx.mine, ctx.my_card)

      render_hook(card_panel(view), "card_change", %{
        "card" => %{"column_id" => "#{ctx.their_col.id}"}
      })

      assert Repo.get!(Card, ctx.my_card.id).column_id == ctx.my_col.id

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.mine}/table")

      render_hook(view, "table_update", %{
        "card_id" => "#{ctx.my_card.id}",
        "field" => "column_id",
        "value" => "#{ctx.their_col.id}"
      })

      card = Repo.get!(Card, ctx.my_card.id)
      assert card.board_id == ctx.mine.id and card.column_id == ctx.my_col.id
    end

    test "Boards.move_card refuses a list on another board", ctx do
      assert {:error, :wrong_board} = Boards.move_card(ctx.my_card.id, ctx.their_col.id)
      assert :ok = Boards.move_card(ctx.their_card.id, ctx.their_other_col.id)
    end
  end

  describe "cards named by id" do
    test "toggle_complete and prio_vote reach only this board's cards", ctx do
      view = board_view(ctx.conn, ctx.mine)

      render_hook(view, "toggle_complete", %{"id" => "#{ctx.their_card.id}"})
      refute Repo.get!(Card, ctx.their_card.id).completed

      render_hook(view, "prio_vote", %{"card_id" => "#{ctx.their_card.id}", "count" => 3})

      assert Repo.aggregate(
               from(v in Slipdock.Boards.Vote, where: v.card_id == ^ctx.their_card.id),
               :count
             ) == 0
    end

    test "a write grant on a view covers that board, not every card", ctx do
      # The victim shares an unfiltered view of one board, with write access.
      {:ok, saved} =
        Boards.create_saved_view(ctx.theirs, %{
          "name" => "Everything",
          "config" => Config.to_map(Config.defaults("table"))
        })

      {:ok, _} = Access.grant(saved, ctx.user, "write", ctx.victim)

      # And has a second board, shared with nobody.
      other = board_fixture(%{"name" => "Private"}, owner: ctx.victim)
      private = card_fixture(hd(other.columns), %{"title" => "Private card"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.theirs}/table?view=#{saved.id}")

      render_hook(view, "toggle_complete", %{"id" => "#{private.id}"})
      refute Repo.get!(Card, private.id).completed

      render_hook(view, "prio_vote", %{"card_id" => "#{private.id}", "count" => 2})

      assert Repo.aggregate(
               from(v in Slipdock.Boards.Vote, where: v.card_id == ^private.id),
               :count
             ) == 0

      # The view's own board is what the grant is for.
      render_hook(view, "toggle_complete", %{"id" => "#{ctx.their_card.id}"})
      assert Repo.get!(Card, ctx.their_card.id).completed
    end
  end

  describe "automation rules" do
    setup ctx do
      # A rule that would complete their card the moment it ran.
      then = DateTime.add(DateTime.utc_now(:second), -10 * 24 * 3600, :second)

      Repo.update_all(from(c in Card, where: c.id == ^ctx.their_card.id),
        set: [updated_at: then, inserted_at: then]
      )

      rule =
        rule_fixture(ctx.theirs, %{
          "trigger" => %{"type" => "card_stale", "days" => 7},
          "actions" => [%{"type" => "complete_card"}]
        })

      %{rule: rule}
    end

    test "can't be run, toggled or deleted from another board", ctx do
      panel = automations_panel(ctx.conn, ctx.mine)
      id = to_string(ctx.rule.id)

      render_hook(panel, "run_rule", %{"id" => id})
      render_hook(panel, "toggle_rule", %{"id" => id})
      render_hook(panel, "delete_rule", %{"id" => id})

      rule = Repo.get!(Slipdock.Automations.Rule, ctx.rule.id)
      assert rule.enabled == ctx.rule.enabled
      refute Repo.get!(Card, ctx.their_card.id).completed
    end

    test "still work on your own board", ctx do
      mine =
        rule_fixture(ctx.mine, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "complete_card"}]
        })

      panel = automations_panel(ctx.conn, ctx.mine)

      render_hook(panel, "toggle_rule", %{"id" => to_string(mine.id)})
      refute Repo.get!(Slipdock.Automations.Rule, mine.id).enabled

      render_hook(panel, "delete_rule", %{"id" => to_string(mine.id)})
      refute Repo.get(Slipdock.Automations.Rule, mine.id)
    end
  end

  defp handled_events(file) do
    handled =
      ~r/defp? (?:handle_)?event\(\s*"([a-z_]+)",/
      |> Regex.scan(File.read!("lib/slipdock_web/live/board_live/" <> file),
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.uniq()

    assert handled != []
    handled
  end

  describe "the guard" do
    test "every handle_event clause is in one of the event lists" do
      assert handled_events("show.ex") -- Show.known_events() == []
    end

    # Each of the board's LiveComponents keeps a list of its own, and refuses
    # anything not on it the same way.
    for {file, module} <- [
          {"automations_component.ex", SlipdockWeb.BoardLive.AutomationsComponent},
          {"sprint_component.ex", SlipdockWeb.BoardLive.SprintComponent},
          {"move_board_component.ex", SlipdockWeb.BoardLive.MoveBoardComponent},
          {"column_component.ex", SlipdockWeb.BoardLive.ColumnComponent},
          {"tags_component.ex", SlipdockWeb.BoardLive.TagsComponent},
          {"settings_component.ex", SlipdockWeb.BoardLive.SettingsComponent},
          {"archive_component.ex", SlipdockWeb.BoardLive.ArchiveComponent},
          {"card_component.ex", SlipdockWeb.BoardLive.CardComponent},
          {"page_component.ex", SlipdockWeb.BoardLive.PageComponent}
        ] do
      test "every handle_event clause in #{file} is in its event list" do
        assert handled_events(unquote(file)) -- unquote(module).events() == []
      end
    end

    test "an event in none of the lists is refused", ctx do
      view = board_view(ctx.conn, ctx.mine)
      assert render_hook(view, "sprint_whatever", %{}) =~ "isn&#39;t something this page can do"
    end

    test "only the owner archives the board", ctx do
      {:ok, _} = Access.grant(ctx.theirs, ctx.user, "write", ctx.victim)
      view = board_view(ctx.conn, ctx.theirs)

      # Board settings are the owner's panel; nobody else gets one to push to.
      refute has_element?(view, "#board-settings")
      assert render_hook(view, "archive_board", %{}) =~ "isn&#39;t something this page can do"
      refute Boards.get_board!(ctx.theirs.id).archived_at
    end

    test "a guest shown one card can't open the sprint charts", ctx do
      {:ok, template} = Boards.find_template("Sprint planning")
      sprints = board_fixture(%{"name" => "Sprints"}, template: template, owner: ctx.victim)
      {:ok, sprint} = Sprints.create_sprint(sprints)
      {:ok, _} = Access.grant(Boards.get_card!(sprint.id), ctx.user, "read", ctx.victim)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{sprints}/cards/#{sprint.id}")
      refute has_element?(view, "#sprint-charts")
      view |> with_target("#board-sprints") |> render_hook("open_sprint_charts", %{})
      refute has_element?(view, "#velocity-chart")
    end
  end
end
