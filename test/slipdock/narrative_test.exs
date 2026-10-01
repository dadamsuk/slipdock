defmodule Slipdock.NarrativeTest do
  use Slipdock.DataCase, async: false

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
      Boards.add_status_update(epic, user, %{"health" => "at_risk", "body" => "Vendor late"})

    {:ok, _} = Boards.add_comment(loose, "Parked for now")
    sub_card = card_fixture(todo, %{"title" => "New subtask"})
    {:ok, _} = Boards.toggle_completed(sub_card)

    {:ok, _} =
      Boards.create_milestone(board, %{
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

  test "the tell list picks which events are told, and comment text can come along" do
    %{board: board, loose: loose, sub: sub} = tree_fixture()
    today = Date.utc_today()
    {:ok, _} = Boards.update_card(loose, %{"start_date" => Date.to_iso8601(today)})
    {:ok, _} = Boards.update_card(loose, %{"due_date" => Date.to_iso8601(Date.add(today, 3))})
    {:ok, _} = Boards.add_comment(loose, "First thought")
    {:ok, _} = Boards.add_comment(loose, "Second thought ![i](/attachments/1/i.png)")
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
end
