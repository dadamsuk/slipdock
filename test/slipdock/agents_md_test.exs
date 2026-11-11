defmodule Slipdock.AgentsMdTest do
  @moduledoc """
  `AGENTS.md` is the house rules an agent reads first (#2785). It started as
  the Phoenix generator's file, with its `MyApp` / `my_app` placeholders and a
  `mix precommit` alias that `CLAUDE.md` contradicted with `mix pre_push`. This
  keeps those out: no generator placeholder in `AGENTS.md`, `mix pre_push` as
  its one pre-push command, and no `precommit` alias left for a doc to name.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The generator's placeholder names: `MyApp`, `MyAppWeb`, `my_app`,
  # `my_app_web.ex`, and the bare `AppWeb` of its router examples.
  @placeholder ~r/\bMyApp|\bmy_app\b|\bmy_app_|\bAppWeb\b/

  defp read(path), do: File.read!(Path.join(@root, path))

  defp placeholders(text), do: Regex.scan(@placeholder, text) |> List.flatten()

  describe "the placeholder check" do
    test "finds each of the generator's placeholder names" do
      for text <- [
            "The `MyAppWeb.Layouts` module",
            "`{DynamicSupervisor, name: MyApp.MyDynamicSup}`",
            "aliased in the `my_app_web.ex` file",
            ~s(@source "../../lib/my_app_web";),
            "replace my_app by the actual app name",
            ~s(scope "/admin", AppWeb.Admin do)
          ] do
        assert placeholders(text) != [], "missed a placeholder in: #{text}"
      end
    end

    test "leaves the app's own names alone" do
      text = "`SlipdockWeb.Layouts` in `lib/slipdock_web.ex`, `Slipdock.Repo`, `BoardWeb`"
      assert placeholders(text) == []
    end
  end

  test "AGENTS.md has no Phoenix generator placeholders" do
    assert placeholders(read("AGENTS.md")) == [],
           "AGENTS.md still names the generator's placeholders: name the app (Slipdock, SlipdockWeb)"
  end

  test "AGENTS.md names mix pre_push, as CLAUDE.md does, and not mix precommit" do
    agents = read("AGENTS.md")
    assert agents =~ "mix pre_push"
    assert read("CLAUDE.md") =~ "mix pre_push"
    refute agents =~ "precommit"
  end

  test "there is no precommit alias, and no doc names one" do
    aliases = Mix.Project.config()[:aliases]
    assert Keyword.has_key?(aliases, :pre_push)
    refute Keyword.has_key?(aliases, :precommit)

    docs =
      ["AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "README.md"] ++
        (Path.join(@root, "docs/**/*.md")
         |> Path.wildcard()
         |> Enum.map(&Path.relative_to(&1, @root)))

    naming = Enum.filter(docs, &(read(&1) =~ "mix precommit"))
    assert naming == [], "these name `mix precommit`, which is gone: #{Enum.join(naming, ", ")}"
  end
end
