defmodule SlipdockWeb.API.SkillsTest do
  @moduledoc """
  The agent instructions this app serves. They need no token, for the same
  reason the guide needs none: they say how to call the API, not what is on it.
  """
  use SlipdockWeb.ConnCase, async: false

  alias Slipdock.Skills

  @tag :anonymous
  test "lists the skills with a version each, without a token", %{conn: conn} do
    assert %{"skills" => skills} = conn |> get("/api/skills") |> json_response(200)

    names = Enum.map(skills, & &1["name"])
    assert "slipdock" in names
    assert "slipdock-wiki" in names
    assert "slipdock-docs" in names
    assert "slipdock-work" in names
    assert "slipdock-loop" in names

    loop = Enum.find(skills, &(&1["name"] == "slipdock-loop"))
    assert loop["description"] =~ "To Do"

    wiki = Enum.find(skills, &(&1["name"] == "slipdock-wiki"))
    assert wiki["description"] =~ "wiki"
    assert "SKILL.md" in wiki["files"]
    assert "references/markup.md" in wiki["files"]
    assert String.length(wiki["sha"]) == 16
  end

  @tag :anonymous
  test "serves a skill and its reference files", %{conn: conn} do
    assert %{"content" => body, "file" => "SKILL.md"} =
             conn |> get("/api/skills/slipdock-wiki") |> json_response(200)

    assert body =~ "name: slipdock-wiki"

    assert %{"content" => markup} =
             conn |> get("/api/skills/slipdock-wiki/references/markup.md") |> json_response(200)

    assert markup =~ "[[Retry policy]]"
  end

  @tag :anonymous
  test "a skill that is not there is a 404", %{conn: conn} do
    assert conn |> get("/api/skills/nope") |> json_response(404)
  end

  @tag :anonymous
  test "cannot be used to read outside the skills directory", %{conn: conn} do
    assert conn |> get("/api/skills/slipdock-wiki/../../../mix.exs") |> json_response(404)
    assert {:error, :not_found} = Skills.read("slipdock-wiki", "../../mix.exs")
    assert {:error, :not_found} = Skills.read("../repo", "SKILL.md")
  end

  test "the sha changes when a file does, which is what `skills check` compares" do
    [%{sha: sha}] = Skills.list() |> Enum.filter(&(&1.name == "slipdock-wiki"))
    assert is_binary(sha)
    assert Skills.get("slipdock-wiki").sha == sha
  end
end
