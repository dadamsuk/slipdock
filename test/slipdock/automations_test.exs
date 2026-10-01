defmodule Slipdock.AutomationsTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Automations, Boards}
  alias Slipdock.Automations.{Parser, Rule, Runner, Spec}

  defp board_with_lists do
    board = board_fixture(%{"name" => "Launch"})
    [backlog, doing, done | _] = board.columns
    {board, backlog, doing, done}
  end

  describe "Spec.validate/1" do
    test "accepts a rule and drops keys it doesn't know" do
      assert {:ok, spec} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created", "column" => "Doing", "hmm" => "no"},
                 "actions" => [%{"type" => "email", "to" => "a@example.com", "secret" => "shh"}]
               })

      assert spec["trigger"] == %{"type" => "card_created", "column" => "Doing"}
      assert spec["actions"] == [%{"type" => "email", "to" => "a@example.com"}]
      assert spec["conditions"] == []
    end

    test "coerces numbers the model wrote as strings" do
      assert {:ok, %{"trigger" => %{"days" => 7}}} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_stale", "days" => "7"},
                 "actions" => [%{"type" => "complete_card"}]
               })
    end

    test "rejects unknown triggers, actions and condition fields" do
      actions = [%{"type" => "complete_card"}]

      assert {:error, msg} =
               Spec.validate(%{"trigger" => %{"type" => "eclipse"}, "actions" => actions})

      assert msg =~ "unknown trigger"

      assert {:error, msg} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "launch_rocket"}]
               })

      assert msg =~ "unknown action"

      assert {:error, msg} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "conditions" => [%{"field" => "vibes", "op" => "is", "value" => "good"}],
                 "actions" => actions
               })

      assert msg =~ "unknown condition field"
    end

    test "requires a trigger, an action and each action's own keys" do
      assert {:error, msg} = Spec.validate(%{"actions" => [%{"type" => "complete_card"}]})
      assert msg =~ "trigger"

      assert {:error, msg} = Spec.validate(%{"trigger" => %{"type" => "card_created"}})
      assert msg =~ "at least one action"

      assert {:error, msg} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "move_card"}]
               })

      assert msg =~ "needs column"
    end
  end

  describe "Spec.summary/1" do
    test "reads the rule back as a sentence" do
      {:ok, spec} =
        Spec.validate(%{
          "trigger" => %{"type" => "card_created", "column" => "Doing"},
          "conditions" => [%{"field" => "priority", "op" => "is", "value" => "high"}],
          "actions" => [
            %{"type" => "email", "to" => "ops@example.com"},
            %{"type" => "set_priority", "priority" => "critical"}
          ]
        })

      assert Spec.summary(spec) ==
               "When a card is added to Doing and priority is high, " <>
                 "email ops@example.com, then set its priority to critical."
    end
  end

  describe "event triggers" do
    test "a card added to a list emails the address the rule names" do
      {board, _backlog, doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created", "column" => doing.name},
        "actions" => [
          %{"type" => "email", "to" => "ops@example.com", "subject" => "New: {{card.title}}"}
        ]
      })

      card_fixture(doing, %{"title" => "Ship it"})
      assert_email_sent(subject: "New: Ship it")
    end

    test "the list filter is respected" do
      {board, backlog, doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created", "column" => doing.name},
        "actions" => [%{"type" => "email", "to" => "ops@example.com"}]
      })

      card_fixture(backlog, %{"title" => "Not this one"})
      refute_email_sent()
    end

    test "moving a card between lists raises an alert" do
      {board, backlog, _doing, done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_moved", "to" => done.name},
        "actions" => [
          %{"type" => "alert", "title" => "{{card.title}} is done", "severity" => "info"}
        ]
      })

      card = card_fixture(backlog, %{"title" => "Write the docs"})
      :ok = Boards.move_card(card.id, done.id)

      assert [alert] = Automations.list_alerts(user_fixture())
      assert alert.title == "Write the docs is done"
      assert alert.card_id == card.id
    end

    test "completing a card is its own trigger" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_completed"},
        "actions" => [%{"type" => "comment", "body" => "Closed on {{today}}."}]
      })

      card = card_fixture(backlog)
      {:ok, _} = Boards.toggle_completed(card)

      assert [comment] = Boards.get_card!(card.id).comments
      assert comment.body == "Closed on #{Date.utc_today()}."
    end

    test "card_updated can name the field it cares about" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_updated", "field" => "due_date"},
        "actions" => [%{"type" => "add_flags", "flags" => ["review"]}]
      })

      card = card_fixture(backlog)

      {:ok, card} = Boards.update_card(card, %{"title" => "Renamed"})
      assert card.flags == []

      {:ok, _} = Boards.update_card(card, %{"due_date" => "2030-01-01"})
      assert Boards.get_card!(card.id).flags == ["review"]
    end

    test "a tag going on a card can trigger a rule" do
      {board, backlog, _doing, _done} = board_with_lists()
      tag = tag_fixture(board, "urgent")

      rule_fixture(board, %{
        "trigger" => %{"type" => "tag_added", "tag" => "urgent"},
        "actions" => [%{"type" => "set_priority", "priority" => "critical"}]
      })

      card = card_fixture(backlog)
      {:ok, _} = Boards.toggle_card_tag(card, tag)

      assert Boards.get_card!(card.id).priority == "critical"
    end

    test "a comment can trigger a rule" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "comment_added"},
        "actions" => [%{"type" => "alert", "title" => "New comment on {{card.title}}"}]
      })

      card = card_fixture(backlog, %{"title" => "Spec"})
      {:ok, _} = Boards.add_comment(card, "Looks good")

      assert [%{title: "New comment on Spec"}] = Automations.list_alerts(user_fixture())
    end

    test "a disabled rule does nothing" do
      {board, _backlog, doing, _done} = board_with_lists()

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "email", "to" => "ops@example.com"}]
        })

      {:ok, _} = Automations.toggle_rule(rule)
      card_fixture(doing)
      refute_email_sent()
    end
  end

  describe "conditions" do
    test "every condition must hold" do
      {board, backlog, _doing, _done} = board_with_lists()
      tag = tag_fixture(board, "ops")

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_updated"},
        "conditions" => [
          %{"field" => "priority", "op" => "any_of", "value" => ["high", "critical"]},
          %{"field" => "tag", "op" => "is", "value" => "ops"}
        ],
        "actions" => [%{"type" => "add_flags", "flags" => ["flagged"]}]
      })

      card = card_fixture(backlog)

      # High priority, but not tagged: no match.
      {:ok, card} = Boards.update_card(card, %{"priority" => "high"})
      assert card.flags == []

      {:ok, _} = Boards.toggle_card_tag(card, tag)
      {:ok, _} = Boards.update_card(Boards.get_card!(card.id), %{"title" => "Now both"})
      assert Boards.get_card!(card.id).flags == ["flagged"]
    end

    test "is_set and is_not_set look at whether a field has a value" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "conditions" => [%{"field" => "due_date", "op" => "is_not_set", "value" => nil}],
        "actions" => [%{"type" => "alert", "title" => "No due date on {{card.title}}"}]
      })

      card_fixture(backlog, %{"title" => "Undated"})
      card_fixture(backlog, %{"title" => "Dated", "due_date" => "2030-06-01"})

      assert ["No due date on Undated"] =
               user_fixture() |> Automations.list_alerts() |> Enum.map(& &1.title)
    end
  end

  describe "actions" do
    test "a rule can move, tag, flag, assign and comment in one go" do
      {board, backlog, _doing, done} = board_with_lists()
      tag = tag_fixture(board, "shipped")
      user = user_fixture()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_completed"},
        "actions" => [
          %{"type" => "move_card", "column" => done.name},
          %{"type" => "add_tags", "tags" => ["shipped"]},
          %{"type" => "add_flags", "flags" => ["starred"]},
          %{"type" => "assign", "assignee" => user.email},
          %{"type" => "comment", "body" => "Shipped {{card.title}}."}
        ]
      })

      card = card_fixture(backlog, %{"title" => "The thing"})
      {:ok, _} = Boards.toggle_completed(card)

      card = Boards.get_card!(card.id)
      assert card.column_id == done.id
      assert Enum.map(card.tags, & &1.id) == [tag.id]
      assert "starred" in card.flags
      assert card.assignee_id == user.id
      assert [%{body: "Shipped The thing."}] = card.comments
    end

    test "set_due_date understands a date and a number of days" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "set_due_date", "in_days" => 3}]
      })

      card = card_fixture(backlog)
      assert Boards.get_card!(card.id).due_date == Date.add(Date.utc_today(), 3)
    end

    test "create_card adds a card of its own" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_completed"},
        "actions" => [
          %{
            "type" => "create_card",
            "title" => "Follow up on {{card.title}}",
            "column" => backlog.name
          }
        ]
      })

      card = card_fixture(backlog, %{"title" => "Launch"})
      {:ok, _} = Boards.toggle_completed(card)

      titles =
        board.id
        |> Boards.get_board!()
        |> Map.get(:columns)
        |> Enum.flat_map(& &1.cards)
        |> Enum.map(& &1.title)

      assert "Follow up on Launch" in titles
    end

    test "an action that cannot be resolved fails on its own and is recorded" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [
            %{"type" => "move_card", "column" => "Nowhere"},
            %{"type" => "add_flags", "flags" => ["blocked"]}
          ]
        })

      card = card_fixture(backlog)

      assert Boards.get_card!(card.id).flags == ["blocked"]
      rule = Automations.get_rule!(rule.id)
      assert rule.last_error =~ "no list called"
      assert rule.run_count == 1
    end

    test "notify_assignee emails whoever holds the card" do
      {board, backlog, _doing, _done} = board_with_lists()
      user = user_fixture("holder@example.com")

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_updated", "field" => "priority"},
        "actions" => [
          %{
            "type" => "notify_assignee",
            "subject" => "Yours: {{card.title}}",
            "body" => "{{card.url}}"
          }
        ]
      })

      card = card_fixture(backlog, %{"title" => "Yours", "assignee_id" => user.id})
      {:ok, _} = Boards.update_card(card, %{"priority" => "high"})

      assert_email_sent(fn email ->
        assert {_, "holder@example.com"} = hd(email.to)
        assert email.subject == "Yours: Yours"
        assert email.text_body =~ "/cards/#{card.id}"
      end)
    end
  end

  describe "templates" do
    test "render/2 fills what it knows and leaves what it doesn't" do
      bindings = %{"card.title" => "Write it", "board.name" => "Launch"}

      assert Runner.render("{{card.title}} on {{ board.name }}", bindings) == "Write it on Launch"
      assert Runner.render("{{card.nope}}", bindings) == "{{card.nope}}"
    end
  end

  describe "loops" do
    test "rules that set each other off stop instead of running forever" do
      {board, backlog, doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_moved", "to" => doing.name},
        "actions" => [%{"type" => "move_card", "column" => backlog.name}]
      })

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_moved", "to" => backlog.name},
        "actions" => [%{"type" => "move_card", "column" => doing.name}]
      })

      card = card_fixture(backlog)
      # Without the depth guard this never returns.
      :ok = Boards.move_card(card.id, doing.id)
      assert Boards.get_card!(card.id).column_id in [backlog.id, doing.id]
    end
  end

  describe "scheduled rules" do
    test "card_stale picks up cards nobody has touched" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_stale", "days" => 7, "column" => backlog.name},
        "actions" => [%{"type" => "add_flags", "flags" => ["waiting"]}]
      })

      fresh = card_fixture(backlog, %{"title" => "Fresh"})
      stale = card_fixture(backlog, %{"title" => "Stale"})
      age(stale, days: 10)

      assert Automations.run_scheduled() == 1
      assert Boards.get_card!(stale.id).flags == ["waiting"]
      assert Boards.get_card!(fresh.id).flags == []
    end

    test "a rule fires once per occasion, however often the scheduler ticks" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_due_soon", "within_hours" => 24},
        "actions" => [%{"type" => "alert", "title" => "{{card.title}} is due tomorrow"}]
      })

      card_fixture(backlog, %{
        "title" => "Report",
        "due_date" => Date.to_iso8601(Date.utc_today())
      })

      assert Automations.run_scheduled() == 1
      assert Automations.run_scheduled() == 0
      assert length(Automations.list_alerts(user_fixture())) == 1
    end

    test "card_overdue only looks at cards past their date and still open" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_overdue"},
        "actions" => [
          %{"type" => "alert", "title" => "Overdue: {{card.title}}", "severity" => "urgent"}
        ]
      })

      yesterday = Date.to_iso8601(Date.add(Date.utc_today(), -1))
      card_fixture(backlog, %{"title" => "Late", "due_date" => yesterday})
      card_fixture(backlog, %{"title" => "Closed", "due_date" => yesterday, "completed" => true})
      card_fixture(backlog, %{"title" => "Future", "due_date" => "2099-01-01"})

      assert Automations.run_scheduled() == 1

      assert [%{title: "Overdue: Late", severity: "urgent"}] =
               Automations.list_alerts(user_fixture())
    end

    test "a daily schedule runs once a day, after its time" do
      {board, _backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "schedule", "at" => "09:00"},
        "actions" => [%{"type" => "alert", "title" => "Morning report"}]
      })

      at = fn time -> DateTime.new!(~D[2030-03-04], time, "Etc/UTC") end

      assert Automations.run_scheduled(at.(~T[08:30:00])) == 0
      assert Automations.run_scheduled(at.(~T[09:15:00])) == 1
      assert Automations.run_scheduled(at.(~T[17:00:00])) == 0
    end

    test "“Run now” forgets what a timed rule has already done" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_overdue"},
          "actions" => [%{"type" => "comment", "body" => "Still overdue."}]
        })

      card =
        card_fixture(backlog, %{"due_date" => Date.to_iso8601(Date.add(Date.utc_today(), -2))})

      assert Automations.run_scheduled() == 1
      assert Automations.run_scheduled() == 0
      assert Automations.run_rule_now(rule) == 1
      assert length(Boards.get_card!(card.id).comments) == 2
    end

    test "a tree-scoped rule reaches into sub-boards" do
      board = board_fixture(%{"name" => "Root"})
      [backlog | _] = board.columns
      {:ok, template} = Boards.find_template("Simple")

      epic = card_fixture(backlog, %{"title" => "Epic"})
      {:ok, sub} = Boards.create_sub_board(epic, template)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "Subcard"})
      age(subcard, days: 30)

      rule_fixture(
        board,
        %{
          "trigger" => %{"type" => "card_stale", "days" => 14},
          "actions" => [%{"type" => "alert", "title" => "Stale: {{card.title}}"}]
        },
        %{"scope" => "tree"}
      )

      assert Automations.run_scheduled() == 1
      assert [%{title: "Stale: Subcard"}] = Automations.list_alerts(user_fixture())
    end
  end

  describe "alerts" do
    test "the same rule says the same thing about the same card only once" do
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_updated"},
        "actions" => [%{"type" => "alert", "title" => "Look at {{card.title}}"}]
      })

      card = card_fixture(backlog, %{"title" => "This"})
      {:ok, card} = Boards.update_card(card, %{"priority" => "high"})
      {:ok, _} = Boards.update_card(card, %{"priority" => "low"})

      assert length(Automations.list_alerts(user_fixture())) == 1
    end

    test "dismissing is per person" do
      {board, backlog, _doing, _done} = board_with_lists()
      owner = user_fixture()
      other = user_fixture("other@example.com")
      Slipdock.Access.grant(board, other, "read", owner)

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "alert", "title" => "Something happened"}]
      })

      card_fixture(backlog)

      assert [alert] = Automations.list_alerts(owner)
      assert [^alert] = Automations.list_alerts(other)

      Automations.dismiss_alert(owner, alert.id)
      assert Automations.list_alerts(owner) == []
      assert [_] = Automations.list_alerts(other)
    end

    test "alerts on boards you cannot read stay out of sight" do
      stranger = user_fixture("stranger@example.com")
      {board, backlog, _doing, _done} = board_with_lists()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "alert", "title" => "Private business"}]
      })

      card_fixture(backlog)

      assert [_] = Automations.list_alerts(user_fixture())
      assert Automations.list_alerts(stranger) == []
    end

    test "the most urgent alert comes first" do
      {board, backlog, _doing, _done} = board_with_lists()

      for severity <- ~w(info urgent warning) do
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [
            %{"type" => "alert", "title" => "A #{severity} one", "severity" => severity}
          ]
        })
      end

      card_fixture(backlog)

      assert ~w(urgent warning info) =
               user_fixture() |> Automations.list_alerts() |> Enum.map(& &1.severity)
    end
  end

  describe "Parser" do
    setup do
      Slipdock.AIStub.share()
      :ok
    end

    test "turns a sentence into a rule, checked against the vocabulary" do
      {board, _backlog, doing, _done} = board_with_lists()

      Slipdock.AIStub.reply_with(%{
        "name" => "Tell ops about new work",
        "scope" => "board",
        "spec" => %{
          "trigger" => %{"type" => "card_created", "column" => doing.name},
          "actions" => [%{"type" => "email", "to" => "someone@example.com"}]
        }
      })

      assert {:ok, rule} =
               Automations.create_rule_from_text(
                 board,
                 "when creating a new card in #{doing.name}, email someone@example.com"
               )

      assert rule.name == "Tell ops about new work"
      assert rule.source =~ "someone@example.com"
      assert Rule.trigger_type(rule) == "card_created"

      # The prompt tells the model what this board actually has.
      assert_receive {:ai_request, %{"messages" => [%{"content" => prompt} | _]}}
      assert prompt =~ "Lists, in order: #{Enum.map_join(board.columns, ", ", & &1.name)}"
      assert prompt =~ "card_stale"
    end

    test "a spec the runner couldn't honour is refused, not stored" do
      {board, _backlog, _doing, _done} = board_with_lists()

      Slipdock.AIStub.reply_with(%{
        "name" => "Nonsense",
        "spec" => %{"trigger" => %{"type" => "full_moon"}, "actions" => []}
      })

      assert {:error, message} = Automations.create_rule_from_text(board, "do something odd")
      assert message =~ "malformed"
      assert Automations.list_rules(board.id) == []
    end

    test "the model may say it cannot write the rule" do
      {board, _backlog, _doing, _done} = board_with_lists()
      Slipdock.AIStub.reply_with(%{"error" => "There is no list called Sprint on this board."})

      assert {:error, "There is no list called Sprint on this board."} =
               Parser.parse(board, "move everything to Sprint")
    end

    test "an empty description is refused before the model is asked" do
      {board, _backlog, _doing, _done} = board_with_lists()
      assert {:error, "Describe the rule first."} = Parser.parse(board, "   ")
    end
  end

  # Cards are only stale if their timestamps say so.
  defp age(card, days: days) do
    then = DateTime.add(DateTime.utc_now(:second), -days * 24 * 3600, :second)

    Repo.update_all(
      from(c in Slipdock.Boards.Card, where: c.id == ^card.id),
      set: [updated_at: then, inserted_at: then]
    )
  end
end
