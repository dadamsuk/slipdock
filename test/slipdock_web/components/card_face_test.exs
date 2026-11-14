defmodule SlipdockWeb.Components.CardFaceTest do
  @moduledoc """
  What a card's front draws, facet by facet, at both densities: each element
  is drawn when it is switched on and the card has something for it, and not
  otherwise. The cards are built in memory, so nothing here reads the
  database.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Attachment
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.ChecklistItem
  alias Slipdock.Boards.Comment
  alias Slipdock.Boards.Handoff
  alias Slipdock.Boards.StatusUpdate
  alias Slipdock.Boards.Tag
  alias Slipdock.Boards.Wait
  alias Slipdock.CardState
  alias Slipdock.Recurrence.Series
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.SlipdockComponents

  @user %User{id: 5, email: "ann@example.com", name: "Ann Example"}

  defp base do
    %Card{
      id: 12,
      board_id: 3,
      title: "A plain card",
      tags: [],
      assignees: [],
      assignee: nil,
      blocks: [],
      blocked_by: [],
      checklist_items: [],
      comments: [],
      attachments: [],
      sub_board: nil,
      handoff: nil,
      wait: nil,
      recurrence: nil,
      status_updates: [],
      rollup: nil,
      flags: [],
      priority: "none"
    }
  end

  defp day(n), do: Date.add(Date.utc_today(), n)

  defp image,
    do: %Attachment{id: 1, filename: "plan.png", content_type: "image/png", key: "k/1", size: 10}

  defp note,
    do: %Attachment{
      id: 2,
      filename: "notes.txt",
      content_type: "text/plain",
      key: "k/2",
      size: 10
    }

  # Each facet: the key that switches it on, a card that has something for
  # it, a selector only that facet draws, and the densities that draw it.
  defp facets, do: look_facets() ++ plan_facets() ++ content_facets()

  defp look_facets do
    [
      {"borders", %{base() | border_top: "sky"}, ~s([data-role="card-borders"] [data-edge="top"]),
       [false, true]},
      {"images", %{base() | attachments: [image()]}, ~s([data-role="card-image"]), [false, true]},
      {"status", %{base() | status_updates: [%StatusUpdate{id: 1, health: "at_risk"}]},
       ~s([title="Reported at risk"]), [false, true]},
      {"status", base(), ~s([data-role="complete-toggle"]), [false, true]},
      {"flags", %{base() | flags: ["blocked"]}, ~s([data-role="flag"][data-flag="blocked"]),
       [false, true]},
      {"priority", %{base() | priority: "high"}, ~s([data-role="priority"][data-priority="high"]),
       [false, true]}
    ]
  end

  defp plan_facets do
    [
      {"assignee", %{base() | assignees: [@user]}, ~s([title="Assigned to Ann Example"]),
       [false, true]},
      {"assignee",
       %{base() | state: %CardState{loop: %{runner: "Builder", kind: "build", job_id: 44}}},
       ~s(#card-12-loop[data-loop-job="44"]), [false, true]},
      {"start_date", %{base() | start_date: day(3)}, ~s([data-role="start"]), [false, true]},
      {"due_date", %{base() | due_date: day(30)}, ~s([title^="Due "]), [false, true]},
      {"percent_complete", %{base() | percent_complete: 40}, ~s([title="40% complete"]),
       [false, true]},
      {"time", %{base() | time_spent: 90}, ~s([title*=" spent"]), [false, true]},
      {"dependencies", %{base() | blocks: [%Card{id: 13, title: "Next"}]},
       ~s([title="Blocks Next"]), [false, true]},
      {"dependencies", %{base() | blocked_by: [%Card{id: 14, title: "First"}]},
       ~s([title="Blocked by: First"]), [false, true]},
      {"subcards",
       %{base() | sub_board: %Board{id: 77}, rollup: %{depth: 1, done: 1, total: 3, children: 3}},
       ~s([title^="1 of 3 subcards done"]), [false, true]}
    ]
  end

  defp content_facets do
    [
      {"checklist", %{base() | checklist_items: [%ChecklistItem{id: 1, done: true}]},
       ~s([title="Checklist"]), [false]},
      {"description", %{base() | description: "Some words"}, ~s([title="Has description"]),
       [false]},
      {"comments", %{base() | comments: [%Comment{id: 1}]}, ~s([title="Comments"]), [false]},
      {"attachments", %{base() | attachments: [note()]}, ~s([title="Attachments"]), [false]},
      {"age", %{base() | state: %CardState{age: 7200, known: true}}, ~s([data-role="age-chip"]),
       [false, true]}
    ]
  end

  defp render_card(card, show, opts \\ []) do
    assigns = Keyword.merge([card: card, show: show], opts)

    (&SlipdockComponents.card/1)
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end

  defp drawn?(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count() > 0

  defp text(html, selector),
    do: html |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp every_key,
    do: Enum.uniq(Config.facet_keys() ++ Config.marks_on() ++ ~w(id borders favourite))

  describe "each facet" do
    test "is drawn when it is on and the card has it" do
      for {key, card, selector, densities} <- facets(), compact <- densities do
        assert drawn?(render_card(card, [key], compact: compact), selector),
               "#{key} should draw #{selector} (compact: #{compact})"
      end
    end

    test "is not drawn when it is off, whatever else is on" do
      for {key, card, selector, densities} <- facets(), compact <- densities do
        refute drawn?(render_card(card, every_key() -- [key], compact: compact), selector),
               "#{selector} should need #{key} (compact: #{compact})"
      end
    end

    test "is not drawn for a card with nothing to show for it" do
      for {key, _card, selector, densities} <- facets(),
          selector != ~s([data-role="complete-toggle"]),
          compact <- densities do
        refute drawn?(render_card(base(), [key], compact: compact), selector),
               "#{selector} should need something on the card (compact: #{compact})"
      end
    end

    test "an empty description, medium priority and a card with no number draw nothing" do
      refute drawn?(
               render_card(%{base() | description: ""}, ["description"]),
               ~s([title="Has description"])
             )

      refute drawn?(
               render_card(%{base() | description: nil}, ["description"]),
               ~s([title="Has description"])
             )

      refute drawn?(
               render_card(%{base() | priority: "medium"}, ["priority"]),
               ~s([data-role="priority"])
             )
    end

    test "a card with no edge coloured has no borders drawn over it" do
      for compact <- [false, true] do
        refute drawn?(
                 render_card(base(), ["borders"], compact: compact),
                 ~s([data-role="card-borders"])
               )
      end
    end

    test "a card read without its state shows no age" do
      card = Map.delete(base(), :state)
      refute drawn?(render_card(card, ["age"]), ~s([data-role="age-chip"]))
    end
  end

  describe "the cover, the tags and the number" do
    test "the cover is the card's own colour, or the one asked for" do
      card = %{base() | color: "rose"}

      assert drawn?(render_card(card, ["cover"]), ~s(.bg-gradient-to-r.from-rose-200))

      assert drawn?(
               render_card(card, ["cover"], cover: "sky"),
               ~s(.bg-gradient-to-r.from-sky-200)
             )

      refute drawn?(render_card(card, []), ~s(.bg-gradient-to-r))
      refute drawn?(render_card(base(), ["cover"]), ~s(.bg-gradient-to-r))
    end

    test "the compact tile draws the cover as a dot" do
      card = %{base() | color: "rose"}
      dot = ~s(span.size-2.shrink-0.rounded-full)

      assert drawn?(render_card(card, ["cover"], compact: true), dot <> ".bg-rose-300")

      assert drawn?(
               render_card(card, ["cover"], compact: true, cover: "sky"),
               dot <> ".bg-sky-300"
             )

      refute drawn?(render_card(card, [], compact: true), dot)
    end

    test "the image is the first one the front may show, and only with the images element" do
      card = %{base() | attachments: [note(), image()]}

      assert LazyHTML.attribute(
               LazyHTML.query(render_card(card, ["images"]), ~s([data-role="card-image"])),
               "alt"
             ) == ["plan.png"]

      assert LazyHTML.attribute(
               LazyHTML.query(
                 render_card(card, ["images"], compact: true),
                 ~s([data-role="card-image"])
               ),
               "alt"
             ) == ["plan.png"]

      refute drawn?(render_card(card, ["attachments"]), ~s([data-role="card-image"]))
    end

    test "tags are chips on a comfortable card and dots on a compact one" do
      card = %{base() | tags: [%Tag{id: 1, name: "bug", color: "rose"}]}

      assert render_card(card, ["tags"]) |> LazyHTML.text() =~ "bug"
      refute render_card(card, []) |> LazyHTML.text() =~ "bug"

      assert drawn?(
               render_card(card, ["tags"], compact: true),
               ~s([title="bug"] span.bg-rose-300)
             )

      refute drawn?(render_card(card, [], compact: true), ~s([title="bug"]))

      refute drawn?(
               render_card(base(), ["tags"], compact: true),
               ~s(span.flex.shrink-0.items-center.gap-0\\.5)
             )
    end

    test "the number is drawn once, with the id element" do
      for compact <- [false, true] do
        html = render_card(base(), ["id"], compact: compact)
        assert text(html, ~s([data-role="card-id"])) == "#12"

        refute drawn?(
                 render_card(base(), every_key() -- ["id"], compact: compact),
                 ~s([data-role="card-id"])
               )
      end
    end

    test "the checklist counts what is done of what there is" do
      items = [%ChecklistItem{id: 1, done: true}, %ChecklistItem{id: 2, done: false}]
      html = render_card(%{base() | checklist_items: items}, ["checklist"])

      assert text(html, ~s([title="Checklist"])) == "1/2"
      assert drawn?(html, ~s([title="Checklist"].chip-line))

      all_done = render_card(%{base() | checklist_items: [hd(items)]}, ["checklist"])
      assert text(all_done, ~s([title="Checklist"])) == "1/1"
      assert drawn?(all_done, ~s([title="Checklist"].text-success))
    end
  end

  describe "start and due together" do
    test "both shown and both set draw as one range" do
      card = %{base() | start_date: day(-3), due_date: day(30)}

      for compact <- [false, true] do
        html = render_card(card, ["start_date", "due_date"], compact: compact)
        assert drawn?(html, ~s([data-role="date-range"]))
        refute drawn?(html, ~s([data-role="start"]))
        refute drawn?(html, ~s([title^="Due "]))
      end
    end

    test "one of them alone keeps its own badge" do
      card = %{base() | start_date: day(-3), due_date: day(30)}

      for compact <- [false, true] do
        start_only = render_card(card, ["start_date"], compact: compact)
        assert drawn?(start_only, ~s([data-role="start"]))
        refute drawn?(start_only, ~s([data-role="date-range"]))

        due_only = render_card(card, ["due_date"], compact: compact)
        assert drawn?(due_only, ~s([title^="Due "]))
        refute drawn?(due_only, ~s([data-role="date-range"]))

        unset = render_card(%{card | due_date: nil}, ["start_date", "due_date"], compact: compact)
        assert drawn?(unset, ~s([data-role="start"]))
        refute drawn?(unset, ~s([data-role="date-range"]))
      end
    end
  end

  describe "the meta row" do
    @meta ~s([data-role="card-meta"])

    test "is drawn when any facet in it is" do
      for {key, card, selector, _densities} <- facets(),
          key not in ~w(borders images),
          selector != ~s([data-role="complete-toggle"]) do
        assert drawn?(render_card(card, [key]), @meta), "#{key} should draw the meta row"
      end
    end

    test "is not drawn for what sits outside it" do
      rich = %{
        base()
        | color: "rose",
          border_top: "sky",
          attachments: [image()],
          tags: [%Tag{id: 1, name: "bug", color: "rose"}]
      }

      # `status` alone is the complete toggle, in the title row.
      for key <- ~w(cover borders images status tags id) do
        refute drawn?(render_card(rich, [key]), @meta),
               "#{key} alone should not draw the meta row"
      end

      refute drawn?(render_card(base(), every_key()), @meta)
    end

    test "is not drawn for the handoff note or the waiting line alone" do
      handoff = %Handoff{id: 1, next_step: "Write the test", body: "It was red"}
      left = %{base() | handoff: handoff}
      html = render_card(left, ["handoff_note"])

      assert drawn?(html, ~s([data-role="handoff-note"]))
      refute drawn?(html, @meta)

      item = %{card: %Card{id: 9002, title: "Theirs"}, reason: "wait", text: "A question"}
      waiting = %{base() | waiting_on_me: %{mine: [], others: [item]}}
      html = render_card(waiting, [])

      assert text(html, ~s(#card-12-waiting-line)) == "Waiting on someone else: 1"
      refute drawn?(html, @meta)
    end
  end

  describe "the marks" do
    defp marked do
      handoff = %Handoff{id: 1, next_step: "Write the test", body: "It was red"}
      wait = %Wait{id: 1, needs: "An answer", on_user: @user}
      series = %Series{rule: "FREQ=DAILY", starts_on: ~D[2026-01-05], next_on: ~D[2026-01-06]}
      state = %CardState{line: "Running the build", kind: "running", driver: "agent"}

      %{
        base()
        | handoff: handoff,
          wait: wait,
          recurrence: series,
          state: state,
          profile: "fix",
          profile_source: "inferred",
          snoozed_until: ~U[2030-03-04 09:00:00Z],
          snooze_note: "After the release"
      }
    end

    test "each is drawn from what the card carries, at both densities" do
      for compact <- [false, true] do
        html = render_card(marked(), nil, compact: compact, handoff_label: "Parked")

        assert LazyHTML.attribute(LazyHTML.query(html, ~s([data-role="handoff-mark"])), "title") ==
                 ["Parked — next: Write the test"]

        assert LazyHTML.attribute(LazyHTML.query(html, ~s([data-role="wait-mark"])), "title") ==
                 ["Waiting on Ann Example: An answer"]

        [repeats] =
          LazyHTML.attribute(LazyHTML.query(html, ~s([data-role="recurrence-mark"])), "title")

        assert repeats =~ "Repeats: "
        assert repeats =~ "next due"

        [snooze] =
          LazyHTML.attribute(LazyHTML.query(html, ~s([data-role="snooze-mark"])), "title")

        assert snooze =~ "After the release"

        assert LazyHTML.attribute(LazyHTML.query(html, ~s([data-role="state-line"])), "title") ==
                 ["Running the build"]

        assert drawn?(html, ~s([data-role="driver-mark"][data-driver="agent"]))
        assert drawn?(html, ~s([data-role="profile"][data-source="inferred"]))
        assert drawn?(html, ~s(.kanban-card.opacity-60))
      end
    end

    test "the repeat mark's title says when its series has ended or is paused (#3115)" do
      series = %Series{rule: "FREQ=DAILY", starts_on: ~D[2026-01-05], next_on: ~D[2026-01-06]}
      repeats = "Repeats: " <> Series.summary(series)

      for {s, expected} <- [
            {%{series | ended_at: ~U[2026-02-01 07:00:00Z], paused: true}, repeats <> " — ended"},
            {%{series | paused: true}, repeats <> " — paused"},
            {%{series | next_on: nil}, repeats}
          ],
          compact <- [false, true] do
        html = render_card(%{base() | recurrence: s}, nil, compact: compact)

        assert LazyHTML.attribute(
                 LazyHTML.query(html, ~s([data-role="recurrence-mark"])),
                 "title"
               ) ==
                 [expected]
      end
    end

    test "the age chip's title says how long, and whether that is known or usual (#3115)" do
      for {state, expected} <- [
            {%CardState{age: 7200, known: false},
             "In this list for at most 2h (its move here wasn't recorded)"},
            {%CardState{age: 7200, known: false, usual: 3600},
             "In this list for at most 2h (its move here wasn't recorded)"},
            {%CardState{age: 7200, known: true}, "In this list for 2h"},
            {%CardState{age: 7200, known: true, usual: 86_400},
             "In this list for 2h; usually 1d"},
            {%CardState{age: 7200, known: true, usual: 3600, over_usual: 3600},
             "In this list for 2h · 1h over usual; usually 1h"}
          ],
          compact <- [false, true] do
        html = render_card(%{base() | state: state}, ["age"], compact: compact)

        assert LazyHTML.attribute(LazyHTML.query(html, ~s([data-role="age-chip"])), "title") ==
                 [expected]
      end
    end

    test "the snoozed day is read in the reader's timezone" do
      card = %{base() | snoozed_until: ~U[2030-03-04 23:30:00Z]}

      for compact <- [false, true] do
        utc = text(render_card(card, nil, compact: compact), ~s([data-role="snooze-mark"]))

        tokyo =
          text(
            render_card(card, nil, compact: compact, zone: "Asia/Tokyo"),
            ~s([data-role="snooze-mark"])
          )

        assert utc =~ "4 Mar"
        assert tokyo =~ "5 Mar"
      end
    end

    test "none is drawn for a card that carries nothing" do
      for compact <- [false, true] do
        html = render_card(base(), nil, compact: compact)

        for role <-
              ~w(handoff-mark wait-mark recurrence-mark snooze-mark state-line driver-mark profile) do
          refute drawn?(html, ~s([data-role="#{role}"])), "#{role} on a plain card"
        end

        refute drawn?(html, ~s(.kanban-card.opacity-60))
      end
    end

    test "the handoff note is shown as the Display menu asks, on a comfortable card" do
      short = render_card(marked(), ["handoff_note"], handoff_label: "Parked")
      assert drawn?(short, ~s([data-role="handoff-note"][data-mode="short"]))
      assert text(short, ~s([data-role="handoff-note"])) =~ "Parked: Write the test"

      assert drawn?(
               render_card(marked(), ["handoff_full"]),
               ~s([data-role="handoff-note"][data-mode="full"])
             )

      assert drawn?(
               render_card(marked(), [], handoff_note: "full"),
               ~s([data-role="handoff-note"][data-mode="full"])
             )

      refute drawn?(render_card(marked(), []), ~s([data-role="handoff-note"]))
    end

    test "the heart is drawn for a favourite, with the favourite element" do
      marks = MapSet.new([{:card, 12}])

      for compact <- [false, true] do
        assert drawn?(
                 render_card(base(), ["favourite"], compact: compact, marks: marks),
                 ~s([data-role="favourite-mark"])
               )

        refute drawn?(
                 render_card(base(), [], compact: compact, marks: marks),
                 ~s([data-role="favourite-mark"])
               )

        refute drawn?(
                 render_card(base(), ["favourite"], compact: compact),
                 ~s([data-role="favourite-mark"])
               )

        refute drawn?(
                 render_card(base(), ["favourite"],
                   compact: compact,
                   marks: MapSet.new([{:card, 13}])
                 ),
                 ~s([data-role="favourite-mark"])
               )
      end
    end
  end

  describe "what waits on the reader" do
    defp waiting do
      item = %{card: %Card{id: 9001, title: "Region"}, reason: "wait", text: "Which one?"}
      %{base() | percent_complete: 57, waiting_on_me: %{mine: [item], others: []}}
    end

    test "the chip counts it and names it, at both densities" do
      for compact <- [false, true] do
        html = render_card(waiting(), ["percent_complete"], compact: compact)

        assert text(html, ~s(#card-12-waiting[data-role="waiting-chip"])) == "⏸ 1 waiting on you"

        assert LazyHTML.attribute(LazyHTML.query(html, "#card-12-waiting"), "title") ==
                 ["#9001 Region: Which one?"]

        refute drawn?(html, ~s([title="57% complete"]))
      end
    end

    test "the chip opens the sub-board kept to those cards" do
      card = %{waiting() | sub_board: %Board{id: 77}}

      for compact <- [false, true] do
        html = render_card(card, [], compact: compact)

        assert [click] =
                 LazyHTML.attribute(LazyHTML.query(html, "button#card-12-waiting"), "phx-click")

        assert click =~ "/boards/77?waiting=me"
      end
    end

    test "the line takes the percentage's place on a comfortable card" do
      html = render_card(waiting(), ["percent_complete"])
      assert text(html, ~s(#card-12-waiting-line.text-warning)) =~ "Waiting on you: #9001"

      quiet = render_card(%{waiting() | waiting_on_me: nil}, ["percent_complete"])
      assert drawn?(quiet, ~s([title="57% complete"]))
      refute drawn?(quiet, ~s([data-role="waiting-line"]))
      refute drawn?(quiet, ~s([data-role="waiting-chip"]))
    end
  end

  describe "the tile itself" do
    test "its ids are the card's, or the one asked for" do
      for compact <- [false, true] do
        html = render_card(base(), [], compact: compact)
        assert LazyHTML.attribute(LazyHTML.query(html, "#card-12"), "data-id") == ["12"]

        html = render_card(base(), [], compact: compact, id: "lane-2-card-12")
        assert LazyHTML.attribute(LazyHTML.query(html, "#lane-2-card-12"), "data-id") == ["12"]
        refute drawn?(html, "#card-12")
      end
    end

    test "the title, the complete toggle and the actions are in the title row" do
      actions = [%{__slot__: :actions, inner_block: fn _, _ -> "the menu" end}]

      for compact <- [false, true] do
        html = render_card(base(), ["status"], compact: compact, actions: actions)

        assert text(html, ~s([data-role="card-title"])) == "A plain card"

        assert LazyHTML.attribute(
                 LazyHTML.query(html, ~s([data-role="complete-toggle"])),
                 "title"
               ) == ["Mark complete"]

        assert text(html, ~s(span.-mr-1.shrink-0)) == "the menu"

        refute drawn?(render_card(base(), ["status"], compact: compact), ~s(span.-mr-1.shrink-0))

        done = render_card(%{base() | completed: true}, ["status"], compact: compact)

        assert LazyHTML.attribute(
                 LazyHTML.query(done, ~s([data-role="complete-toggle"])),
                 "title"
               ) == ["Mark incomplete"]
      end
    end

    test "a placed wiki page links to its document and has no number or toggle" do
      page =
        struct(Slipdock.Wiki.Page, Map.merge(Map.from_struct(base()), %{id: 7, slug: "a-page"}))

      marks = MapSet.new([{:page, 7}])

      for compact <- [false, true] do
        html = render_card(page, ["status", "id", "favourite"], compact: compact, marks: marks)

        assert LazyHTML.attribute(LazyHTML.query(html, "#page-7.kanban-page"), "data-id") == [
                 "page-7"
               ]

        assert LazyHTML.attribute(LazyHTML.query(html, ~s(a[title="Open the document"])), "href") ==
                 ["/boards/3/wiki/a-page"]

        refute drawn?(html, ~s([data-role="card-id"]))
        refute drawn?(html, ~s([data-role="complete-toggle"]))
        assert drawn?(html, ~s([data-role="favourite-mark"]))
      end

      for compact <- [false, true] do
        html = render_card(base(), ["status", "id"], compact: compact)
        refute drawn?(html, ~s(a[title="Open the document"]))
        refute drawn?(html, ".kanban-page")
      end
    end

    test "a page's subcards chip is not a button, a card's is" do
      sub = %{sub_board: %Board{id: 77}, rollup: %{depth: 1, done: 1, total: 3, children: 3}}

      page =
        struct(
          Slipdock.Wiki.Page,
          Map.merge(Map.from_struct(base()), Map.merge(sub, %{id: 7, slug: "a-page"}))
        )

      for compact <- [false, true] do
        assert drawn?(
                 render_card(Map.merge(base(), sub), ["subcards"], compact: compact),
                 ~s(button[title^="1 of 3 subcards done"])
               )

        assert drawn?(
                 render_card(page, ["subcards"], compact: compact),
                 ~s(span[title^="1 of 3 subcards done"])
               )
      end
    end
  end

  describe "the time chip and bar (#3112)" do
    # A 4h estimate, in minutes, and what is spent against it in each case.
    @estimate 240

    defp timed(spent, extra \\ %{}),
      do: Map.merge(%{base() | time_spent: spent, time_estimate: @estimate}, extra)

    defp render_fragment(fun, assigns),
      do: fun |> render_component(assigns) |> LazyHTML.from_fragment()

    defp badge(card), do: render_fragment(&SlipdockComponents.time_badge/1, card: card)
    defp bar(percent), do: render_fragment(&SlipdockComponents.time_bar/1, percent: percent)

    defp attr(html, selector, name),
      do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

    defp classes(html, selector), do: attr(html, selector, "class") |> String.split()

    test "with no estimate, the chip gives the time spent and draws no bar" do
      html = badge(%{base() | time_spent: 90})

      assert text(html, ".chip") == "1.5h"
      assert attr(html, ".chip", "title") == "1.5h spent"
      assert "chip-line" in classes(html, ".chip")
      refute drawn?(html, ~s([style^="width"]))
    end

    test "the chip gives spent/estimate, its percentage and its tint at each stage" do
      for {spent, label, percent, tint, fill} <- [
            {120, "2h/4h", 50, "chip-line", "bg-success"},
            {192, "3.2h/4h", 80, "bg-warning/15", "bg-warning"},
            {240, "4h/4h", 100, "bg-warning/15", "bg-warning"},
            {360, "6h/4h", 150, "bg-error/15", "bg-error"}
          ] do
        html = badge(timed(spent))
        [shown_spent, _] = String.split(label, "/")

        assert text(html, ".chip") == label

        assert attr(html, ".chip", "title") ==
                 "#{shown_spent} spent of 4h estimated (#{percent}%)"

        assert tint in classes(html, ".chip"), "#{percent}%: no #{tint}"
        assert fill in classes(html, ~s([style^="width"])), "#{percent}%: no #{fill}"

        assert attr(html, ~s([style^="width"]), "style") ==
                 "width: #{min(percent, 100)}%"
      end
    end

    test "under 80% the chip has neither the near nor the over tint" do
      chip = badge(timed(120)) |> classes(".chip")
      refute "bg-warning/15" in chip
      refute "bg-error/15" in chip
    end

    test "a running timer adds its time, says so in the title and pulses the clock" do
      started = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      html = badge(timed(90, %{timer_started_at: started}))

      assert text(html, ".chip") == "2h/4h"
      assert attr(html, ".chip", "title") == "2h spent of 4h estimated (50%) — timer running"
      assert "animate-pulse" in classes(html, ".hero-clock")
    end

    test "a stopped timer neither says it runs nor pulses" do
      html = badge(timed(120))

      refute attr(html, ".chip", "title") =~ "timer running"
      refute "animate-pulse" in classes(html, ".hero-clock")
    end

    test "the bar's fill, status and value at each stage, capped at 100%" do
      for {percent, status, fill} <- [
            {50, "under", "bg-success"},
            {80, "near", "bg-warning"},
            {100, "near", "bg-warning"},
            {150, "over", "bg-error"}
          ] do
        html = bar(percent)

        assert attr(html, ~s([role="progressbar"]), "data-status") == status
        assert attr(html, ~s([role="progressbar"]), "aria-valuenow") == "#{percent}"
        fill_style = "width: #{min(percent, 100)}%"
        assert attr(html, ~s([style^="width"]), "style") == fill_style
        assert fill in classes(html, ~s([style^="width"]))
      end
    end

    test "only an over-estimate bar draws the tick, at where the estimate fell" do
      for percent <- [50, 80, 100] do
        refute drawn?(bar(percent), ~s([title="Estimate"])), "#{percent}% drew a tick"
      end

      # 100 / 150 of the bar is the estimate: 66.7%.
      assert attr(bar(150), ~s([title="Estimate"]), "style") == "left: 66.7%"
      assert attr(bar(200), ~s([title="Estimate"]), "style") == "left: 50.0%"
      assert attr(bar(400), ~s([title="Estimate"]), "style") == "left: 25.0%"
    end
  end

  describe "opening an item (#2890)" do
    test "page_path/1 is a placed page's document, on its own board" do
      page = %Slipdock.Wiki.Page{id: 7, board_id: 3, slug: "a-page"}
      assert SlipdockComponents.page_path(page) == "/boards/3/wiki/a-page"
    end

    test "page_path/1 is for a page, not a card" do
      assert_raise FunctionClauseError, fn ->
        SlipdockComponents.page_path(%Card{id: 7, board_id: 3})
      end
    end

    test "open_item/1 opens a page's panel and a card's modal, by its id" do
      page = %Slipdock.Wiki.Page{id: 7, board_id: 3, slug: "a-page"}

      assert SlipdockComponents.open_item(page) ==
               Phoenix.LiveView.JS.push("open_page", value: %{id: 7})

      assert SlipdockComponents.open_item(%Card{id: 7}) ==
               Phoenix.LiveView.JS.push("open_card", value: %{id: 7})
    end

    test "item_id/1 tells a page from a card that shares its number" do
      assert SlipdockComponents.item_id(%Slipdock.Wiki.Page{id: 7}) == "page-7"
      assert SlipdockComponents.item_id(%Card{id: 7}) == "7"
    end
  end
end
