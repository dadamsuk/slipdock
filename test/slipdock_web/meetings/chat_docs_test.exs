defmodule SlipdockWeb.Meetings.ChatDocsTest do
  @moduledoc """
  Chat capture's docs and skills (#1078): the capture skill and the main
  skill say how to send a conversation, the ChatGPT version maps it onto
  `capture_chat`, the guide, manual and README describe it, and the help and
  agents pages mention it only while chat capture is on.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Slipdock.{Settings, Skills}
  alias Slipdock.Skills.ChatGPT

  @root Path.expand("../../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  setup do
    {:ok, _} = Settings.complete_setup(%{"admin_email" => "admin@example.com"})
    :ok
  end

  test "the capture skill sends a conversation, with its rules" do
    {:ok, text} = Skills.read("slipdock-capture")
    assert Skills.get("slipdock-capture").description =~ "conversation with Claude or ChatGPT"
    assert text =~ "## Capture a conversation (chat capture)"
    assert text =~ "slipdock capture-chat <board> chat.txt"
    assert text =~ "`capture_chat`"
    assert text =~ "your suggestions are not decisions until they said yes"
    assert text =~ "--drop-transcript"
    # The two rules still stand.
    assert text =~ "Answer a question only with the user's own answer"
    assert text =~ "Commit only when the user asks you to"
  end

  test "the main skill names capture-chat" do
    {:ok, text} = Skills.read("slipdock")
    assert text =~ "slipdock capture-chat <board> chat.txt"
  end

  test "the ChatGPT version maps capture-chat onto capture_chat" do
    {:ok, md} = ChatGPT.skill_md("slipdock-capture", "https://x.example")
    assert md =~ "| `capture-chat <board> <file>` | `capture_chat` |"
    assert md =~ "is how *this* conversation gets onto the board"
    assert "capture_chat" in ChatGPT.tool_names()
    assert {:ok, _zip} = ChatGPT.zip("slipdock-capture", "https://x.example")
  end

  test "the guide's chat section, while chat capture is on", %{conn: conn} do
    body = conn |> get(~p"/api/guide") |> response(200)
    assert body =~ "## Chat capture"
    assert body =~ "`capture_chat` sends the conversation"
    assert body =~ "`claude-export`, `chatgpt-export`"

    {:ok, _} = Settings.update(%{"chat_capture_enabled" => false})
    refute conn |> get(~p"/api/guide") |> response(200) =~ "## Chat capture"
  end

  test "the manual and the README describe it" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^### Capturing a conversation$/m
    assert manual =~ "`chat_capture_enabled`"
    assert manual =~ "`claude-export`"
    assert manual =~ "*From a conversation*"
    assert manual =~ "slipdock capture-chat <board> chat.txt"

    readme = read("README.md")
    assert readme =~ "**Meeting and chat capture**"
    assert readme =~ "docs/manual.md#capturing-a-conversation"
  end

  test "the agents page and the help say so only while it is on", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/account/agent")
    assert view |> element("#agent-chat-capture") |> render() =~ "capture_chat"

    {:ok, view, _} = live(conn, ~p"/help/agents/mcp")
    assert view |> element("#help-mcp-capture-chat") |> render() =~ "capture this conversation"

    {:ok, _} = Settings.update(%{"chat_capture_enabled" => false})
    {:ok, view, _} = live(conn, ~p"/account/agent")
    refute has_element?(view, "#agent-chat-capture")
    {:ok, view, _} = live(conn, ~p"/help/agents/mcp")
    refute has_element?(view, "#help-mcp-capture-chat")
  end
end
