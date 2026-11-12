defmodule Slipdock.NarrativeTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  alias Slipdock.{Boards, Narrative}
  alias Slipdock.Swimlanes.Config

  test "the range comes from explicit dates or the span" do
    today = ~D[2030-01-15]
    config = Config.defaults("narrative")
    assert Narrative.range(config, today) == {~D[2030-01-02], ~D[2030-01-15]}
    assert Narrative.range(%{config | span: "7"}, today) == {~D[2030-01-09], ~D[2030-01-15]}

    assert Narrative.range(%{config | from: "2030-01-01", to: "2030-01-10"}, today) ==
             {~D[2030-01-01], ~D[2030-01-10]}

    # A backwards range is turned around.
    assert Narrative.range(%{config | from: "2030-01-10", to: "2030-01-01"}, today) ==
             {~D[2030-01-01], ~D[2030-01-10]}
  end

  test "events are told under the top-level card, subcards included, respecting the view's filters" do
    %{board: board, epic: epic, sub: sub, loose: loose, late: late} = tree_fixture()
    user = user_fixture()
    [todo | _] = sub.columns

    {:ok, _} =
      Boards.StatusUpdates.add_status_update(epic, user, %{
        "health" => "at_risk",
        "body" => "Vendor late"
      })

    {:ok, _} = Boards.Comments.add_comment(loose, "Parked for now")
    sub_card = card_fixture(todo, %{"title" => "New subtask"})
    {:ok, _} = Boards.Cards.toggle_completed(sub_card)

    {:ok, _} =
      Boards.Milestones.create_milestone(board, %{
        "name" => "Launch",
        "date" => Date.to_iso8601(Date.utc_today())
      })

    today = Date.utc_today()
    narrative = Narrative.build(reload(board), Config.defaults("narrative"), today)

    assert narrative.from == Date.add(today, -13)
    assert narrative.to == today
    [group] = narrative.groups
    refute narrative.grouped
    stories = Map.new(group.cards, &{&1.card.title, &1})

    epic_story = stories["Epic"]
    assert epic_story.changed?
    kinds = Enum.map(epic_story.events, & &1.kind)
    assert :created in kinds and :status in kinds and :completed in kinds
    assert Enum.any?(epic_story.events, &(&1.message =~ "New subtask" and not &1.own?))
    assert Enum.any?(epic_story.events, &(&1.message =~ "at risk: Vendor late"))

    assert Enum.any?(stories["Loose"].events, &(&1.kind == :comment))
    assert narrative.summary.status_updates == 1
    assert narrative.summary.comments == 1
    assert narrative.summary.changed == group.total
    assert [%{name: "Launch"}] = narrative.milestones.passed
    assert Enum.any?(narrative.board_events, &(&1.message =~ "Launch"))

    # Filters narrow the story: only the overdue card.
    filtered = Narrative.build(reload(board), %{Config.defaults("narrative") | q: "late"}, today)
    assert [%{cards: [%{card: %{id: id}}]}] = filtered.groups
    assert id == late.id

    # Grouping by list splits the story.
    grouped =
      Narrative.build(reload(board), %{Config.defaults("narrative") | rows: "column"}, today)

    assert grouped.grouped
    assert length(grouped.groups) >= 1

    # A range before anything happened has no events, but still lists the cards as unchanged.
    quiet =
      Narrative.build(
        reload(board),
        %{Config.defaults("narrative") | from: "2020-01-01", to: "2020-01-31"},
        today
      )

    assert quiet.summary.changed == 0
    assert quiet.summary.cards == group.total
  end

  test "at risk now counts the cards reported at risk or off track, not the ones on track" do
    board = board_fixture()
    [backlog | _] = board.columns
    user = user_fixture()

    for {title, health} <- [
          {"Slipping", "at_risk"},
          {"Stuck", "off_track"},
          {"Fine", "on_track"},
          {"Quiet", nil},
          {"Silent", nil}
        ] do
      card = card_fixture(backlog, %{"title" => title})

      if health,
        do:
          {:ok, _} =
            Boards.StatusUpdates.add_status_update(card, user, %{
              "health" => health,
              "body" => "Now"
            })
    end

    narrative = Narrative.build(reload(board), Config.defaults("narrative"), Date.utc_today())

    assert narrative.summary.cards == 5
    assert narrative.summary.at_risk_now == 2
  end

  test "the tell list picks which events are told, and comment text can come along" do
    %{board: board, loose: loose, sub: sub} = tree_fixture()
    today = Date.utc_today()
    {:ok, _} = Boards.Cards.update_card(loose, %{"start_date" => Date.to_iso8601(today)})

    {:ok, _} =
      Boards.Cards.update_card(loose, %{"due_date" => Date.to_iso8601(Date.add(today, 3))})

    {:ok, _} = Boards.Comments.add_comment(loose, "First thought")
    {:ok, _} = Boards.Comments.add_comment(loose, "Second thought ![i](/attachments/1/i.png)")
    [todo | _] = sub.columns
    _subtask = card_fixture(todo, %{"title" => "Subtask under epic"})

    story = fn config ->
      n = Narrative.build(reload(board), config, today)
      [group] = n.groups
      {n, Map.new(group.cards, &{&1.card.title, &1})}
    end

    # Everything on (the default, minus the summary section): both comments
    # stay, with their text; start and due changes are separate kinds.
    {n, stories} = story.(Config.defaults("narrative"))
    kinds = Enum.map(stories["Loose"].events, & &1.kind)
    assert Enum.count(kinds, &(&1 == :comment)) == 2
    assert :start in kinds and :due in kinds
    assert n.summary.scheduled == 2

    assert Enum.map(Enum.filter(stories["Loose"].events, &(&1.kind == :comment)), & &1.body) ==
             ["First thought", "Second thought ![i](/attachments/1/i.png)"]

    assert Enum.any?(stories["Epic"].events, &(&1.message =~ "Subtask under epic"))
    assert MapSet.member?(n.tell, "board")
    refute MapSet.member?(n.tell, "summary")

    # Without start dates, comment text and subcard events.
    tell = Config.tell_keys() -- ~w(start comment_text subcards summary)
    {n, stories} = story.(%{Config.defaults("narrative") | tell: tell})
    kinds = Enum.map(stories["Loose"].events, & &1.kind)
    refute :start in kinds
    assert :due in kinds
    assert n.summary.scheduled == 1
    assert Enum.all?(stories["Loose"].events, &is_nil(&1[:body]))
    refute Enum.any?(stories["Epic"].events, &(&1.message =~ "Subtask under epic"))
    assert Enum.all?(stories["Epic"].events, & &1.own?)

    # Only comments: cards with nothing but other events read as unchanged,
    # and board changes are dropped.
    {n, stories} = story.(%{Config.defaults("narrative") | tell: ~w(comments)})
    assert stories["Loose"].changed?
    refute stories["Epic"].changed?
    assert n.summary.changed == 1
    assert n.board_events == []
    assert Enum.all?(stories["Loose"].events, &(&1.kind == :comment))
  end

  test "tell is part of the config: cast, ordered, saved and encoded" do
    config = Config.from_query(%{"tell" => "summary,bogus,created"}, Config.defaults("narrative"))
    assert config.tell == ~w(created summary)
    assert Config.tells?(config, "summary")
    refute Config.tells?(config, "moved")
    assert Config.to_map(config)["tell"] == ~w(created summary)
    assert {:tell, "created,summary"} in Config.to_query(config, Config.defaults("narrative"))

    # A form with the chooser sends an empty marker, so unticking everything sticks.
    assert Config.from_form(%{"tell" => [""]}, config).tell == []
    # A form without the chooser leaves it alone.
    assert Config.from_form(%{"rows" => "column"}, config).tell == ~w(created summary)
  end

  describe "lines/2" do
    @title "Dark mode for the dashboard"
    @at ~U[2030-03-04 09:00:00Z]

    # An event as build/3 makes it: on the card itself unless `card_id` says
    # a subcard, today unless `at` says otherwise, by nobody known.
    defp ev(kind, message, opts \\ []) do
      at = Keyword.get(opts, :at, @at)
      card_id = Keyword.get(opts, :card_id, 1)

      %{
        id: System.unique_integer([:positive]),
        at: at,
        date: DateTime.to_date(at),
        kind: kind,
        message: message,
        card_id: card_id,
        own?: card_id == 1,
        actor: Keyword.get(opts, :actor)
      }
    end

    defp messages(lines), do: Enum.map(lines, & &1.message)

    test "a single line drops the card's title" do
      assert messages(
               Narrative.lines([ev(:edited, "set Confidence on “#{@title}” to 80%")], @title)
             ) ==
               ["set Confidence to 80%"]

      assert messages(
               Narrative.lines(
                 [
                   ev(:created, "added “#{@title}” to Backlog"),
                   ev(:moved, "moved “#{@title}” from Backlog to Doing"),
                   ev(:comment, "commented on “#{@title}”"),
                   ev(:completed, "completed “#{@title}”")
                 ],
                 @title
               )
             ) == [
               "added it to Backlog",
               "moved it from Backlog to Doing",
               "commented",
               "completed it"
             ]
    end

    test "a lone field change stays as it was, unfolded" do
      [line] = Narrative.lines([ev(:due, "set due date on “#{@title}” to 2030-03-09")], @title)
      assert line.message == "set due date to 2030-03-09"
      assert line.kind == :due
      refute Map.has_key?(line, :folded)
    end

    test "consecutive field changes by one actor on one day are one line" do
      events = [
        ev(:edited, "set Reach on “#{@title}” to 4000 people"),
        ev(:edited, "set Impact on “#{@title}” to 3", at: ~U[2030-03-04 09:01:00Z]),
        ev(:edited, "set Confidence on “#{@title}” to 80%", at: ~U[2030-03-04 15:00:00Z]),
        ev(:edited, "set Effort on “#{@title}” to 3 weeks", at: ~U[2030-03-04 23:59:00Z])
      ]

      assert [line] = Narrative.lines(events, @title)
      assert line.message == "set Reach 4000 people, Impact 3, Confidence 80%, Effort 3 weeks"
      assert line.kind == :edited
      # It carries the first change's time and the changes it stands for.
      assert line.at == @at
      assert length(line.folded) == 4
    end

    test "mixed sequences fold only the runs between other events" do
      events = [
        ev(:created, "added “#{@title}” to Backlog"),
        ev(:edited, "set Reach on “#{@title}” to 4000 people"),
        ev(:edited, "set Impact on “#{@title}” to 3"),
        ev(:comment, "commented on “#{@title}”"),
        ev(:edited, "set Effort on “#{@title}” to 3 weeks"),
        # A cleared field isn't a "set": it stands alone and breaks the run.
        ev(:edited, "cleared Confidence on “#{@title}”"),
        ev(:due, "set due date on “#{@title}” to 2030-03-09"),
        ev(:start, "set start date on “#{@title}” to 2030-03-05")
      ]

      assert messages(Narrative.lines(events, @title)) == [
               "added it to Backlog",
               "set Reach 4000 people, Impact 3",
               "commented",
               "set Effort to 3 weeks",
               "cleared Confidence",
               "set due date 2030-03-09, start date 2030-03-05"
             ]
    end

    test "changes on different days or by different actors stay apart" do
      events = [
        ev(:edited, "set Reach on “#{@title}” to 10"),
        ev(:edited, "set Impact on “#{@title}” to 3", at: ~U[2030-03-05 00:00:00Z]),
        ev(:edited, "set Effort on “#{@title}” to 1 weeks",
          at: ~U[2030-03-05 01:00:00Z],
          actor: {7, "human", nil}
        ),
        ev(:edited, "set Confidence on “#{@title}” to 50%",
          at: ~U[2030-03-05 02:00:00Z],
          actor: {7, "human", nil}
        )
      ]

      assert messages(Narrative.lines(events, @title)) == [
               "set Reach to 10",
               "set Impact to 3",
               "set Effort 1 weeks, Confidence 50%"
             ]
    end

    test "a subcard's lines keep its name, and fold only with the same subcard" do
      events = [
        ev(:edited, "set Reach on “#{@title}” to 1"),
        ev(:edited, "set Reach on “Wire it up” to 2", card_id: 2),
        ev(:edited, "set Impact on “Wire it up” to 3", card_id: 2),
        ev(:edited, "set Impact on “Move to cloud” to 1", card_id: 3)
      ]

      assert [own, sub, other] = Narrative.lines(events, @title)
      assert own.message == "set Reach to 1"
      assert sub.message == "set on “Wire it up”: Reach 2, Impact 3"
      refute sub.own?
      # A title with " to " in it still parses.
      assert other.message == "set Impact on “Move to cloud” to 1"
    end

    test "nothing to tell, no title, or a message that only looks like a change" do
      assert Narrative.lines([], @title) == []

      # Without a title the messages are left alone.
      assert messages(Narrative.lines([ev(:completed, "completed “X”")], nil)) == [
               "completed “X”"
             ]

      assert messages(Narrative.lines([ev(:completed, "completed “X”")], "")) == ["completed “X”"]

      # "set" with no " to " or no value, and "set" on a kind that isn't a
      # field (a status update), don't fold.
      events = [
        ev(:edited, "set flags"),
        ev(:edited, "set Reach to "),
        ev(:status, "set status to at risk"),
        ev(:status, "set status to on track")
      ]

      assert length(Narrative.lines(events, @title)) == 4
    end
  end

  test "build/3 events carry the log's actor and fold in lines/2" do
    board = board_fixture(%{"name" => "Folding"})
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Dark mode"})
    {:ok, _} = Slipdock.Fields.install_preset(board, "rice")
    board = reload(board)

    for {f, v} <- Enum.zip(Enum.take(board.fields, 3), ["4000", "3", "80"]) do
      {:ok, _} = Slipdock.Fields.set_value(Boards.Cards.get_card!(card.id), f, v)
    end

    narrative = Narrative.build(reload(board), Config.defaults("narrative"), Date.utc_today())
    [%{cards: cards}] = narrative.groups
    story = Enum.find(cards, &(&1.card.id == card.id))

    assert Enum.all?(story.events, &Map.has_key?(&1, :actor))
    # Nobody set an actor in the test's process, so every entry is the
    # system's (#1735): one actor, so the field changes fold.
    assert story.events |> Enum.map(& &1.actor) |> Enum.uniq() == [{nil, "system", nil}]
    # build/3 still tells each change with the title, for its other callers.
    assert Enum.any?(story.events, &(&1.message == "set Reach on “Dark mode” to 4000 people"))

    assert messages(Narrative.lines(story.events, "Dark mode")) == [
             "added it to Backlog",
             "set Reach 4000 people, Impact 3, Confidence 80%"
           ]
  end
end
