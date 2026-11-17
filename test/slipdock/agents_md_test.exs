defmodule Slipdock.AgentsMdTest do
  @moduledoc """
  `AGENTS.md` is the house rules an agent reads first (#2785). It started as
  the Phoenix generator's file, with its `MyApp` / `my_app` placeholders and a
  `mix precommit` alias that `CLAUDE.md` contradicted with `mix pre_push`. This
  keeps those out: no generator placeholder in `AGENTS.md`, `mix pre_push` as
  its one pre-push command, and no `precommit` alias left for a doc to name.
  """
  use ExUnit.Case, async: true

  alias Slipdock.DocsFacts

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

  describe "the outside contributor's path (#3342)" do
    @outside "## If you can't open the maintainers' board"

    for file <- ["CLAUDE.md", "AGENTS.md"] do
      test "#{file} opens with it: fork, a pull request, never main, no card or handbook" do
        text = read(unquote(file))
        # The first section after the title is the outsider's.
        assert [_title, first | _] = String.split(text, ~r/^## /m)
        assert "## " <> first =~ @outside

        section = "## " <> first
        assert section =~ ~r/fork/i
        assert section =~ ~r/open a pull request/i
        assert section =~ "Never push to `main`"
        DocsFacts.assert_states(section, "Skip the card and handbook steps")
        DocsFacts.assert_states(section, "say in the pull request which checks you ran")
      end

      test "#{file} tells nobody to push to main but a maintainer with a card" do
        # Every "push to `main`" is a "never", or rule 5's maintainer case,
        # which comes after rule 5 names the outsider's exception.
        text = read(unquote(file)) |> String.replace(~r/\s+/, " ")

        pushes =
          Regex.scan(~r/.{0,40}push to `main`.{0,20}/i, text)
          |> List.flatten()
          |> Enum.reject(&(&1 =~ ~r/never push to `main`/i))

        for push <- pushes do
          assert push =~ "push to `main`, which deploys",
                 "#{unquote(file)} tells someone to push to main: #{push}"

          [before, _] = String.split(text, "push to `main`, which deploys", parts: 2)
          rule5 = before |> String.split("5. **Ship the way") |> List.last()
          DocsFacts.assert_states(rule5, "Without access to the board, this rule is not yours")
          assert rule5 =~ "maintainers' board"
        end
      end
    end
  end
end
