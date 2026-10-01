defmodule Slipdock.RoadmapViewsTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Coloring, Table, Timeline}
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes.Config

  describe "dependency conflicts" do
    setup do
      board = board_fixture()
      [col | _] = board.columns

      blocker =
        card_fixture(col, %{
          "title" => "Design",
          "start_date" => "2030-01-01",
          "due_date" => "2030-01-20"
        })

      blocked =
        card_fixture(col, %{
          "title" => "Build",
          "start_date" => "2030-01-10",
          "due_date" => "2030-01-30"
        })

      fine = card_fixture(col, %{"title" => "Ship", "start_date" => "2030-02-01"})
      {:ok, _} = Boards.add_dependency(blocked, blocker)
      {:ok, _} = Boards.add_dependency(fine, blocker)
      %{board: reload(board), blocker: blocker, blocked: blocked, fine: fine}
    end

    test "a card that starts before its blocker is done is a violation", ctx do
      blocked = Boards.get_card!(ctx.blocked.id)
      fine = Boards.get_card!(ctx.fine.id)
      assert [%{id: id}] = Card.violated_blockers(blocked)
      assert id == ctx.blocker.id
      assert Card.violated_blockers(fine) == []

      # Done blockers no longer conflict.
      {:ok, _} = Boards.toggle_completed(ctx.blocker)
      assert Card.violated_blockers(Boards.get_card!(ctx.blocked.id)) == []
    end

    test "the timeline lists links between visible bars and marks the violated one", ctx do
      config = %{Config.defaults("timeline") | unit: "month"}
      timeline = Timeline.build(ctx.board, config, ~D[2030-01-15])

      links = Enum.sort_by(timeline.links, & &1.to)
      assert [%{from: b1, to: t1, violated: true}, %{from: b2, to: t2, violated: false}] = links
      assert {b1, t1} == {ctx.blocker.id, ctx.blocked.id}
      assert {b2, t2} == {ctx.blocker.id, ctx.fine.id}
    end

    test "the 'dates conflict' filter keeps only violated cards", ctx do
      config = %{Config.defaults("table") | deps: "violated"}
      rows = Table.rows(ctx.board, config, ~D[2030-01-15])
      assert [%{cards: [%{title: "Build"}]}] = rows.groups
    end
  end

  describe "colour by" do
    test "each colouring picks a palette colour and has a legend" do
      board = board_fixture()
      [col | _] = board.columns
      tag = tag_fixture(board, "Infra", "teal")
      card = card_fixture(col, %{"title" => "X", "priority" => "high", "color" => "rose"})
      {:ok, _} = Boards.toggle_card_tag(card, tag)
      board = reload(board)
      card = board.columns |> hd() |> Map.fetch!(:cards) |> hd()

      assert Coloring.color(card, "cover", board) == "rose"
      assert Coloring.color(card, "priority", board) == "orange"
      assert Coloring.color(card, "tag", board) == "teal"
      assert Coloring.color(card, "health", board) == "sky"
      assert is_binary(Coloring.color(card, "column", board))
      assert is_nil(Coloring.color(card, "assignee", board))
      assert is_nil(Coloring.color(card, "stated", board))

      assert [{"teal", "Infra"}] = Coloring.legend(board, "tag")
      assert length(Coloring.legend(board, "column")) == 4
      assert Coloring.legend(board, "cover") == []
    end

    test "colour_by survives a round trip through query and stored config" do
      config = Config.from_query(%{"color_by" => "health"}, Config.defaults("timeline"))
      assert config.color_by == "health"
      assert Config.from_map(Config.to_map(config)).color_by == "health"
      assert Config.from_query(%{"color_by" => "bogus"}).color_by == "cover"
    end
  end

  describe "status updates" do
    test "the latest update is the card's stated health and rolls up" do
      board = board_fixture()
      [col | _] = board.columns
      user = user_fixture()
      card = card_fixture(col, %{"title" => "Thing"})

      assert {:ok, _} =
               Boards.add_status_update(card, user, %{
                 "health" => "at_risk",
                 "body" => "Vendor late"
               })

      assert {:ok, _} =
               Boards.add_status_update(card, user, %{"health" => "on_track", "body" => ""})

      card = Boards.get_card!(card.id)
      assert Card.stated_health(card) == "on_track"

      assert [%{health: "on_track", body: nil}, %{health: "at_risk", body: "Vendor late"}] =
               card.status_updates

      assert card.rollup.stated == "on_track"
      assert Boards.latest_stated_health([card.id]) == %{card.id => "on_track"}

      assert {:error, _} = Boards.add_status_update(card, user, %{"health" => "meh"})

      [activity | _] = Boards.list_activities(board.id)
      assert activity.kind == "status"
      assert activity.message =~ "on track"
    end
  end

  describe "published views" do
    test "publishing gives a token that finds the view and its board; unpublishing withdraws it" do
      board = board_fixture()

      {:ok, view} =
        Boards.create_saved_view(board, %{"name" => "Roadmap", "config" => %{"mode" => "table"}})

      assert is_nil(view.public_token)
      assert Boards.get_published_view("nope") == nil

      {:ok, view} = Boards.publish_saved_view(view)
      assert String.length(view.public_token) > 16
      found = Boards.get_published_view(view.public_token)
      assert found.id == view.id
      assert found.board.id == board.id

      {:ok, _} = Boards.unpublish_saved_view(view)
      assert Boards.get_published_view(view.public_token) == nil
    end
  end

  describe "csv export" do
    test "the table becomes CSV with the visible fields, escaped" do
      board = board_fixture()
      [col | _] = board.columns

      card_fixture(col, %{
        "title" => ~s(Say "hi", please),
        "priority" => "high",
        "due_date" => "2030-03-01"
      })

      card_fixture(col, %{"title" => "Plain"})

      csv =
        Table.csv(reload(board), %{
          Config.defaults("table")
          | fields: ~w(title priority due_date completed)
        })

      [header, one, two, ""] = String.split(csv, "\r\n")
      assert header == "Title,Priority,Due,Done"
      assert one == ~s("Say ""hi"", please",high,2030-03-01,no)
      assert two == "Plain,none,,no"

      grouped =
        Table.csv(reload(board), %{Config.defaults("table") | rows: "priority", fields: ~w(title)})

      assert String.starts_with?(grouped, "Group,Title\r\nHigh,")
    end
  end
end
