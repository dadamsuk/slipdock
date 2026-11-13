defmodule SlipdockCLI.SkillsBoardTest do
  @moduledoc """
  `slipdock skills board <board> [<name>]` (#2063): the registry skills
  enabled on a board, as a table, one skill's pinned text, or JSON. A name
  not enabled there and a board out of reach end in `System.halt/1`, so they
  are checked on `board_skills/2`, which decides them.
  """
  # Sync: sets the SLIPDOCK_* variables, which are one environment for the
  # whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Skills}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  @board %{"id" => 7, "code" => "plan", "name" => "Plans"}
  @grilling %{
    "name" => "grilling",
    "description" => "Asks hard questions.",
    "source_name" => "octo/skills",
    "licence" => "MIT",
    "pinned_hash" => "abc123def4567890ffff",
    "status" => "current",
    "text" => "---\nname: grilling\n---\n\nAsk one question at a time.\n"
  }

  defp serve(body), do: System.put_env("SLIPDOCK_URL", FakeServer.start([{200, body}]))

  test "lists the board's enabled skills, a changed one said so" do
    changed = %{@grilling | "name" => "tdd", "status" => "changed", "licence" => nil}
    serve(JSON.encode!(%{board: @board, skills: [@grilling, changed]}))

    out = capture_io(fn -> Skills.run("skills", ["board", "plan"], []) end)

    assert_received {:request, "GET", "/api/boards/plan/skills", _}
    assert out =~ "grilling"
    assert out =~ "octo/skills"
    assert out =~ "abc123def456"
    refute out =~ "abc123def4567890"
    assert out =~ "changed upstream: the pinned text is served until re-pinned"
    refute out =~ "Ask one question"
  end

  test "none enabled says so and how to enable one" do
    serve(JSON.encode!(%{board: @board, skills: []}))
    out = capture_io(fn -> Skills.run("skills", ["board", "plan"], []) end)
    assert out =~ "no skills are enabled on Plans (plan)"
    assert out =~ "slipdock registry enable"
  end

  test "with a name, prints that skill's pinned text, its provenance on stderr" do
    serve(JSON.encode!(%{board: @board, skills: [@grilling]}))

    {out, err} =
      with_io(:stderr, fn ->
        capture_io(fn -> Skills.run("skills", ["board", "my board", "grilling"], []) end)
      end)

    assert_received {:request, "GET", "/api/boards/my%20board/skills", _}
    assert out == @grilling["text"] <> "\n"
    assert err =~ "grilling from octo/skills · licence MIT · pinned abc123def456 · current"
  end

  test "--json with a name gives the board and that skill, text included" do
    serve(JSON.encode!(%{board: @board, skills: [@grilling]}))

    out = capture_io(fn -> Skills.run("skills", ["board", "plan", "grilling"], json: true) end)
    data = JSON.decode!(out)
    assert data["board"]["code"] == "plan"
    assert data["skill"]["text"] =~ "Ask one question"
  end

  test "a name not enabled there is a 404 that names the board" do
    assert {:error, 404, %{"error" => "no skill named tdd is enabled on Plans (plan)"}} =
             Skills.board_skills({:ok, %{"board" => @board, "skills" => [@grilling]}}, "tdd")

    assert {:error, 404, %{"error" => "no skill named tdd is enabled on Plans"}} =
             Skills.board_skills(
               {:ok, %{"board" => %{"name" => "Plans", "code" => nil}, "skills" => []}},
               "tdd"
             )
  end

  test "the server's refusal passes through untouched" do
    refusal = {:error, 404, %{"error" => "board not found"}}
    assert Skills.board_skills(refusal, nil) == refusal
    assert Skills.board_skills(refusal, "grilling") == refusal
  end
end
