defmodule Slipdock.AutomationsTest do
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Automations, Boards}
  alias Slipdock.Automations.{Callback, Parser, Rule, Runner, Spec}

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

    test "a “callback” is the webhook action under the name people use for it" do
      assert {:ok, %{"actions" => [action]}} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "callback", "url" => "https://example.com/h"}]
               })

      assert action == %{"type" => "webhook", "url" => "https://example.com/h"}
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

    test "says which method a callback will use" do
      {:ok, spec} =
        Spec.validate(%{
          "trigger" => %{"type" => "card_updated"},
          "actions" => [
            %{"type" => "webhook", "url" => "https://example.com/h", "method" => "get"}
          ]
        })

      assert Spec.summary(spec) == "When a card's details changes, GET https://example.com/h."
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

    test "with several people on a card, notify_assignee emails them all and card_assigned fires per newcomer" do
      {board, backlog, _doing, _done} = board_with_lists()
      ada = user_fixture("ada@example.com")
      bob = user_fixture("bob@example.com")

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_assigned", "assignee" => "bob@example.com"},
        "actions" => [%{"type" => "add_flags", "flags" => ["starred"]}]
      })

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_updated", "field" => "priority"},
        "conditions" => [%{"field" => "assignee", "op" => "is", "value" => "bob@example.com"}],
        "actions" => [%{"type" => "notify_assignee", "subject" => "Ours: {{card.assignee}}"}]
      })

      card = card_fixture(backlog, %{"title" => "Ours", "assignee_id" => ada.id})
      {:ok, _} = Boards.update_card(card, %{"add_assignee_ids" => [bob.id]})
      card = Boards.get_card!(card.id)
      assert card.flags == ["starred"]

      {:ok, _} = Boards.update_card(card, %{"priority" => "high"})

      assert_email_sent(fn email ->
        assert Enum.map(email.to, &elem(&1, 1)) == ["ada@example.com", "bob@example.com"]
        assert email.subject == "Ours: ada@example.com, bob@example.com"
      end)
    end
  end

  describe "callbacks" do
    # A rule's callback goes to a `Req.Test` plug (see config/test.exs), which
    # hands the request back to the test rather than off the machine.
    defp stub_callback(status \\ 200) do
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:callback, conn.method, conn.query_params, body})
        Plug.Conn.send_resp(conn, status, "")
      end)
    end

    defp a_card(column) do
      card_fixture(column, %{
        "title" => "Ship the thing",
        "start_date" => "2026-10-20",
        "due_date" => "2026-11-01",
        "flags" => ["blocked", "review"],
        "percent_complete" => 40
      })
    end

    test "POSTs the card, a link to it, its dates, flags and status as JSON" do
      {board, backlog, _doing, _done} = board_with_lists()
      stub_callback()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "webhook", "url" => "https://example.com/hooks/kanban"}]
      })

      card = a_card(backlog)

      assert_received {:callback, "POST", _params, body}
      assert {:ok, payload} = Jason.decode(body)

      assert payload["event"] == "card_created"
      assert payload["board"]["name"] == board.name
      assert payload["board"]["url"] =~ "/boards/#{board.id}"

      assert payload["card"]["title"] == "Ship the thing"
      assert payload["card"]["url"] =~ "/boards/#{board.id}/cards/#{card.id}"
      assert payload["card"]["start_date"] == "2026-10-20"
      assert payload["card"]["due_date"] == "2026-11-01"
      assert payload["card"]["flags"] == ["blocked", "review"]
      assert payload["card"]["status"] == "open"
      assert payload["card"]["percent_complete"] == 40
      assert payload["card"]["column"] == backlog.name
    end

    test "a GET sends the same fields in the query string" do
      {board, backlog, _doing, _done} = board_with_lists()
      stub_callback()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [
          %{"type" => "webhook", "url" => "https://example.com/hooks/kanban", "method" => "get"}
        ]
      })

      card = a_card(backlog)

      assert_received {:callback, "GET", params, ""}
      assert params["card.title"] == "Ship the thing"
      assert params["card.url"] =~ "/boards/#{board.id}/cards/#{card.id}"
      assert params["card.due_date"] == "2026-11-01"
      assert params["card.flags"] == "blocked,review"
      assert params["card.status"] == "open"
      assert params["event"] == "card_created"
    end

    test "the card's status says done once it is ticked off" do
      {board, backlog, _doing, _done} = board_with_lists()
      stub_callback()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_completed"},
        "actions" => [%{"type" => "webhook", "url" => "https://example.com/hooks/kanban"}]
      })

      {:ok, _} = backlog |> a_card() |> Boards.toggle_completed()

      assert_received {:callback, "POST", _params, body}
      assert %{"card" => %{"status" => "done", "completed" => true}} = Jason.decode!(body)
    end

    test "placeholders in the URL are filled in" do
      {board, backlog, _doing, _done} = board_with_lists()
      stub_callback()

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [
          %{
            "type" => "webhook",
            "url" => "https://example.com/hooks/{{card.id}}",
            "method" => "get"
          }
        ]
      })

      card = card_fixture(backlog)

      assert_received {:callback, "GET", params, ""}
      assert params["card.id"] == to_string(card.id)
    end

    test "a refusal at the other end is recorded on the rule" do
      {board, backlog, _doing, _done} = board_with_lists()
      stub_callback(503)

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "webhook", "url" => "https://example.com/hooks/kanban"}]
        })

      card_fixture(backlog)

      assert_received {:callback, "POST", _params, _body}
      assert Automations.get_rule!(rule.id).last_error =~ "HTTP 503"
    end

    test "a URL that isn't http(s) is refused when the rule is saved" do
      assert {:error, message} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "webhook", "url" => "file:///etc/passwd"}]
               })

      assert message =~ "not an http(s) URL"
    end

    test "a private or loopback address is refused when the rule is saved" do
      for url <- [
            "http://127.0.0.1:4000/admin",
            "http://169.254.169.254/latest/meta-data/",
            "http://0.0.0.0/hook",
            "http://[::1]/hook",
            "http://[::ffff:127.0.0.1]/hook",
            "http://localhost:5432/"
          ] do
        assert {:error, message} =
                 Spec.validate(%{
                   "trigger" => %{"type" => "card_created"},
                   "actions" => [%{"type" => "webhook", "url" => url}]
                 }),
               url

        assert message =~ "not a public address"
      end
    end

    test "placeholders can't choose the host" do
      assert {:error, message} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "webhook", "url" => "https://{{card.title}}/x"}]
               })

      assert message =~ "host"
    end

    test "a name that resolves to a private address is refused when called" do
      {board, backlog, _doing, _done} = board_with_lists()
      stub_callback(200)

      for host <- ~w(intranet.test tailnet.test metadata.test split.test) do
        rule =
          rule_fixture(board, %{
            "trigger" => %{"type" => "card_created"},
            "actions" => [%{"type" => "webhook", "url" => "http://#{host}/hook"}]
          })

        card_fixture(backlog)

        refute_received {:callback, _, _, _}
        assert Automations.get_rule!(rule.id).last_error =~ "not a public address"
        Automations.delete_rule(rule)
      end
    end

    test "a redirect is not followed" do
      {board, backlog, _doing, _done} = board_with_lists()
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        send(test, {:hit, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/inside")
        |> Plug.Conn.send_resp(302, "")
      end)

      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "webhook", "url" => "https://example.com/hooks"}]
        })

      card_fixture(backlog)

      assert_received {:hit, "/hooks"}
      refute_received {:hit, "/inside"}
      assert Automations.get_rule!(rule.id).last_error =~ "redirects are not followed"
    end

    test "the call goes to the address that was checked, under its own name" do
      {board, backlog, _doing, _done} = board_with_lists()
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        send(test, {:host, conn.host})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "webhook", "url" => "https://hooks.example.com/x"}]
      })

      card_fixture(backlog)

      assert_received {:host, host}
      assert host == Slipdock.EgressStub.public() |> :inet.ntoa() |> to_string()
    end

    test "placeholders in the URL are percent-encoded" do
      {board, backlog, _doing, _done} = board_with_lists()
      test = self()

      Req.Test.stub(Slipdock.Automations.Notifier, fn conn ->
        send(test, {:path, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [
          %{"type" => "webhook", "url" => "https://example.com/hooks/{{card.title}}?k=1"}
        ]
      })

      card_fixture(backlog, %{"title" => "../admin?drop=1#x"})

      assert_received {:path, path, query}
      assert path == "/hooks/..%2Fadmin%3Fdrop%3D1%23x"
      assert query == "k=1"
    end
  end

  describe "the callback log" do
    defp answer_with(status) do
      Req.Test.stub(Slipdock.Automations.Notifier, &Plug.Conn.send_resp(&1, status, ""))
    end

    defp webhook_rule(board, url \\ "https://example.com/hooks/kanban", extra \\ %{}) do
      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [Map.merge(%{"type" => "webhook", "url" => url}, extra)]
      })
    end

    test "records each call as it happens: rule, card, method, URL and answer" do
      {board, backlog, _doing, _done} = board_with_lists()
      answer_with(200)
      rule = webhook_rule(board, "https://example.com/hooks/{{card.id}}", %{"method" => "put"})
      Automations.subscribe_callbacks(board.id)

      card = card_fixture(backlog, %{"title" => "Ship it"})

      assert_received {:callbacks_changed, board_id}
      assert board_id == board.id

      assert [call] = Automations.list_callbacks(board.id)
      assert call.rule_id == rule.id
      assert call.rule_name == rule.name
      assert call.card_id == card.id
      assert call.card_title == "Ship it"
      assert call.method == "PUT"
      assert call.url == "https://example.com/hooks/#{card.id}"
      assert call.status == 200
      assert call.error == nil
      assert is_integer(call.duration_ms)
      assert Callback.ok?(call)
    end

    test "a refusal is logged with its status" do
      {board, backlog, _doing, _done} = board_with_lists()
      answer_with(503)
      webhook_rule(board)

      card_fixture(backlog)

      assert [call] = Automations.list_callbacks(board.id)
      assert call.status == 503
      assert call.error == "HTTP 503"
      refute Callback.ok?(call)
      assert Callback.outcome(call) == "HTTP 503"
    end

    test "a URL that was never called is logged too" do
      {board, backlog, _doing, _done} = board_with_lists()
      webhook_rule(board, "http://intranet.test/x")

      card_fixture(backlog)

      assert [call] = Automations.list_callbacks(board.id)
      assert call.status == nil
      assert call.error =~ "not a public address"
    end

    test "a transport failure is logged as a category, not the raw error" do
      {board, backlog, _doing, _done} = board_with_lists()

      Req.Test.stub(Slipdock.Automations.Notifier, &Req.Test.transport_error(&1, :econnrefused))

      webhook_rule(board)
      card_fixture(backlog)

      assert [call] = Automations.list_callbacks(board.id)
      assert call.error == "unreachable"
    end

    test "a tree rule's calls are logged on the rule's board, not the sub-board" do
      {board, backlog, _doing, _done} = board_with_lists()
      answer_with(200)

      rule_fixture(
        board,
        %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "webhook", "url" => "https://example.com/h"}]
        },
        %{"scope" => "tree"}
      )

      {:ok, template} = Boards.find_template("Simple")
      epic = card_fixture(backlog)
      {:ok, sub} = Boards.create_sub_board(epic, template)
      sub = Boards.get_board!(sub.id)
      card_fixture(hd(sub.columns))

      assert length(Automations.list_callbacks(board.id)) == 2
      assert Automations.list_callbacks(sub.id) == []
    end

    test "the log keeps only the newest calls, newest first" do
      {board, _backlog, _doing, _done} = board_with_lists()

      for n <- 1..205 do
        Automations.log_callback(%{
          board_id: board.id,
          method: "POST",
          url: "https://example.com/#{n}",
          status: 200
        })
      end

      calls = Automations.list_callbacks(board.id, 500)
      assert length(calls) == 200
      assert hd(calls).url == "https://example.com/205"
      assert List.last(calls).url == "https://example.com/6"
      assert length(Automations.list_callbacks(board.id, 3)) == 3
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
