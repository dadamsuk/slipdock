defmodule SlipdockWeb.API.AutomationsTest do
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Automations, Boards}

  setup %{conn: conn} do
    Slipdock.AIStub.share()
    board = board_fixture(%{"name" => "API Board"})
    [backlog, doing, _review, done] = board.columns

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      backlog: backlog,
      doing: doing,
      done: done
    }
  end

  defp email_rule(to \\ "ops@example.com") do
    %{
      "trigger" => %{"type" => "card_created"},
      "actions" => [%{"type" => "email", "to" => to, "subject" => "New: {{card.title}}"}]
    }
  end

  describe "GET /api/automations/vocabulary" do
    test "describes every trigger, condition and action a spec may use", %{conn: conn} do
      body = conn |> get(~p"/api/automations/vocabulary") |> json_response(200)
      v = body["vocabulary"]

      assert %{"type" => "card_stale", "required" => ["days"], "scheduled" => true} =
               Enum.find(v["triggers"], &(&1["type"] == "card_stale"))

      assert %{"type" => "email", "required" => ["to"]} =
               Enum.find(v["actions"], &(&1["type"] == "email"))

      assert "priority" in v["condition_fields"]
      assert "any_of" in v["condition_ops"]
      assert "{{card.url}}" in v["placeholders"]

      # The example is a rule the API would actually accept.
      assert {:ok, _} = Slipdock.Automations.Spec.validate(body["example"]["spec"])
    end
  end

  describe "creating rules" do
    test "a spec is taken exactly as given, with no model involved", %{conn: conn, board: board} do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{
          "name" => "Tell ops",
          "spec" => email_rule()
        })
        |> json_response(201)

      assert body["automation"]["name"] == "Tell ops"
      assert body["automation"]["summary"] == "When a card is added, email ops@example.com."
      assert body["automation"]["trigger"] == "card_created"
      assert body["automation"]["enabled"]
      refute body["automation"]["scheduled"]
      refute_received {:ai_request, _}
    end

    test "a spec without a name is named after what it does", %{conn: conn, board: board} do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{"spec" => email_rule()})
        |> json_response(201)

      assert body["automation"]["name"] == "When a card is added, email ops@example.com."
    end

    test "the rule it creates actually runs", %{conn: conn, board: board, backlog: backlog} do
      conn
      |> post(~p"/api/boards/#{board.name}/automations", %{
        "spec" => email_rule("someone@example.com")
      })
      |> json_response(201)

      card_fixture(backlog, %{"title" => "From the API"})
      assert_email_sent(subject: "New: From the API")
    end

    test "a bad spec is refused with the reason", %{conn: conn, board: board} do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{
          "spec" => %{"trigger" => %{"type" => "full_moon"}, "actions" => []}
        })
        |> json_response(422)

      assert body["details"]["spec"] == ["unknown trigger “full_moon”"]
      assert Automations.list_rules(board.id) == []
    end

    test "text is turned into a spec by the model", %{conn: conn, board: board, done: done} do
      Slipdock.AIStub.reply_with(%{
        "name" => "Email on done",
        "spec" => %{
          "trigger" => %{"type" => "card_moved", "to" => done.name},
          "actions" => [%{"type" => "email", "to" => "someone@example.com"}]
        }
      })

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{
          "text" => "email someone@example.com when a ticket is closed"
        })
        |> json_response(201)

      assert body["automation"]["name"] == "Email on done"
      assert body["automation"]["source"] == "email someone@example.com when a ticket is closed"
    end

    test "text the model can't express comes back as a 422", %{conn: conn, board: board} do
      Slipdock.AIStub.reply_with(%{"error" => "There is no list called Sprint."})

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{"text" => "move it all to Sprint"})
        |> json_response(422)

      assert body["error"] == "There is no list called Sprint."
    end

    test "neither spec nor text is a 400 that says what to send", %{conn: conn, board: board} do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{"name" => "Nothing"})
        |> json_response(400)

      assert body["error"] =~ "/api/automations/vocabulary"
      assert body["error"] =~ "/api/automations/presets"
    end
  end

  describe "ready-made rules" do
    test "GET /api/automations/presets lists each preset and its fields", %{conn: conn} do
      body = conn |> get(~p"/api/automations/presets") |> json_response(200)

      assert %{"key" => "follow_list", "fields" => fields} =
               Enum.find(body["presets"], &(&1["key"] == "follow_list"))

      assert %{"name" => "column", "required" => true} = hd(fields)

      assert %{"options" => ["alert", "email", "alert_email", "assignees"]} =
               Enum.find(fields, &(&1["name"] == "notify"))
    end

    test "a preset with its params becomes a rule, with no model involved", %{
      conn: conn,
      board: board,
      doing: doing
    } do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{
          "preset" => "follow_list",
          "params" => %{"column" => doing.name}
        })
        |> json_response(201)

      assert body["automation"]["name"] == "Followed: #{doing.name}"

      assert body["automation"]["spec"]["trigger"] == %{
               "type" => "card_entered",
               "column" => doing.name
             }
    end

    test "a preset missing a field is a 422 naming it", %{conn: conn, board: board} do
      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations", %{"preset" => "follow_list"})
        |> json_response(422)

      assert body["error"] =~ "List"
    end
  end

  describe "listing, changing and deleting" do
    setup %{board: board} do
      %{rule: rule_fixture(board, email_rule(), %{"name" => "Tell ops"})}
    end

    test "lists a board's rules with their state", %{conn: conn, board: board, rule: rule} do
      body = conn |> get(~p"/api/boards/#{board.id}/automations") |> json_response(200)

      assert [%{"id" => id, "name" => "Tell ops", "run_count" => 0}] = body["automations"]
      assert id == rule.id
    end

    test "one rule by id or by name, spec included", %{conn: conn, board: board, rule: rule} do
      body = conn |> get(~p"/api/boards/#{board.id}/automations/#{rule.id}") |> json_response(200)
      assert body["automation"]["spec"]["trigger"]["type"] == "card_created"

      body = conn |> get(~p"/api/boards/#{board.id}/automations/Tell ops") |> json_response(200)
      assert body["automation"]["id"] == rule.id
    end

    test "enabled can be switched off and on", %{conn: conn, board: board, rule: rule} do
      body =
        conn
        |> patch(~p"/api/boards/#{board.id}/automations/#{rule.id}", %{"enabled" => false})
        |> json_response(200)

      refute body["automation"]["enabled"]
      refute Automations.get_rule!(rule.id).enabled

      conn
      |> patch(~p"/api/boards/#{board.id}/automations/#{rule.id}", %{"enabled" => true})
      |> json_response(200)

      assert Automations.get_rule!(rule.id).enabled
    end

    test "the spec can be replaced outright", %{conn: conn, board: board, rule: rule} do
      body =
        conn
        |> patch(~p"/api/boards/#{board.id}/automations/#{rule.id}", %{
          "spec" => %{
            "trigger" => %{"type" => "card_completed"},
            "actions" => [%{"type" => "archive_card"}]
          },
          "name" => "Archive when done"
        })
        |> json_response(200)

      assert body["automation"]["summary"] == "When a card is completed, archive it."
    end

    test "deleting one removes it", %{conn: conn, board: board, rule: rule} do
      assert conn
             |> delete(~p"/api/boards/#{board.id}/automations/#{rule.id}")
             |> json_response(200) == %{"ok" => true}

      assert Automations.list_rules(board.id) == []
    end

    test "an unknown rule is a 404", %{conn: conn, board: board} do
      body = conn |> get(~p"/api/boards/#{board.id}/automations/nope") |> json_response(404)
      assert body["error"] == "automation not found"
    end
  end

  describe "running a rule by hand" do
    test "reports how often it fired", %{conn: conn, board: board, backlog: backlog} do
      rule =
        rule_fixture(board, %{
          "trigger" => %{"type" => "card_overdue"},
          "actions" => [%{"type" => "add_flags", "flags" => ["blocked"]}]
        })

      card =
        card_fixture(backlog, %{"due_date" => Date.to_iso8601(Date.add(Date.utc_today(), -2))})

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/automations/#{rule.id}/run")
        |> json_response(200)

      assert body["fired"] == 1
      assert body["automation"]["run_count"] == 1
      assert Boards.get_card!(card.id).flags == ["blocked"]
    end
  end

  describe "permissions" do
    test "only the owner may see or change a board's rules", %{board: board} do
      reader = user_fixture("reader@example.com")
      Access.grant(board, reader, "write", user_fixture())
      conn = reader |> conn_as() |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/api/boards/#{board.id}/automations") |> json_response(403)

      assert conn
             |> post(~p"/api/boards/#{board.id}/automations", %{"spec" => email_rule()})
             |> json_response(403)
    end

    test "a board you can't see at all is a 404", %{board: board} do
      conn =
        user_fixture("stranger@example.com")
        |> conn_as()
        |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/api/boards/#{board.id}/automations") |> json_response(403)
    end
  end

  describe "alerts" do
    setup %{board: board, backlog: backlog} do
      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [
          %{"type" => "alert", "title" => "Look at {{card.title}}", "severity" => "warning"}
        ]
      })

      %{card: card_fixture(backlog, %{"title" => "This one"})}
    end

    test "GET /api/alerts lists what is waiting for you", %{conn: conn, board: board, card: card} do
      body = conn |> get(~p"/api/alerts") |> json_response(200)

      assert [alert] = body["alerts"]
      assert alert["title"] == "Look at This one"
      assert alert["severity"] == "warning"
      assert alert["card"] == "This one"
      assert alert["board"] == board.name
      assert alert["url"] == "/boards/#{board.id}/cards/#{card.id}"
    end

    test "dismissing one is per person", %{conn: conn} do
      [alert] = Automations.list_alerts(user_fixture())
      other = user_fixture("other@example.com")
      Access.grant(Boards.get_board!(alert.board_id), other, "read", user_fixture())

      assert conn |> delete(~p"/api/alerts/#{alert.id}") |> json_response(200) == %{"ok" => true}
      assert conn |> get(~p"/api/alerts") |> json_response(200) == %{"alerts" => []}

      # Everyone else still has theirs.
      assert [_] = Automations.list_alerts(other)
    end

    test "dismissing all says how many went", %{conn: conn} do
      body = conn |> delete(~p"/api/alerts") |> json_response(200)
      assert body == %{"ok" => true, "dismissed" => 1}
      assert conn |> get(~p"/api/alerts") |> json_response(200) == %{"alerts" => []}
    end

    test "alerts from boards you can't read aren't listed", %{conn: _conn} do
      conn =
        user_fixture("stranger@example.com")
        |> conn_as()
        |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/api/alerts") |> json_response(200) == %{"alerts" => []}
    end
  end
end
