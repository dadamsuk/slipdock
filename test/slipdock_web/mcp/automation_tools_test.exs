defmodule SlipdockWeb.MCP.AutomationToolsTest do
  @moduledoc """
  `list_automations` and `manage_automation`: a board's rules over MCP,
  owner only, built the way the HTTP API builds them.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Automations}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Rules Desk", "code" => "rd7"}, owner: user)
    [_backlog, doing, _review, done] = board.columns
    %{board: board, doing: doing, done: done}
  end

  defp email_rule(to \\ default_email()) do
    %{
      "trigger" => %{"type" => "card_created"},
      "actions" => [%{"type" => "email", "to" => to, "subject" => "New: {{card.title}}"}]
    }
  end

  defp call(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    result["structuredContent"]
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  defp token_conn(user, scope \\ "write") do
    {token, _} = Accounts.create_api_token(user, "mcp", scope: scope)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  describe "create, list, update and delete" do
    test "a spec is stored as given, then listed, changed and deleted", %{
      conn: conn,
      board: board
    } do
      created =
        ok!(
          call(conn, "manage_automation", %{
            action: "create",
            board: "rd7",
            name: "Tell ops",
            spec: email_rule()
          })
        )["automation"]

      assert created["name"] == "Tell ops"
      assert created["spec"]["trigger"] == %{"type" => "card_created"}
      assert created["enabled"] == true

      listed = ok!(call(conn, "list_automations", %{board: "rd7"}))
      assert listed["board_id"] == board.id
      assert [%{"id" => id, "name" => "Tell ops"}] = listed["automations"]
      assert id == created["id"]
      refute Map.has_key?(listed, "vocabulary")

      by_name = ok!(call(conn, "list_automations", %{board: "rd7", rule: "tell ops"}))
      assert by_name["automation"]["id"] == id

      off =
        ok!(
          call(conn, "manage_automation", %{
            action: "update",
            board: "rd7",
            rule: to_string(id),
            enabled: false
          })
        )

      refute off["automation"]["enabled"]
      refute Automations.get_rule!(id).enabled

      renamed =
        ok!(
          call(conn, "manage_automation", %{
            action: "update",
            board: "rd7",
            rule: "Tell ops",
            name: "Tell everyone",
            scope: "tree"
          })
        )["automation"]

      assert renamed["name"] == "Tell everyone"
      assert renamed["scope"] == "tree"

      assert error!(
               call(conn, "manage_automation", %{
                 action: "delete",
                 board: "rd7",
                 rule: "Tell everyone"
               })
             ) =~ "confirm"

      assert [_] = Automations.list_rules(board.id)

      assert ok!(
               call(conn, "manage_automation", %{
                 action: "delete",
                 board: "rd7",
                 rule: "Tell everyone",
                 confirm: true
               })
             ) == %{"deleted" => true, "automation" => id, "name" => "Tell everyone"}

      assert Automations.list_rules(board.id) == []
    end

    test "a spec without a name is named after what it does", %{conn: conn} do
      created =
        ok!(
          call(conn, "manage_automation", %{action: "create", board: "rd7", spec: email_rule()})
        )

      assert created["automation"]["name"] =~ "email"
    end

    test "the spec can be replaced on update", %{conn: conn, board: board, done: done} do
      rule = rule_fixture(board, email_rule(), %{"name" => "Swap"})

      spec = %{
        "trigger" => %{"type" => "card_moved", "to" => done.name},
        "actions" => [%{"type" => "add_flags", "flags" => ["review"]}]
      }

      updated =
        ok!(
          call(conn, "manage_automation", %{
            action: "update",
            board: "rd7",
            rule: rule.id,
            spec: spec
          })
        )

      assert updated["automation"]["trigger"] == "card_moved"
      assert Automations.get_rule!(rule.id).spec["trigger"]["to"] == done.name
    end

    test "a preset with its params becomes a rule", %{conn: conn, doing: doing} do
      created =
        ok!(
          call(conn, "manage_automation", %{
            action: "create",
            board: "rd7",
            preset: "follow_list",
            params: %{column: doing.name}
          })
        )["automation"]

      assert created["name"] == "Followed: #{doing.name}"
      assert created["spec"]["trigger"] == %{"type" => "card_entered", "column" => doing.name}
    end

    test "text is turned into a spec by the model", %{conn: conn, done: done} do
      Slipdock.AIStub.reply_with(%{
        "name" => "Email on done",
        "spec" => %{
          "trigger" => %{"type" => "card_moved", "to" => done.name},
          "actions" => [%{"type" => "email", "to" => default_email()}]
        }
      })

      created =
        ok!(
          call(conn, "manage_automation", %{
            action: "create",
            board: "rd7",
            text: "email me when a card is done"
          })
        )["automation"]

      assert created["name"] == "Email on done"
      assert created["source"] == "email me when a card is done"
    end

    test "vocabulary: true gives the spec grammar and the presets", %{conn: conn} do
      listed = ok!(call(conn, "list_automations", %{board: "rd7", vocabulary: true}))

      assert listed["automations"] == []
      assert Enum.any?(listed["vocabulary"]["triggers"], &(&1["type"] == "card_stale"))
      assert Enum.any?(listed["presets"], &(&1["key"] == "follow_list"))
    end
  end

  describe "refusals" do
    test "a bad spec is refused with the reason, and nothing is saved", %{
      conn: conn,
      board: board
    } do
      text =
        error!(
          call(conn, "manage_automation", %{
            action: "create",
            board: "rd7",
            spec: %{"trigger" => %{"type" => "full_moon"}, "actions" => []}
          })
        )

      assert text =~ "not saved"
      assert text =~ "full_moon"
      assert Automations.list_rules(board.id) == []
    end

    test "create with no spec, preset or text says what to send", %{conn: conn} do
      text = error!(call(conn, "manage_automation", %{action: "create", board: "rd7"}))
      assert text =~ "spec"
      assert text =~ "preset"
    end

    test "a preset missing a field names it", %{conn: conn} do
      assert error!(
               call(conn, "manage_automation", %{
                 action: "create",
                 board: "rd7",
                 preset: "follow_list"
               })
             ) =~ "List"
    end

    test "text the model can't express comes back as its reason", %{conn: conn, board: board} do
      Slipdock.AIStub.reply_with(%{"error" => "There is no list called Sprint."})

      assert error!(
               call(conn, "manage_automation", %{
                 action: "create",
                 board: "rd7",
                 text: "move it all to Sprint"
               })
             ) == "There is no list called Sprint."

      assert Automations.list_rules(board.id) == []
    end

    test "update with nothing to change says so", %{conn: conn, board: board} do
      rule = rule_fixture(board, email_rule(), %{"name" => "Idle"})

      assert error!(
               call(conn, "manage_automation", %{action: "update", board: "rd7", rule: rule.id})
             ) =~ "nothing to change"
    end

    test "an unknown rule names the ones the board has", %{conn: conn, board: board} do
      assert error!(call(conn, "list_automations", %{board: "rd7", rule: "Ghost"})) =~
               "it has none"

      rule = rule_fixture(board, email_rule(), %{"name" => "Real"})

      text =
        error!(
          call(conn, "manage_automation", %{
            action: "delete",
            board: "rd7",
            rule: "Ghost",
            confirm: true
          })
        )

      assert text =~ "no automation “Ghost”"
      assert text =~ "#{rule.id} “Real”"
    end

    test "bad arguments are named", %{conn: conn} do
      assert error!(call(conn, "manage_automation", %{action: "rename", board: "rd7"})) =~
               "action must be one of create, update, delete"

      assert error!(call(conn, "manage_automation", %{action: "create", board: "rd7", spec: "x"})) =~
               "spec must be an object"

      assert error!(
               call(conn, "manage_automation", %{
                 action: "create",
                 board: "rd7",
                 preset: "follow_list",
                 params: [1]
               })
             ) =~ "params must be an object"

      assert error!(call(conn, "manage_automation", %{action: "update", board: "rd7"})) =~
               "rule is required"

      assert error!(call(conn, "list_automations", %{})) =~ "board is required"
    end
  end

  describe "permissions" do
    test "a writer who is not the owner may neither list nor change rules", %{
      user: user,
      board: board
    } do
      rule = rule_fixture(board, email_rule(), %{"name" => "Owned"})
      writer = user_fixture("writer@example.com")
      Access.grant(board, writer, "write", user)
      conn = token_conn(writer)

      assert error!(call(conn, "list_automations", %{board: board.id})) =~
               "only a board's owner"

      assert error!(
               call(conn, "manage_automation", %{
                 action: "delete",
                 board: board.id,
                 rule: rule.id,
                 confirm: true
               })
             ) =~ "only a board's owner"

      assert [_] = Automations.list_rules(board.id)
    end

    test "a board you can't see is not found", %{board: board} do
      conn = token_conn(user_fixture("stranger@example.com"))

      assert error!(call(conn, "list_automations", %{board: board.id})) =~
               "no board you can see"
    end

    test "a read-only token may neither list nor change, as over HTTP", %{
      user: user,
      board: board
    } do
      rule_fixture(board, email_rule(), %{"name" => "Read me"})
      conn = token_conn(user, "read")

      text = error!(call(conn, "list_automations", %{board: "rd7"}))
      assert text =~ "scope doesn't allow it"
      refute text =~ "only a board's owner"

      assert error!(
               call(conn, "manage_automation", %{
                 action: "create",
                 board: "rd7",
                 spec: email_rule()
               })
             ) =~ "read-only"

      assert [_] = Automations.list_rules(board.id)
    end
  end

  test "both tools are listed, the write one marked destructive", %{conn: conn} do
    tools =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))
      |> json_response(200)
      |> get_in(["result", "tools"])

    list = Enum.find(tools, &(&1["name"] == "list_automations"))
    manage = Enum.find(tools, &(&1["name"] == "manage_automation"))

    assert list["annotations"]["readOnlyHint"] == true
    assert manage["annotations"]["destructiveHint"] == true
  end
end
