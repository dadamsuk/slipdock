defmodule SlipdockWeb.API.PageSectionsTest do
  @moduledoc """
  The half of the wiki API an agent lives in: reading a page with its
  references resolved, writing one section at a time, and the link graph.
  """
  use SlipdockWeb.ConnCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.Wiki

  setup %{conn: conn, user: user} do
    board = board_fixture(%{"name" => "API Wiki 2", "code" => "apiwiki2"}, owner: user)

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      board: board,
      column: hd(board.columns)
    }
  end

  defp create(conn, body),
    do: conn |> post("/api/boards/apiwiki2/pages", body) |> json_response(201)

  describe "render" do
    test "resolves links and card chips to answers, not syntax", %{
      conn: conn,
      column: column
    } do
      card = card_fixture(column, %{"title" => "Fix the thing"})
      create(conn, %{title: "Retry policy"})

      %{"page" => page} =
        create(conn, %{title: "Runbook", body: "See [[Retry policy]] for ##{card.id}."})

      assert %{"body" => source} =
               conn |> get("/api/pages/#{page["id"]}") |> json_response(200) |> Map.fetch!("page")

      assert source =~ "[[Retry policy]]"

      assert %{"body" => rendered, "format" => "markdown"} =
               conn |> get("/api/pages/#{page["id"]}/render") |> json_response(200)

      assert rendered =~ "[Retry policy](/boards/"
      assert rendered =~ "Fix the thing (##{card.id}"

      assert %{"body" => html} =
               conn |> get("/api/pages/#{page["id"]}/render?format=html") |> json_response(200)

      assert html =~ "wiki-chip"

      assert %{"error" => error} =
               conn |> get("/api/pages/#{page["id"]}/render?format=pdf") |> json_response(400)

      assert error =~ "markdown, html or text"
    end
  end

  describe "sections" do
    setup %{conn: conn} do
      body = "# Deploy\n\nHow we ship.\n\n## Log\n\n- 2026-09-01 first\n"
      %{"page" => page} = create(conn, %{title: "Runbook", body: body})
      %{page: page}
    end

    test "lists the headings a path may name", %{conn: conn, page: page} do
      assert %{"sections" => sections} =
               conn |> get("/api/pages/#{page["id"]}/sections") |> json_response(200)

      assert Enum.map(sections, & &1["path"]) == ["Deploy", "Deploy/Log"]
    end

    test "reads one, replaces one, and appends to one", %{conn: conn, page: page} do
      assert %{"body" => text} =
               conn |> get("/api/pages/#{page["id"]}/section/Deploy/Log") |> json_response(200)

      assert text =~ "2026-09-01 first"

      assert %{"page" => appended} =
               conn
               |> post("/api/pages/#{page["id"]}/section/Log", %{
                 body: "- 2026-09-29 rolled back",
                 message: "log"
               })
               |> json_response(200)

      assert appended["body"] =~ "2026-09-01 first"
      assert appended["body"] =~ "2026-09-29 rolled back"

      assert %{"page" => replaced} =
               conn
               |> put("/api/pages/#{page["id"]}/section/Deploy/Log", %{
                 body: "## Log\n\n- reset"
               })
               |> json_response(200)

      refute replaced["body"] =~ "2026-09-01 first"
      assert replaced["body"] =~ "- reset"
      assert replaced["body"] =~ "How we ship."
    end

    test "appending cannot conflict, even with a stale hash", %{conn: conn, page: page} do
      assert %{"page" => _} =
               conn
               |> post("/api/pages/#{page["id"]}/section/Log", %{
                 body: "- late",
                 base_hash: "nonsense"
               })
               |> json_response(200)
    end

    test "a path that misses says what there is instead", %{conn: conn, page: page} do
      assert %{"error" => error} =
               conn |> get("/api/pages/#{page["id"]}/section/Nowhere") |> json_response(404)

      assert error =~ "Deploy/Log"
    end

    test "appends to the whole page", %{conn: conn, page: page} do
      assert %{"page" => appended} =
               conn
               |> post("/api/pages/#{page["id"]}/append", %{body: "## New\n\nWords."})
               |> json_response(200)

      assert appended["body"] =~ "## New"
      assert String.ends_with?(String.trim(appended["body"]), "Words.")
    end
  end

  describe "the graph" do
    test "links, backlinks, pins and wanted pages", %{conn: conn, column: column} do
      card = card_fixture(column, %{"title" => "Ship it"})
      %{"page" => target} = create(conn, %{title: "Retry policy"})

      %{"page" => source} =
        create(conn, %{
          title: "Runbook",
          body: "See [[Retry policy]] and ##{card.id} and [[Not written]]."
        })

      assert %{"outgoing" => out, "unresolved" => unresolved} =
               conn |> get("/api/pages/#{source["id"]}/links") |> json_response(200)

      assert Enum.any?(out, &(&1["kind"] == "page" and &1["target"]["id"] == target["id"]))
      assert Enum.any?(out, &(&1["kind"] == "card" and &1["target"]["id"] == card.id))
      assert [%{"raw" => "[[Not written]]"}] = unresolved

      assert %{"incoming" => [%{"page" => %{"id" => id}}]} =
               conn |> get("/api/pages/#{target["id"]}/links") |> json_response(200)

      assert id == source["id"]

      assert %{"pinned" => true} =
               conn
               |> post("/api/pages/#{source["id"]}/links", %{card: card.id})
               |> json_response(200)

      assert [%{pinned: true}] = Wiki.pages_for_card(card)

      assert %{"wanted" => [%{"title" => "Not written", "count" => 1}]} =
               conn |> get("/api/boards/apiwiki2/pages/wanted") |> json_response(200)
    end

    test "resolve turns a title into a link an agent can write safely", %{conn: conn} do
      create(conn, %{title: "Retry policy"})

      assert %{"found" => true, "write_as" => "[[Retry policy]]", "page" => page} =
               conn
               |> get("/api/pages/resolve?board=apiwiki2&title=retry+policy")
               |> json_response(200)

      assert page["slug"] == "retry-policy"

      assert %{"found" => false, "write_as" => "[[Retry]]", "note" => note} =
               conn
               |> get("/api/pages/resolve?board=apiwiki2&title=Retry")
               |> json_response(200)

      assert note =~ "wanted page"
    end
  end
end
