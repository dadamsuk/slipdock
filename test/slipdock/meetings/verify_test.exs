defmodule Slipdock.Meetings.VerifyTest do
  @moduledoc """
  Verification (#535): quotes checked word for word in code (G2), the two
  readings merged with their agreement as a signal, links checked and
  versioned, and every kind of question raised when — and only when — it
  should be. Signals are labels, never numbers.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Meetings.{Event, Finding, Question, Utterance, Verify, Version}

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: owner)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")
    %{owner: owner, board: board, sam: sam, capture: capture_fixture(board, owner)}
  end

  @decision %{
    "kind" => "decision",
    "title" => "Annual plan at 20% off",
    "topic" => "Pricing",
    "evidence" => [%{"line" => "L2", "quote" => "We go with the annual plan at 20% off."}]
  }

  defp with_readings(capture, first, second \\ nil, agent \\ nil, context \\ %{}) do
    capture
    |> Ecto.Changeset.change(
      readings: %{"1" => first, "2" => second, "agent" => agent},
      context: Map.merge(%{"candidates" => [], "decisions" => []}, context)
    )
    |> Repo.update!()
  end

  defp findings(capture),
    do:
      Repo.all(
        from(f in Finding,
          where: f.capture_id == ^capture.id,
          order_by: f.position,
          preload: [:evidence]
        )
      )

  defp questions(capture), do: Repo.all(from(q in Question, where: q.capture_id == ^capture.id))

  describe "word for word (G2)" do
    test "a quote in the transcript is kept, with exactly where it is", %{capture: capture} do
      capture =
        with_readings(capture, [
          put_in(@decision, ["evidence"], [
            %{"line" => "L2", "quote" => "the annual plan at 20% off"}
          ])
        ])

      {:ok, %{kept: 1, dropped: 0}} = Meetings.verify(capture)

      [f] = findings(capture)
      assert f.status == "kept"
      assert "quoted" in f.signals
      [e] = f.evidence

      assert {e.line_id, e.char_start, e.char_end, e.quote} ==
               {"L2", 11, 37, "the annual plan at 20% off"}

      assert e.speaker == "Sam" and e.start_ms == 4_000
    end

    test "a quote one word different is dropped, listed as dropped, and on the record", %{
      capture: capture
    } do
      wrong =
        put_in(@decision, ["evidence"], [
          %{"line" => "L2", "quote" => "We go with the monthly plan at 20% off."}
        ])

      capture = with_readings(capture, [wrong])

      {:ok, %{kept: 0, dropped: 1}} = Meetings.verify(capture)
      [f] = findings(capture)
      assert f.status == "dropped"
      refute f.included

      assert f.drop_reason ==
               "its quote is not in the transcript: “We go with the monthly plan at 20% off.” (L2)"

      assert Repo.exists?(
               from(e in Event, where: e.capture_id == ^capture.id and e.kind == "dropped")
             )
    end

    test "case, curly quotes, dashes, ellipses and spacing are forgiven; nothing else is" do
      text = "Let’s ship — the “annual” plan…  by Friday"
      assert {0, 12} = Verify.locate("let's ship -", text)
      assert {_, _} = Verify.locate("the \"annual\" plan... by friday", text)
      assert Verify.locate("Let's ship the annual plan", text) == nil
      assert Verify.locate("   ", text) == nil
      assert Verify.locate("ship it", "ship it now") == {0, 7}
    end

    test "a quote on a misnumbered line is found on its real line", %{capture: capture} do
      capture =
        with_readings(capture, [
          put_in(@decision, ["evidence"], [%{"line" => "L1", "quote" => "annual plan"}])
        ])

      {:ok, %{kept: 1}} = Meetings.verify(capture)
      assert [%{evidence: [%{line_id: "L2"}]}] = findings(capture)
    end

    test "one bad quote among good ones drops the finding", %{capture: capture} do
      two =
        put_in(@decision, ["evidence"], [
          %{"line" => "L2", "quote" => "annual plan"},
          %{"line" => "L4", "quote" => "No, that's yours"}
        ])

      capture = with_readings(capture, [two])
      assert {:ok, %{kept: 0, dropped: 1}} = Meetings.verify(capture)
    end
  end

  describe "two readings" do
    test "found by both is one finding, marked as agreed", %{capture: capture} do
      capture =
        with_readings(capture, [@decision], [Map.put(@decision, "title", "Go annual, 20% off")])

      {:ok, %{kept: 1}} = Meetings.verify(capture)
      [f] = findings(capture)
      assert f.readings == [1, 2]
      assert "both_readings" in f.signals
      assert length(f.evidence) == 1
    end

    test "found by only one is marked so", %{capture: capture} do
      capture = with_readings(capture, [@decision], [])
      {:ok, _} = Meetings.verify(capture)
      assert [%{signals: signals, readings: [1]}] = findings(capture)
      assert "one_reading" in signals
    end

    test "with the second reading off there is no agreement signal", %{capture: capture} do
      capture = with_readings(capture, [@decision])
      {:ok, _} = Meetings.verify(capture)
      [f] = findings(capture)
      refute "one_reading" in f.signals or "both_readings" in f.signals
    end

    test "readings that differ on a figure ask which reading", %{capture: capture} do
      capture =
        with_readings(capture, [Map.put(@decision, "title", "Annual plan at 15% off")], [
          Map.put(@decision, "title", "Annual plan at 50% off")
        ])

      {:ok, %{questions: 1}} = Meetings.verify(capture)

      [q] = questions(capture)
      assert q.kind == "which_reading"
      assert Enum.map(q.options, & &1["label"]) == ["15%", "50%", "Not decided"]
      assert "readings_differ" in hd(findings(capture)).signals
    end

    test "agent findings are checked the same way and marked as the agent's", %{capture: capture} do
      capture =
        with_readings(capture, [], nil, [
          @decision,
          put_in(@decision, ["evidence"], [%{"line" => "L9", "quote" => "made up"}])
        ])

      {:ok, %{kept: 1, dropped: 1}} = Meetings.verify(capture)
      [kept, dropped] = findings(capture)
      assert kept.origin == "agent" and "from_agent" in kept.signals
      assert dropped.origin == "agent" and dropped.status == "dropped"
    end
  end

  describe "owners" do
    @action %{
      "kind" => "action",
      "title" => "Update the pricing page",
      "due" => "fri",
      "due_date" => "2026-10-09",
      "evidence" => [%{"line" => "L3", "quote" => "can you update PL-14 by Friday?"}]
    }

    test "a member named is the assignee", %{capture: capture, sam: sam} do
      capture = with_readings(capture, [Map.put(@action, "owner", "Sam")])
      {:ok, %{questions: 0}} = Meetings.verify(capture)
      [f] = findings(capture)
      assert "owner_known" in f.signals
      assert f.effect["assignee_id"] == sam.id
      assert f.effect["due_date"] == "2026-10-09"
      assert f.effect["type"] == "new_card"
      assert f.effect["list"] == "To Do"
    end

    test "a name not on the board asks who is meant, offering the nearest members", %{
      capture: capture,
      sam: sam
    } do
      capture = with_readings(capture, [Map.put(@action, "owner", "Sammy")])
      {:ok, %{questions: 1}} = Meetings.verify(capture)

      [q] = questions(capture)
      assert q.kind == "who_is_meant"
      assert q.prompt =~ "“Sammy” isn't on this board"
      assert hd(q.options)["value"] == "user:#{sam.id}"
      assert List.last(q.options)["label"] == "Nobody yet"
      [f] = findings(capture)
      assert "owner_unknown" in f.signals

      # Optional: as it stands the card names Sammy, and nothing waits on it.
      refute q.blocking
      assert Enum.find(q.options, &(&1["value"] == "name:Sammy"))["label"] == "Keep “Sammy”"
      assert f.effect["assignee"] == "Sammy" and is_nil(f.effect["assignee_id"])
      assert Meetings.open_questions(capture) == []
    end

    test "two members answering to the name must be told apart before the commit", %{
      board: board,
      capture: capture,
      sam: sam
    } do
      other = user_fixture("sam.jones@example.com")
      {:ok, other} = Slipdock.Accounts.update_profile(other, %{"name" => "Sam Jones"})
      share_fixture(board, [other], "write")

      {:ok, _} = Meetings.verify(with_readings(capture, [Map.put(@action, "owner", "Sam")]))
      [q] = questions(capture)
      assert q.blocking

      users = for o <- q.options, String.starts_with?(o["value"], "user:"), do: o["value"]
      assert Enum.sort(users) == Enum.sort(["user:#{sam.id}", "user:#{other.id}"])
    end

    test "a name a person in the meeting has becomes theirs; a speaker label is nobody", %{
      board: board,
      owner: owner
    } do
      capture =
        capture_fixture(board, owner, %{transcript: "names #{System.unique_integer()}"},
          utterances: [
            %{speaker: "Priya Nair", text: "Ryan, send Nick the changes."},
            %{speaker: "Johnny Walsh", text: "I'll book the room."},
            %{speaker: "Unknown-3", text: "I can join full-time."}
          ]
        )

      act = fn owner, line, quote ->
        %{
          "kind" => "action",
          "title" => "Do #{owner}",
          "owner" => owner,
          "evidence" => [%{"line" => line, "quote" => quote}]
        }
      end

      {:ok, _} =
        Meetings.verify(
          with_readings(capture, [
            act.("Johnny", "L2", "I'll book the room."),
            act.("priya nair", "L1", "send Nick the changes"),
            act.("Unknown-3", "L3", "I can join full-time.")
          ])
        )

      [johnny, priya, label] = findings(capture)
      assert johnny.effect["assignee"] == "Johnny Walsh"
      assert priya.effect["assignee"] == "Priya Nair"
      assert is_nil(label.effect["assignee"])
      refute "owner_unknown" in label.signals

      qs = questions(capture)
      assert length(qs) == 2 and Enum.all?(qs, &(not &1.blocking))
      refute Enum.any?(qs, &(&1.finding_id == label.id))
    end

    test "who is meant also offers the people in the meeting whose name it is", %{
      board: board,
      owner: owner
    } do
      capture =
        capture_fixture(board, owner, %{transcript: "names #{System.unique_integer()}"},
          utterances: [
            %{speaker: "Priya Nair", text: "Johnny, can you send the deck?"},
            %{speaker: "Johnny Walsh", text: "Yes."},
            %{speaker: "Speaker 3", text: "Mm."}
          ]
        )
        |> Ecto.Changeset.change(attendees: [%{"name" => "Johnny Marr"}, %{"name" => "Sam"}])
        |> Repo.update!()

      action = %{
        "kind" => "action",
        "title" => "Send the deck",
        "owner" => "Johnny",
        "evidence" => [%{"line" => "L1", "quote" => "Johnny, can you send the deck?"}]
      }

      {:ok, _} = Meetings.verify(with_readings(capture, [action]))
      [q] = questions(capture)

      # After the members nearest the name: the meeting's own Johnnys.
      assert q.options
             |> Enum.map(& &1["value"])
             |> Enum.drop_while(&String.starts_with?(&1, "user:")) == [
               "name:Johnny Walsh",
               "name:Johnny Marr",
               "name:Johnny",
               "none"
             ]

      labels = Map.new(q.options, &{&1["value"], &1["label"]})
      assert labels["name:Johnny Walsh"] == "Johnny Walsh (in the meeting)"
      assert labels["name:Johnny"] == "Keep “Johnny”"
      # A one-word attendee or a "Speaker 3" label names nobody in particular.
      refute Map.has_key?(labels, "name:Sam")
    end
  end

  describe "links" do
    setup %{board: board, capture: capture} do
      card = card_fixture(hd(board.columns), %{"title" => "Pricing page refresh"})

      candidate = %{
        "type" => "card",
        "id" => card.id,
        "ref" => "##{card.id}",
        "title" => card.title,
        "version" => Version.of(card),
        "lines" => ["L3"],
        "summary" => nil
      }

      %{card: card, candidate: candidate, capture: capture}
    end

    test "a finding naming a card by id becomes a change to it, version kept", ctx do
      change = %{
        "kind" => "card_change",
        "title" => "Pricing page due Friday",
        "card" => "PL-#{ctx.card.id}",
        "change" => %{"field" => "due_date", "to" => "2026-10-09"},
        "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
      }

      capture =
        with_readings(ctx.capture, [change], nil, nil, %{
          "candidates" => [Map.put(ctx.candidate, "strength", "id")]
        })

      {:ok, %{questions: 0}} = Meetings.verify(capture)

      [f] = findings(capture)
      assert f.kind == "card_change"
      assert "linked_by_id" in f.signals
      assert [%{"id" => id, "version" => version, "strength" => "id"}] = f.links
      assert id == ctx.card.id and version == Version.of(ctx.card)
      assert f.effect["changes"] == %{"due_date" => "2026-10-09"}
      assert [%{"title" => "Pricing page refresh"}] = f.known
    end

    test "an action linked only by similarity asks existing card or new", ctx do
      action = %{
        "kind" => "action",
        "title" => "Refresh pricing",
        "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
      }

      capture =
        with_readings(ctx.capture, [action], nil, nil, %{
          "candidates" => [Map.put(ctx.candidate, "strength", "similarity")]
        })

      {:ok, %{questions: 1}} = Meetings.verify(capture)

      [q] = questions(capture)
      assert q.kind == "existing_or_new"
      assert Enum.map(q.options, & &1["value"]) == ["card:#{ctx.card.id}", "new", "none"]
      assert "linked_by_similarity" in hd(findings(capture)).signals
      # Only similar in meaning: a hint, and left alone it makes a new card.
      refute q.blocking
    end

    test "an action naming a card's title must say which before the commit", ctx do
      action = %{
        "kind" => "action",
        "title" => "Refresh pricing",
        "evidence" => [%{"line" => "L3", "quote" => "update PL-14 by Friday"}]
      }

      capture =
        with_readings(ctx.capture, [action], nil, nil, %{
          "candidates" => [Map.put(ctx.candidate, "strength", "name")]
        })

      {:ok, _} = Meetings.verify(capture)
      assert [%{kind: "existing_or_new", blocking: true}] = questions(capture)
    end

    test "a change to a card nobody read asks which card, offering those read", ctx do
      change = %{
        "kind" => "card_change",
        "title" => "Move it",
        "card" => "#999999",
        "evidence" => [%{"line" => "L1", "quote" => "settle the pricing page"}]
      }

      # The candidate sits on another line, so it isn't linked to this finding.
      capture =
        with_readings(ctx.capture, [change, Map.delete(change, "card")], nil, nil, %{
          "candidates" => [
            Map.merge(ctx.candidate, %{"strength" => "similarity", "lines" => ["L9"]})
          ]
        })

      {:ok, %{questions: 2}} = Meetings.verify(capture)
      [named, unnamed] = questions(capture)
      assert named.kind == "existing_or_new" and named.blocking
      assert named.prompt =~ "#999999 isn't one Slipdock read."
      assert unnamed.prompt =~ "It doesn't name one."
      assert hd(named.options)["value"] == "card:#{ctx.card.id}"
      assert hd(findings(capture)).links == []
    end

    test "a change to a card nobody can find, with none to offer, is shown left out", ctx do
      change = %{
        "kind" => "card_change",
        "title" => "CTO role is in transition",
        "evidence" => [%{"line" => "L1", "quote" => "settle the pricing page"}]
      }

      capture = with_readings(ctx.capture, [change])
      {:ok, %{questions: 0}} = Meetings.verify(capture)
      [f] = findings(capture)
      refute f.included
      assert "card_not_found" in f.signals
      assert f.effect["type"] == "new_card"

      assert [%{"why" => "about a card Slipdock couldn't find"}] =
               Slipdock.Meetings.Commit.build(Meetings.get_capture!(capture.id))["left_out"]
    end
  end

  describe "the wiki already knows" do
    test "an open question the wiki answers is left out, with the answer linked", %{
      capture: capture
    } do
      page = %{
        "type" => "page",
        "id" => 7,
        "ref" => "W-7",
        "title" => "Pricing principles",
        "summary" => "Annual only.",
        "strength" => "similarity",
        "lines" => ["L1"]
      }

      question = %{
        "kind" => "open_question",
        "title" => "Which plans do we sell?",
        "evidence" => [%{"line" => "L1", "quote" => "Let's settle the pricing page."}]
      }

      capture = with_readings(capture, [question], nil, nil, %{"candidates" => [page]})
      {:ok, _} = Meetings.verify(capture)

      [f] = findings(capture)
      refute f.included
      assert "answered_in_wiki" in f.signals
      assert [%{"ref" => "W-7", "answers" => true}] = f.known
    end

    test "an open question nobody answered goes to the backlog", %{board: board, owner: owner} do
      {:ok, _} = Slipdock.Boards.create_column(board, %{"name" => "Backlog"})
      capture = capture_fixture(board, owner)

      question = %{
        "kind" => "open_question",
        "title" => "Who owns billing?",
        "evidence" => [%{"line" => "L1", "quote" => "pricing page"}]
      }

      capture = with_readings(capture, [question])
      {:ok, _} = Meetings.verify(capture)

      assert [%{included: true, effect: %{"type" => "new_card", "list" => "Backlog"}}] =
               findings(capture)
    end
  end

  test "who said it is asked only when a finding depends on an unsure line", %{capture: capture} do
    Repo.update_all(
      from(u in Utterance, where: u.capture_id == ^capture.id and u.line_id in ["L2", "L4"]),
      set: [voice_unsure: true]
    )

    unsure_decision = @decision

    sure = %{
      "kind" => "decision",
      "title" => "Settle it",
      "decided_by" => "Priya",
      "evidence" => [%{"line" => "L2", "quote" => "annual plan"}]
    }

    capture = with_readings(capture, [unsure_decision, sure])

    {:ok, %{questions: 1}} = Meetings.verify(capture)
    assert [%{kind: "who_said_it", context: %{"line" => "L2"}} = q] = questions(capture)
    # Unanswered, it stays unattributed: asked, not waited on.
    refute q.blocking
  end

  test "ideas are left out by default; decisions are entries with a topic label", %{
    capture: capture
  } do
    idea = %{
      "kind" => "idea",
      "title" => "A lifetime plan",
      "evidence" => [%{"line" => "L2", "quote" => "annual plan"}]
    }

    capture = with_readings(capture, [@decision, idea])
    {:ok, _} = Meetings.verify(capture)

    [decision, idea] = findings(capture)
    assert decision.included

    assert decision.effect == %{
             "type" => "decision_entry",
             "topic" => "Pricing",
             "text" => "Annual plan at 20% off",
             "supersedes" => nil,
             "decided_by" => nil
           }

    refute idea.included
  end

  test "verifying again replaces what a reading found, and keeps what a person added", %{
    capture: capture
  } do
    capture = with_readings(capture, [@decision])
    {:ok, _} = Meetings.verify(capture)

    Repo.insert!(%Finding{
      capture_id: capture.id,
      kind: "action",
      title: "Mine",
      origin: "person"
    })

    {:ok, _} = Meetings.verify(capture)

    assert findings(capture) |> Enum.map(& &1.title) |> Enum.sort() == [
             "Annual plan at 20% off",
             "Mine"
           ]
  end

  test "no signal reads as a number, let alone a percentage" do
    for {key, label} <- Verify.signals() do
      refute label =~ ~r/\d|%/, "#{key}: #{label}"
    end

    assert Verify.signal_label("linked_by_similarity") == "linked by similarity only"
    assert Verify.signal_label("something_new") == "something new"
  end
end
