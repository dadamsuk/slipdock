defmodule SlipdockWeb.Meetings.AgentsTest do
  @moduledoc """
  Meeting capture for agents (#542): answering and including over the API,
  and the four MCP tools — listed only while meeting mode is on, an answer
  made through them recorded as the person's *via agent*, and the commit
  doing exactly what the preview said.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures
  import Slipdock.MeetingsFixtures

  alias Slipdock.{Repo, Settings}
  alias Slipdock.Meetings.{Commit, Event, Finding, Question}

  setup %{user: user} do
    meetings_on()
    board = board_fixture(%{"name" => "Pricing", "code" => "PL"}, owner: user)
    sam = user_fixture("sam@example.com")
    {:ok, sam} = Slipdock.Accounts.update_profile(sam, %{"name" => "Sam Smith"})
    share_fixture(board, [sam], "write")

    capture =
      reviewed_capture(board, user, [decision_finding(), action_finding("Sammy")], %{}, %{
        blocking: true
      })

    question = Repo.one!(from(q in Question, where: q.capture_id == ^capture.id))

    [decision, _action] =
      Repo.all(from(f in Finding, where: f.capture_id == ^capture.id, order_by: f.position))

    %{board: board, sam: sam, capture: capture, question: question, decision: decision}
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
  end

  defp call(conn, name, args),
    do: rpc(conn, "tools/call", %{name: name, arguments: args})["result"]

  defp ok!(result) do
    assert result["isError"] == false, inspect(result["content"])
    [%{"text" => text}] = result["content"]
    result["structuredContent"] || Jason.decode!(text)
  end

  defp error!(result) do
    assert result["isError"] == true
    [%{"text" => text}] = result["content"]
    text
  end

  describe "the API" do
    test "an answer by number, by label or by value; null takes it back", ctx do
      path = ~p"/api/captures/#{ctx.capture.id}/resolve"

      body =
        ctx.conn
        |> post(path, %{"question" => ctx.question.id, "answer" => "1"})
        |> json_response(200)

      assert body["capture"]["state"] == "ready"

      assert [%{"status" => "answered", "via" => "api", "answered_by" => by}] =
               body["capture"]["questions"]

      assert by == ctx.user.email

      ctx.conn
      |> post(path, %{"question" => ctx.question.id, "answer" => nil})
      |> json_response(200)

      body =
        ctx.conn
        |> post(path, %{"question" => ctx.question.id, "answer" => "nobody yet"})
        |> json_response(200)

      assert [%{"answer" => %{"value" => "none"}}] = body["capture"]["questions"]
    end

    test "an answer that is not one of them is a 422 listing the real ones", ctx do
      body =
        ctx.conn
        |> post(~p"/api/captures/#{ctx.capture.id}/resolve", %{
          "question" => ctx.question.id,
          "answer" => "Bob"
        })
        |> json_response(422)

      assert body["error"] =~
               ~s("Bob" is not an answer to this question; the answers are 1. Sam Smith)

      ctx.conn
      |> post(~p"/api/captures/#{ctx.capture.id}/resolve", %{"question" => 0, "answer" => "1"})
      |> json_response(404)
    end

    test "include, leave out and edit a finding", ctx do
      path = ~p"/api/captures/#{ctx.capture.id}/findings/#{ctx.decision.id}"
      body = ctx.conn |> post(path, %{"included" => false}) |> json_response(200)

      assert Enum.find(body["capture"]["findings"], &(&1["id"] == ctx.decision.id))["included"] ==
               false

      body =
        ctx.conn
        |> post(path, %{"title" => "Annual at 20% off", "topic" => "Plans"})
        |> json_response(200)

      f = Enum.find(body["capture"]["findings"], &(&1["id"] == ctx.decision.id))
      assert f["title"] == "Annual at 20% off"
      assert f["edited_by"] == ctx.user.email
      assert f["becomes"] == "nothing — left out"
    end

    test "answering a committed capture is refused", ctx do
      {:ok, _} = Slipdock.Meetings.Review.answer(ctx.question, "none", ctx.user)
      {:ok, _} = Commit.commit(Slipdock.Meetings.get_capture!(ctx.capture.id), ctx.user)

      body =
        ctx.conn
        |> post(~p"/api/captures/#{ctx.capture.id}/resolve", %{
          "question" => ctx.question.id,
          "answer" => nil
        })
        |> json_response(409)

      assert body["error"] =~ "this capture is committed"
    end
  end

  describe "MCP" do
    test "the four meeting tools are listed while meeting mode is on, and only then", ctx do
      names = fn ->
        rpc(ctx.conn, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
      end

      assert ~w(capture_meeting get_capture resolve_capture_question commit_capture) -- names.() ==
               []

      {:ok, _} = Settings.update(%{"meetings_enabled" => false})

      assert Enum.all?(
               ~w(capture_meeting get_capture resolve_capture_question commit_capture),
               &(&1 not in names.())
             )

      assert rpc(ctx.conn, "tools/call", %{
               name: "get_capture",
               arguments: %{capture: ctx.capture.id}
             })["error"]["message"] =~ "unknown tool"
    end

    test "capture_meeting sends a transcript, with the agent's findings", ctx do
      result =
        ok!(
          call(ctx.conn, "capture_meeting", %{
            board: "PL",
            transcript: "Priya: Ship it Friday.\nSam: Agreed, Friday.",
            title: "Release",
            findings: %{
              "findings" => [
                %{
                  "kind" => "decision",
                  "title" => "Ship Friday",
                  "evidence" => [%{"line" => "L1", "quote" => "Ship it Friday."}]
                }
              ]
            }
          })
        )

      assert result["title"] == "Release"
      assert result["existing"] == false
      capture = Slipdock.Meetings.get_capture!(result["id"])
      assert capture.source == "agent"
      assert capture.sources["findings"]["count"] == 1

      again =
        ok!(
          call(ctx.conn, "capture_meeting", %{
            board: "PL",
            transcript: "Priya: Ship it Friday.\nSam: Agreed, Friday."
          })
        )

      assert again["existing"] == true
    end

    test "capture_meeting says what is wrong with a transcript", ctx do
      assert error!(
               call(ctx.conn, "capture_meeting", %{
                 board: "PL",
                 transcript: "{\"sentences\": [",
                 format: "fireflies"
               })
             ) =~ "the JSON is not valid"

      assert error!(call(ctx.conn, "capture_meeting", %{board: "nope", transcript: "x"})) =~
               "no board you can see"
    end

    test "get_capture shows the questions with numbered answers", ctx do
      result = ok!(call(ctx.conn, "get_capture", %{capture: ctx.capture.id}))
      assert [%{"id" => qid, "answers" => ["1. Sam Smith" | _]}] = result["questions"]
      assert qid == ctx.question.id

      assert Enum.any?(
               result["findings"],
               &(&1["becomes"] =~ "an entry on the meeting's decisions page (Pricing)")
             )

      assert result["preview"] == nil
    end

    test "an answer made through MCP is the person's, via agent, on the record", ctx do
      result =
        ok!(
          call(ctx.conn, "resolve_capture_question", %{
            capture: ctx.capture.id,
            question: ctx.question.id,
            answer: "Sam Smith"
          })
        )

      assert result["state"] == "ready"
      assert is_binary(result["preview"])

      q = Repo.reload!(ctx.question)
      assert q.via == "agent" and q.answered_by_id == ctx.user.id

      message =
        Repo.one!(
          from(e in Event,
            where: e.capture_id == ^ctx.capture.id and e.kind == "answered",
            select: e.message
          )
        )

      assert message =~ "(via agent)"

      assert error!(
               call(ctx.conn, "resolve_capture_question", %{
                 capture: ctx.capture.id,
                 question: ctx.question.id,
                 answer: "9"
               })
             ) =~
               "is not one of the answers"
    end

    test "commit_capture writes what the preview said, and refuses the second time", ctx do
      {:ok, _} = Slipdock.Meetings.Review.answer(ctx.question, "none", ctx.user)
      preview = ok!(call(ctx.conn, "get_capture", %{capture: ctx.capture.id}))["preview"]

      result = ok!(call(ctx.conn, "commit_capture", %{capture: ctx.capture.id, preview: preview}))
      assert result["committed"] == true
      assert "decisions on Decisions / Pricing sync · 7 Oct 2026" in result["written"]

      assert Repo.exists?(
               from(e in Event,
                 where:
                   e.capture_id == ^ctx.capture.id and e.kind == "committed" and e.via == "agent"
               )
             )

      assert error!(call(ctx.conn, "commit_capture", %{capture: ctx.capture.id})) =~
               "committed already"
    end

    test "a read-only token can read a capture but not answer or commit", ctx do
      {token, _} = Slipdock.Accounts.create_api_token(ctx.user, "ro", scope: "read")
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)

      assert ok!(call(conn, "get_capture", %{capture: ctx.capture.id}))["id"] == ctx.capture.id

      assert error!(
               call(conn, "resolve_capture_question", %{
                 capture: ctx.capture.id,
                 question: ctx.question.id,
                 answer: "1"
               })
             ) =~ "read-only"
    end
  end
end
