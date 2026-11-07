defmodule Slipdock.IncidentsTest do
  @moduledoc """
  Incidents (#1946): a card names the card whose shipping caused it
  (`caused_by`) and the check that should have caught it (`missed_by`).
  Every door sets and clears them (the card panel, PATCH and create, MCP
  `update_card`/`create_card`; the CLI's flags are in the CLI's own
  `incidents_test.exs`), an unknown layer and a card the writer can't read
  are refused with a sentence, both cards show the link, and the causing
  card carries one `process` finding with source `incident` that follows the
  fields.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Findings, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.Finding

  setup %{user: user} do
    board = board_fixture(%{"name" => "Incidents"}, owner: user)
    [_backlog, todo | _] = board.columns
    cause = card_fixture(todo, %{"title" => "Shipped the login change"})
    incident = card_fixture(todo, %{"title" => "Login broke"})

    # A board the user can't read, with a card on it.
    stranger = user_fixture("stranger@example.com")
    private = board_fixture(%{"name" => "Private"}, owner: stranger)
    hidden = card_fixture(hd(private.columns), %{"title" => "Somebody else's"})

    %{
      board: board,
      todo: todo,
      cause: cause,
      incident: incident,
      hidden: hidden,
      stranger: stranger
    }
  end

  defp findings,
    do: Repo.all(from(f in Finding, where: f.source == "incident", order_by: f.id))

  defp set(card, attrs, user),
    do: Boards.update_card(Repo.get!(Card, card.id), attrs, by: user)

  defp error_on(changeset, field) do
    {message, _} = Keyword.fetch!(changeset.errors, field)
    message
  end

  describe "the fields" do
    test "set, with #N or a number, and cleared with blanks", ctx do
      {:ok, card} =
        set(ctx.incident, %{"caused_by" => "##{ctx.cause.id}", "missed_by" => "ci"}, ctx.user)

      assert card.caused_by_id == ctx.cause.id
      assert card.missed_by == "ci"

      {:ok, card} = set(card, %{"caused_by" => ctx.cause.id}, ctx.user)
      assert card.caused_by_id == ctx.cause.id

      {:ok, card} = set(card, %{"caused_by" => "", "missed_by" => ""}, ctx.user)
      assert card.caused_by_id == nil
      assert card.missed_by == nil
    end

    test "every layer is taken, and an unknown one refused with a sentence", ctx do
      for layer <- ~w(bar rules ci verify audit none) do
        assert {:ok, %{missed_by: ^layer}} = set(ctx.incident, %{"missed_by" => layer}, ctx.user)
      end

      assert {:error, cs} = set(ctx.incident, %{"missed_by" => "luck"}, ctx.user)

      assert error_on(cs, :missed_by) =~
               "must be one of the checks: bar, rules, ci, verify, audit, none"
    end

    test "a card the writer can't read is refused, and reads like one that isn't there", ctx do
      assert {:error, cs} = set(ctx.incident, %{"caused_by" => ctx.hidden.id}, ctx.user)

      assert error_on(cs, :caused_by) ==
               "There is no card ##{ctx.hidden.id} you can read to name as the cause."

      assert {:error, cs} = set(ctx.incident, %{"caused_by" => 999_999_999}, ctx.user)

      assert error_on(cs, :caused_by) ==
               "There is no card #999999999 you can read to name as the cause."

      assert Repo.get!(Card, ctx.incident.id).caused_by_id == nil
    end

    test "a card shared with the writer on another board is taken", ctx do
      share_fixture(ctx.hidden |> Repo.preload(:board) |> Map.fetch!(:board), [ctx.user], "read")

      assert {:ok, %{caused_by_id: id}} =
               set(ctx.incident, %{"caused_by" => ctx.hidden.id}, ctx.user)

      assert id == ctx.hidden.id
    end

    test "not a card id, or the card itself, is refused", ctx do
      assert {:error, cs} = set(ctx.incident, %{"caused_by" => "login"}, ctx.user)
      assert error_on(cs, :caused_by) =~ "isn't a card id"

      assert {:error, cs} = set(ctx.incident, %{"caused_by" => ctx.incident.id}, ctx.user)
      assert error_on(cs, :caused_by) =~ "can't be its own cause"
    end

    test "create takes them too, and refuses the same", ctx do
      {:ok, card} =
        Boards.create_card(
          ctx.todo,
          %{"title" => "Broke again", "caused_by" => ctx.cause.id, "missed_by" => "rules"},
          by: ctx.user
        )

      assert card.caused_by_id == ctx.cause.id
      assert [%{card_id: cause_id}] = findings()
      assert cause_id == ctx.cause.id

      assert {:error, cs} =
               Boards.create_card(ctx.todo, %{"title" => "No", "caused_by" => ctx.hidden.id},
                 by: ctx.user
               )

      assert error_on(cs, :caused_by) =~ "you can read"
    end
  end

  describe "the finding on the causing card" do
    test "setting missed_by records one process finding with source incident", ctx do
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "ci"}, ctx.user)

      assert [finding] = findings()
      assert finding.kind == "process"
      assert finding.card_id == ctx.cause.id
      assert finding.board_id == ctx.board.id
      assert finding.status == "open"
      assert finding.text == "##{ctx.incident.id} (incident) was missed by ci"
    end

    test "changing the layer updates that finding rather than adding one", ctx do
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "ci"}, ctx.user)
      [first] = findings()

      {:ok, _} = set(ctx.incident, %{"missed_by" => "verify"}, ctx.user)
      assert [finding] = findings()
      assert finding.id == first.id
      assert finding.count == 1
      assert finding.text == "##{ctx.incident.id} (incident) was missed by verify"

      {:ok, _} = set(ctx.incident, %{"missed_by" => "none"}, ctx.user)
      assert [%{text: text}] = findings()
      assert text =~ "was missed by none: no check could have caught it"
    end

    test "naming another cause moves the finding to it", ctx do
      other = card_fixture(ctx.todo, %{"title" => "The real culprit"})
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "bar"}, ctx.user)
      {:ok, _} = set(ctx.incident, %{"caused_by" => other.id}, ctx.user)

      assert [finding] = findings()
      assert finding.card_id == other.id
    end

    test "no finding until both are set, and clearing either takes it away", ctx do
      {:ok, _} = set(ctx.incident, %{"missed_by" => "audit"}, ctx.user)
      assert findings() == []

      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.cause.id}, ctx.user)
      assert [_] = findings()

      {:ok, _} = set(ctx.incident, %{"missed_by" => nil}, ctx.user)
      assert findings() == []

      {:ok, _} = set(ctx.incident, %{"missed_by" => "audit"}, ctx.user)
      {:ok, _} = set(ctx.incident, %{"caused_by" => nil}, ctx.user)
      assert findings() == []
    end

    test "one a person dismissed stays as they left it when the incident is cleared", ctx do
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "ci"}, ctx.user)
      [finding] = findings()
      {:ok, _} = Findings.triage(finding, "dismiss")

      {:ok, _} = set(ctx.incident, %{"missed_by" => nil}, ctx.user)
      assert [%{status: "dismissed"}] = findings()
    end

    test "the findings list filters by source incident", ctx do
      {:ok, _} =
        set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "rules"}, ctx.user)

      assert {:ok, [finding]} = Findings.list(ctx.board, %{"source" => "incident"})
      assert finding.text =~ "was missed by rules"
    end

    test "the Findings page lists it", ctx do
      {:ok, _} =
        set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "rules"}, ctx.user)

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")
      assert html =~ "(incident) was missed by rules"
    end
  end

  describe "the API" do
    test "PATCH sets, shows and clears them", ctx do
      body =
        ctx.conn
        |> patch(~p"/api/cards/#{ctx.incident.id}", %{
          "caused_by" => ctx.cause.id,
          "missed_by" => "verify"
        })
        |> json_response(200)

      assert body["card"]["caused_by"] == ctx.cause.id
      assert body["card"]["missed_by"] == "verify"

      card = ctx.conn |> get(~p"/api/cards/#{ctx.incident.id}") |> json_response(200)
      assert card["card"]["caused_by_card"]["title"] == "Shipped the login change"

      cause = ctx.conn |> get(~p"/api/cards/#{ctx.cause.id}") |> json_response(200)

      assert [%{"id" => id, "title" => "Login broke", "missed_by" => "verify"}] =
               cause["card"]["incidents"]

      assert id == ctx.incident.id

      body =
        ctx.conn
        |> patch(~p"/api/cards/#{ctx.incident.id}", %{"caused_by" => nil, "missed_by" => nil})
        |> json_response(200)

      refute Map.has_key?(body["card"], "caused_by")
      refute Map.has_key?(body["card"], "missed_by")
    end

    test "PATCH refuses an unknown layer and an unreadable card with a sentence", ctx do
      body =
        ctx.conn
        |> patch(~p"/api/cards/#{ctx.incident.id}", %{"missed_by" => "luck"})
        |> json_response(422)

      assert hd(body["details"]["missed_by"]) =~ "must be one of the checks"

      body =
        ctx.conn
        |> patch(~p"/api/cards/#{ctx.incident.id}", %{"caused_by" => ctx.hidden.id})
        |> json_response(422)

      assert hd(body["details"]["caused_by"]) =~ "you can read"
    end

    test "create takes them", ctx do
      body =
        ctx.conn
        |> post(~p"/api/boards/#{ctx.board.id}/cards", %{
          "title" => "Broke on create",
          "caused_by" => "##{ctx.cause.id}",
          "missed_by" => "ci"
        })
        |> json_response(201)

      assert body["card"]["caused_by"] == ctx.cause.id
      assert body["card"]["missed_by"] == "ci"
    end

    test "a cause the reader can't read shows hidden, and its incidents aren't listed", ctx do
      # Somebody with write on the user's board, who can read a card the user can't.
      share_fixture(ctx.board, [ctx.stranger], "write")
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.hidden.id}, ctx.stranger)

      card = ctx.conn |> get(~p"/api/cards/#{ctx.incident.id}") |> json_response(200)
      assert card["card"]["caused_by_card"] == %{"id" => ctx.hidden.id, "hidden" => true}

      # An incident on their own board, caused by the user's card: not listed for the user.
      {:ok, _} =
        Boards.create_card(
          hd(Boards.get_board!(ctx.hidden.board_id).columns),
          %{"title" => "Theirs", "caused_by" => ctx.cause.id},
          by: ctx.stranger
        )

      cause = ctx.conn |> get(~p"/api/cards/#{ctx.cause.id}") |> json_response(200)
      refute Map.has_key?(cause["card"], "incidents")
    end
  end

  describe "a token scoped to some boards" do
    setup ctx do
      # A second board of the user's own, outside the token's scope.
      other = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.user)
      outside = card_fixture(hd(other.columns), %{"title" => "Out of scope"})

      {token, _} =
        Slipdock.Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.board.id])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "application/json")

      %{scoped: conn, outside: outside}
    end

    test "can't name a card outside its scope, and is told the scope is why", ctx do
      body =
        ctx.scoped
        |> patch(~p"/api/cards/#{ctx.incident.id}", %{"caused_by" => ctx.outside.id})
        |> json_response(422)

      assert hd(body["details"]["caused_by"]) =~
               "token's scope doesn't reach card ##{ctx.outside.id}"

      assert Repo.get!(Card, ctx.incident.id).caused_by_id == nil
    end

    test "sees a cause outside its scope only as hidden, and no incidents from there", ctx do
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.outside.id}, ctx.user)
      {:ok, _} = set(ctx.outside, %{"caused_by" => ctx.cause.id}, ctx.user)

      card = ctx.scoped |> get(~p"/api/cards/#{ctx.incident.id}") |> json_response(200)
      assert card["card"]["caused_by_card"] == %{"id" => ctx.outside.id, "hidden" => true}

      cause = ctx.scoped |> get(~p"/api/cards/#{ctx.cause.id}") |> json_response(200)
      refute Map.has_key?(cause["card"], "incidents")
    end
  end

  describe "MCP" do
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

    test "update_card sets and clears them, and refuses an unknown layer", ctx do
      result =
        call(ctx.conn, "update_card", %{
          card: ctx.incident.id,
          caused_by: ctx.cause.id,
          missed_by: "audit"
        })

      refute result["isError"]
      card = Repo.get!(Card, ctx.incident.id)
      assert {card.caused_by_id, card.missed_by} == {ctx.cause.id, "audit"}

      result =
        call(ctx.conn, "update_card", %{card: ctx.incident.id, caused_by: nil, missed_by: nil})

      refute result["isError"]
      card = Repo.get!(Card, ctx.incident.id)
      assert {card.caused_by_id, card.missed_by} == {nil, nil}

      result = call(ctx.conn, "update_card", %{card: ctx.incident.id, missed_by: "luck"})
      assert result["isError"]
      assert hd(result["content"])["text"] =~ "must be one of the checks"

      result = call(ctx.conn, "update_card", %{card: ctx.incident.id, caused_by: ctx.hidden.id})
      assert result["isError"]
      assert hd(result["content"])["text"] =~ "you can read"
    end

    test "create_card takes them, and get_card shows both ends", ctx do
      result =
        call(ctx.conn, "create_card", %{
          board: to_string(ctx.board.id),
          title: "Broke from MCP",
          caused_by: ctx.cause.id,
          missed_by: "bar"
        })

      refute result["isError"]
      card = Repo.one!(from(c in Card, where: c.title == "Broke from MCP"))
      assert {card.caused_by_id, card.missed_by} == {ctx.cause.id, "bar"}

      text = hd(call(ctx.conn, "get_card", %{card: ctx.cause.id})["content"])["text"]
      assert text =~ "Broke from MCP"
      assert text =~ "incidents"
    end
  end

  describe "the card panel" do
    test "the incident shows its cause and the layer, the cause the incident", ctx do
      {:ok, _} = set(ctx.incident, %{"caused_by" => ctx.cause.id, "missed_by" => "ci"}, ctx.user)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.incident}")
      assert has_element?(view, "#incident-cause", "Shipped the login change")
      assert has_element?(view, "#incident-cause", "missed by ci")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.cause}")
      assert has_element?(view, "#caused-incident-#{ctx.incident.id}", "Caused incident")
      assert has_element?(view, "#caused-incident-#{ctx.incident.id}", "Login broke")
    end

    test "the Incident line sets, refuses and clears", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.incident}")
      form = "#incident-form-#{ctx.incident.id}"

      view
      |> form(form, %{"incident" => %{"caused_by" => "##{ctx.cause.id}", "missed_by" => "rules"}})
      |> render_submit()

      card = Repo.get!(Card, ctx.incident.id)
      assert {card.caused_by_id, card.missed_by} == {ctx.cause.id, "rules"}
      assert has_element?(view, "#incident-cause", "missed by rules")
      assert [_] = findings()

      view |> form(form, %{"incident" => %{"caused_by" => "#{ctx.hidden.id}"}}) |> render_submit()

      assert has_element?(
               view,
               "#card-incident #incident-error",
               "There is no card ##{ctx.hidden.id} you can read"
             )

      assert Repo.get!(Card, ctx.incident.id).caused_by_id == ctx.cause.id

      # Not one of the select's options, so sent as a crafted event would be.
      view
      |> element(form)
      |> render_submit(%{
        "incident" => %{"caused_by" => "##{ctx.cause.id}", "missed_by" => "luck"}
      })

      assert has_element?(view, "#card-incident #incident-error", "Missed by")
      assert Repo.get!(Card, ctx.incident.id).missed_by == "rules"

      view |> element("#incident-cause button", "Clear") |> render_click()
      refute has_element?(view, "#incident-error")

      card = Repo.get!(Card, ctx.incident.id)
      assert {card.caused_by_id, card.missed_by} == {nil, nil}
      assert findings() == []
      refute has_element?(view, "#incident-cause")
    end
  end
end
