defmodule SlipdockWeb.FindingsLiveTest do
  @moduledoc """
  The board's Findings page (W-2310 §Findings, #1940): it lists what the API
  lists, with the same filters kept in the URL, lets a writer promote,
  dismiss, merge and reopen, refuses a reader, and the card panel says how
  many open findings a card has.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Repo}
  alias Slipdock.Findings.Finding

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Learned"}, owner: owner)
    [backlog | _] = board.columns
    card = card_fixture(backlog, %{"title" => "Taught us"})
    other = card_fixture(backlog, %{"title" => "Another"})
    %{board: board, card: card, other: other, owner: owner}
  end

  defp finding(board, card, attrs) do
    %Finding{
      board_id: board.id,
      card_id: card && card.id,
      kind: "gotcha",
      source: "agent",
      text: "a lesson",
      by: "Builder"
    }
    |> struct(attrs)
    |> Repo.insert!()
  end

  defp reader_conn(board, owner) do
    reader = user_fixture("findings-reader-#{System.unique_integer([:positive])}@example.com")
    {:ok, _} = Access.grant(board, reader, "read", owner)
    conn_as(reader)
  end

  describe "the listing" do
    test "shows the tree's open findings with kind, source, count, card, recorder and text",
         ctx do
      f = finding(ctx.board, ctx.card, text: "`mix format` can need two passes", count: 3)
      finding(ctx.board, ctx.card, text: "already handled", status: "dismissed")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")

      row = "#findings-list #finding-#{f.id}"
      assert has_element?(view, "#{row} [data-role=kind]", "gotcha")
      assert has_element?(view, "#{row} [data-role=source]", "agent")
      assert has_element?(view, "#{row} [data-role=count]", "×3")
      assert has_element?(view, "#{row} [data-role=by]", "Builder")
      assert has_element?(view, "#{row} [data-role=text]", "mix format")

      assert has_element?(
               view,
               ~s(#{row} a[data-role=card][href="/boards/#{ctx.board.id}/cards/#{ctx.card.id}"]),
               "Taught us"
             )

      refute render(view) =~ "already handled"
      refute has_element?(view, "#findings-empty")
    end

    test "a sub-board's page lists the root's findings, its subcards' included", ctx do
      {:ok, t} = Boards.find_template(nil, "Simple")
      {:ok, sub} = sub_board(ctx.card, t)
      sub = Boards.get_board!(sub.id)
      subcard = card_fixture(hd(sub.columns), %{"title" => "A subcard"})
      f = finding(ctx.board, subcard, text: "learned below")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{sub}/findings")
      assert has_element?(view, "#finding-#{f.id}", "learned below")
      assert has_element?(view, "#finding-#{f.id} a", "A subcard")
    end

    test "no findings says so", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")
      assert has_element?(view, "#findings-empty", "No findings")
      refute has_element?(view, "#findings-list")
    end

    test "a stranger is sent away", ctx do
      stranger = user_fixture("findings-stranger@example.com")

      assert {:error, {_, %{to: "/"}}} =
               live(conn_as(stranger), ~p"/boards/#{ctx.board}/findings")
    end

    test "the board's Runners panel links to it beside Health", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")

      assert has_element?(
               view,
               ~s(#runners-findings[href="/boards/#{ctx.board.id}/findings"]),
               "Findings"
             )

      assert has_element?(view, "#runners-health")
    end
  end

  describe "filters" do
    setup ctx do
      old =
        finding(ctx.board, ctx.card,
          text: "old rule",
          kind: "rule",
          source: "rejection",
          updated_at: ~U[2026-01-01 00:00:00Z]
        )

      new = finding(ctx.board, ctx.other, text: "new tooling", kind: "tooling", source: "agent")
      gone = finding(ctx.board, ctx.card, text: "was promoted", status: "promoted", note: "UX-9")
      %{old: old, new: new, gone: gone}
    end

    defp shown(view, f), do: has_element?(view, "#finding-#{f.id}")

    test "status: open by default, then any status or one", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")
      assert shown(view, ctx.old) and shown(view, ctx.new)
      refute shown(view, ctx.gone)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?status=all")
      assert shown(view, ctx.old) and shown(view, ctx.gone)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?status=promoted")
      assert shown(view, ctx.gone)
      refute shown(view, ctx.old)
      assert has_element?(view, "#finding-#{ctx.gone.id} [data-role=note]", "UX-9")
    end

    test "kind", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?kind=rule")
      assert shown(view, ctx.old)
      refute shown(view, ctx.new)
    end

    test "source", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?source=agent")
      assert shown(view, ctx.new)
      refute shown(view, ctx.old)
    end

    test "card", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?card=#{ctx.other.id}")
      assert shown(view, ctx.new)
      refute shown(view, ctx.old)
    end

    test "since: days back or a date; a bad one says so and lists without it", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?since=7")
      assert shown(view, ctx.new)
      refute shown(view, ctx.old)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?since=2025-12-01")
      assert shown(view, ctx.new) and shown(view, ctx.old)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?since=soon")
      assert has_element?(view, "#findings-filter-error", "since is a date")
      assert shown(view, ctx.new) and shown(view, ctx.old)
    end

    test "changing the form puts the filters in the URL", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")

      view
      |> form("#findings-filters",
        filters: %{status: "open", kind: "rule", source: "", card: "", since: ""}
      )
      |> render_change()

      assert_patch(view, ~p"/boards/#{ctx.board}/findings?kind=rule")
      assert shown(view, ctx.old)
      refute shown(view, ctx.new)
    end
  end

  describe "triage" do
    test "promote with a note, from the panel opened in the URL", ctx do
      f = finding(ctx.board, ctx.card, text: "promote me")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")

      view |> element("#finding-triage-#{f.id}") |> render_click()
      assert_patch(view, ~p"/boards/#{ctx.board}/findings?triage=#{f.id}")
      assert has_element?(view, "#finding-panel", "promote me")

      view
      |> form("#finding-promote", %{promote: %{note: "W-1950 §Tests TEST-9"}})
      |> render_submit()

      assert %{status: "promoted", note: "W-1950 §Tests TEST-9"} = Repo.get!(Finding, f.id)
      assert_patch(view, ~p"/boards/#{ctx.board}/findings")
      assert render(view) =~ "Finding ##{f.id} promoted."
      refute shown(view, f)
    end

    test "the panel survives a reload", ctx do
      f = finding(ctx.board, ctx.card, text: "still open")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?triage=#{f.id}")
      assert has_element?(view, "#finding-panel", "still open")
    end

    test "dismiss", ctx do
      f = finding(ctx.board, ctx.card, text: "not worth it")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")
      view |> element("#finding-dismiss-#{f.id}") |> render_click()
      assert Repo.get!(Finding, f.id).status == "dismissed"
      refute shown(view, f)
    end

    test "merge into another finding picked from the list, which takes its count", ctx do
      f = finding(ctx.board, ctx.card, text: "the CLI lacks --paths", count: 2)
      into = finding(ctx.board, ctx.other, text: "the installed CLI lacks --paths", count: 3)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?triage=#{f.id}")

      assert has_element?(view, "#finding-merge-into option[value='#{into.id}']")
      refute has_element?(view, "#finding-merge-into option[value='#{f.id}']")

      view |> form("#finding-merge", %{merge: %{into: into.id}}) |> render_submit()

      assert %{status: "merged", merged_into_id: merged} = Repo.get!(Finding, f.id)
      assert merged == into.id
      assert Repo.get!(Finding, into.id).count == 5
      assert has_element?(view, "#finding-#{into.id} [data-role=count]", "×5")
    end

    test "reopen a triaged finding", ctx do
      f = finding(ctx.board, ctx.card, text: "back again", status: "dismissed")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?status=dismissed")
      view |> element("#finding-reopen-#{f.id}") |> render_click()
      assert Repo.get!(Finding, f.id).status == "open"
    end

    test "a refusal from Findings is said, and nothing changes", ctx do
      f = finding(ctx.board, ctx.card, text: "merged already", status: "merged")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")
      assert render_hook(view, "promote", %{"id" => f.id, "note" => "x"}) =~ "reopen it first"
      assert Repo.get!(Finding, f.id).status == "merged"
    end

    test "a refusal in the panel is said in the panel, not as a flash", ctx do
      f = finding(ctx.board, ctx.card, text: "merge me")
      into = finding(ctx.board, ctx.other, text: "the target")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings?triage=#{f.id}")

      # The target is merged elsewhere after the panel opened.
      Repo.update!(Ecto.Changeset.change(into, status: "merged", merged_into_id: f.id))

      view |> form("#finding-merge", %{merge: %{into: into.id}}) |> render_submit()
      assert has_element?(view, "#finding-panel #finding-panel-error", "merged itself")
      assert Repo.get!(Finding, f.id).status == "open"
    end

    test "a finding of another tree is refused", ctx do
      elsewhere = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
      f = finding(elsewhere, nil, text: "not here")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/findings")
      assert render_hook(view, "dismiss", %{"id" => f.id}) =~ "isn&#39;t on this board"
      assert Repo.get!(Finding, f.id).status == "open"
    end

    test "a reader sees the list but no triage controls, and a write is refused", ctx do
      f = finding(ctx.board, ctx.card, text: "look but leave it")
      {:ok, view, _} = live(reader_conn(ctx.board, ctx.owner), ~p"/boards/#{ctx.board}/findings")

      assert has_element?(view, "#finding-#{f.id}", "look but leave it")

      refute has_element?(view, "#finding-#{f.id} [data-role=triage]")
      refute has_element?(view, "#finding-dismiss-#{f.id}")

      for {event, params} <- [
            {"dismiss", %{}},
            {"promote", %{"note" => "x"}},
            {"merge", %{"into" => "1"}},
            {"reopen", %{}}
          ] do
        assert render_hook(view, event, Map.put(params, "id", f.id)) =~ "read-only access"
      end

      assert Repo.get!(Finding, f.id).status == "open"

      {:ok, view, _} =
        live(reader_conn(ctx.board, ctx.owner), ~p"/boards/#{ctx.board}/findings?triage=#{f.id}")

      refute has_element?(view, "#finding-panel")
    end
  end

  describe "the card panel" do
    test "says how many open findings a card has, linking to the page filtered to it", ctx do
      finding(ctx.board, ctx.card, text: "one")
      finding(ctx.board, ctx.card, text: "two")
      finding(ctx.board, ctx.card, text: "done with", status: "dismissed")

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      assert has_element?(
               view,
               ~s(#card-findings a[href="/boards/#{ctx.board.id}/findings?card=#{ctx.card.id}"]),
               "2 open findings"
             )
    end

    test "says it in the singular for one", ctx do
      finding(ctx.board, ctx.card, text: "one")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      assert has_element?(view, "#card-findings", "1 open finding")
    end

    test "has no line when none are open", ctx do
      finding(ctx.board, ctx.card, text: "settled", status: "promoted")
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      refute has_element?(view, "#card-findings")
    end
  end
end
