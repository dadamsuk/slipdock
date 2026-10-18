defmodule SlipdockWeb.Meetings.CaptureChatTest do
  @moduledoc """
  Capturing a conversation from the conversation (#1076): the MCP tool
  `capture_chat`, with the model's own findings (no server model call, every
  quote still checked) or without (the server reads it), and the same over
  `POST /api/boards/:board/captures` with the chat formats.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{AIStub, Meetings, Repo, Settings}
  alias Slipdock.Meetings.{Finding, Pipeline}

  @chat """
  User: Should we ship the pricing page on Friday?
  Assistant: I'd suggest Friday. You could also rewrite the FAQ first.
  User: Yes, ship it Friday. I'll tell Sam today.
  """

  setup %{user: user} do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    board = board_fixture(%{"name" => "Pricing", "code" => "PLCHAT"}, owner: user)
    %{board: board}
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
  end

  defp call(conn, args), do: rpc(conn, "tools/call", %{name: "capture_chat", arguments: args})

  defp ok!(response) do
    result = response["result"]
    assert result["isError"] == false, inspect(result["content"])
    [%{"text" => text}] = result["content"]
    Jason.decode!(text)
  end

  defp requests do
    receive do
      {:ai_request, body} -> [body | requests()]
    after
      0 -> []
    end
  end

  defp kept(id),
    do: Repo.all(from(f in Finding, where: f.capture_id == ^id and f.status == "kept"))

  test "capture_chat is listed, writes, and says what it is for", %{conn: conn} do
    tools = rpc(conn, "tools/list", %{})["result"]["tools"]
    tool = Enum.find(tools, &(&1["name"] == "capture_chat"))
    assert tool["annotations"]["readOnlyHint"] == false
    assert tool["description"] =~ "commit only when they say so"
    assert tool["inputSchema"]["required"] == ["board", "transcript"]
  end

  test "with the model's findings: no server model call, a made-up quote dropped and reported",
       %{conn: conn, board: board, user: user} do
    # The context step may embed; a chat completion would fail.
    AIStub.stub_embeddings()

    findings = %{
      "findings" => [
        %{
          "kind" => "decision",
          "title" => "Ship the pricing page on Friday",
          "evidence" => [%{"line" => "L3", "quote" => "Yes, ship it Friday."}]
        },
        %{
          "kind" => "decision",
          "title" => "Rewrite the FAQ",
          "evidence" => [%{"line" => "L3", "quote" => "Yes, rewrite the FAQ."}]
        }
      ],
      "summary" => "Agreed to ship on Friday."
    }

    summary =
      conn
      |> call(%{board: "PLCHAT", transcript: @chat, title: "Pricing chat", findings: findings})
      |> ok!()

    assert summary["kind"] == "chat"
    assert summary["existing"] == false

    capture = Meetings.get_capture!(summary["id"])
    assert capture.kind == "chat" and capture.source == "agent"
    assert capture.board_id == board.id and capture.owner_id == user.id

    capture = Pipeline.run(capture)
    assert capture.state in ~w(ready needs_review)
    # Read by the model that sent it: nothing asked of a server model.
    assert requests() == []
    assert capture.readings["meta"]["agent_only"] == true
    assert Meetings.notes(capture)["summary"] == "Agreed to ship on Friday."

    assert [%{title: "Ship the pricing page on Friday"} = f] = kept(capture.id)
    assert "from_agent" in f.signals

    again = conn |> call(%{board: "PLCHAT", transcript: @chat}) |> ok!()
    assert again["existing"] == true
    assert again["dropped"] == 1
  end

  test "without findings the server reads it, with the chat prompt", %{conn: conn} do
    AIStub.reply_with(%{"findings" => []})
    summary = conn |> call(%{board: "PLCHAT", transcript: @chat}) |> ok!()
    capture = Pipeline.run(Meetings.get_capture!(summary["id"]))

    assert capture.state == "ready"
    assert [request] = requests()
    assert hd(request["messages"])["content"] =~ "working conversation between a person"
  end

  test "refusals: an unknown format, a broken export, no board to write to", %{conn: conn} do
    assert rpc(conn, "tools/call", %{
             name: "capture_chat",
             arguments: %{board: "PLCHAT", transcript: @chat, format: "vtt"}
           })["result"]["content"]
           |> hd()
           |> Map.get("text") =~ ~s("vtt" is not a chat format)

    broken =
      call(conn, %{board: "PLCHAT", transcript: "{\"mapping\": [", format: "chatgpt-export"})

    assert broken["result"]["isError"] == true
    assert hd(broken["result"]["content"])["text"] =~ "expected a ChatGPT export"

    other = user_fixture("other@example.com")
    board_fixture(%{"name" => "Theirs", "code" => "THEIRSCHAT"}, owner: other)
    nope = call(conn, %{board: "THEIRSCHAT", transcript: @chat})
    assert nope["result"]["isError"] == true
  end

  test "keep_transcript: false is kept on the capture (#1077)", %{conn: conn} do
    summary =
      conn |> call(%{board: "PLCHAT", transcript: @chat, keep_transcript: false}) |> ok!()

    refute Meetings.get_capture!(summary["id"]).keep_transcript

    other = conn |> call(%{board: "PLCHAT", transcript: @chat <> "User: and more\n"}) |> ok!()
    assert Meetings.get_capture!(other["id"]).keep_transcript
  end

  test "off when chat capture is off", %{conn: conn} do
    {:ok, _} = Settings.update(%{"chat_capture_enabled" => false})
    names = rpc(conn, "tools/list", %{})["result"]["tools"] |> Enum.map(& &1["name"])
    refute "capture_chat" in names
    assert call(conn, %{board: "PLCHAT", transcript: @chat})["error"]["message"] =~ "unknown tool"
  end

  describe "the API" do
    test "a ChatGPT export, one conversation chosen by title", %{
      conn: conn,
      board: board,
      user: user
    } do
      convo = fn title, text ->
        %{
          "title" => title,
          "current_node" => "a",
          "mapping" => %{
            "u" => %{
              "id" => "u",
              "parent" => nil,
              "children" => ["a"],
              "message" => %{
                "author" => %{"role" => "user"},
                "content" => %{"parts" => [text]}
              }
            },
            "a" => %{
              "id" => "a",
              "parent" => "u",
              "children" => [],
              "message" => %{
                "author" => %{"role" => "assistant"},
                "content" => %{"parts" => ["Sure."]}
              }
            }
          }
        }
      end

      export = Jason.encode!([convo.("One", "First"), convo.("Two", "Second")])

      body =
        conn
        |> post(~p"/api/boards/#{board.id}/captures", %{
          "kind" => "chat",
          "transcript" => export,
          "conversation" => "Two"
        })
        |> json_response(201)

      assert body["capture"]["kind"] == "chat"
      capture = Meetings.get_capture!(body["capture"]["id"])
      assert capture.transcript_format == "chatgpt-export"

      lines = Repo.preload(capture, :utterances).utterances
      person = user.name || hd(String.split(user.email, "@"))
      assert Enum.map(lines, &{&1.speaker, &1.text}) == [{person, "Second"}, {"ChatGPT", "Sure."}]
    end

    test "several conversations and none chosen is a 422 naming them", %{conn: conn, board: board} do
      export =
        Jason.encode!([
          %{"name" => "One", "chat_messages" => [%{"sender" => "human", "text" => "a"}]},
          %{"name" => "Two", "chat_messages" => [%{"sender" => "human", "text" => "b"}]}
        ])

      assert %{"error" => error} =
               conn
               |> post(~p"/api/boards/#{board.id}/captures", %{
                 "kind" => "chat",
                 "transcript" => export
               })
               |> json_response(422)

      assert error =~
               ~s[the export holds 2 conversations; choose one by id or title ("One", "Two")]
    end
  end
end
