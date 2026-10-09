defmodule SlipdockWeb.Meetings.DocsAndSkillsTest do
  @moduledoc """
  Meeting capture's docs and skills (#543): the `slipdock-capture` skill is
  served and packaged like the others (and for ChatGPT, mapped onto the
  connector's capture tools), the agents page mentions meetings only while
  meeting mode is on, and the manual says what it promises.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.MeetingsFixtures

  alias Slipdock.Skills
  alias Slipdock.Skills.ChatGPT

  @root Path.expand("../../..", __DIR__)

  test "the skill is listed, served and in the tarball, with its two rules" do
    assert %{name: "slipdock-capture", description: description, sha: sha} =
             Skills.get("slipdock-capture")

    assert description =~ "meeting"
    assert is_binary(sha)

    {:ok, text} = Skills.read("slipdock-capture")
    assert text =~ "Answer a question only with the user's own answer"
    assert text =~ "Commit only when the user asks you to"

    {:ok, tarball} = Skills.tarball()
    {:ok, files} = :erl_tar.extract({:binary, tarball}, [:memory, :compressed])
    assert Enum.any?(files, fn {name, _} -> to_string(name) == "slipdock-capture/SKILL.md" end)
  end

  @tag :anonymous
  test "GET /api/skills names it, and its SKILL.md downloads", %{conn: conn} do
    names =
      conn
      |> get(~p"/api/skills")
      |> json_response(200)
      |> Map.fetch!("skills")
      |> Enum.map(& &1["name"])

    assert "slipdock-capture" in names

    assert conn |> get(~p"/api/skills/slipdock-capture") |> response(200) =~
             "slipdock capture new"
  end

  test "the ChatGPT version uses the connector's capture tools" do
    assert ChatGPT.offered?("slipdock-capture")
    {:ok, md} = ChatGPT.skill_md("slipdock-capture", "https://x.example")
    assert md =~ "| `capture new <board> --transcript` | `capture_meeting` |"
    assert md =~ "| `capture resolve` | `resolve_capture_question` |"
    assert md =~ "The `capture` tools are there only while the server's admin has meeting"
    assert {:ok, _zip} = ChatGPT.zip("slipdock-capture", "https://x.example")
  end

  test "the main skill points at the capture skill" do
    {:ok, text} = Skills.read("slipdock")
    assert text =~ "slipdock capture new <board> --transcript F"
    assert text =~ "slipdock-capture skill"
  end

  test "the agents page mentions meetings only while meeting mode is on", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/account/agent")
    refute has_element?(view, "#agent-meetings")

    meetings_on()
    {:ok, view, _} = live(conn, ~p"/account/agent")
    assert view |> element("#agent-meetings") |> render() =~ "commits only when you ask"
  end

  test "the manual has the section, its promises and the commands" do
    manual = File.read!(Path.join(@root, "docs/manual.md"))
    assert manual =~ ~r/^## Meeting capture$/m
    assert manual =~ "**Nothing is written that a person didn't approve.**"
    assert manual =~ "**Nothing is claimed that the transcript doesn't say.**"
    assert manual =~ "slipdock capture resolve <id> <question> <answer>"
    assert manual =~ "POST   /api/captures/:id/commit"

    readme = File.read!(Path.join(@root, "README.md"))
    assert readme =~ "**Meeting capture**, when an admin turns on meeting mode"
    assert readme =~ "docs/manual.md#meeting-capture"
  end
end
