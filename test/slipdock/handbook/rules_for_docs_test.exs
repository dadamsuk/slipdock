defmodule Slipdock.Handbook.RulesForDocsTest do
  @moduledoc """
  Asking for the rules of a set of paths (#1774) is written down: the
  guide, `docs/agents.md`, the manual and the slipdock-loop skill (every
  copy), which reads them before building and checks the diff before
  submitting.
  """
  # The guide reads the settings, so this needs the database.
  use Slipdock.DataCase, async: true

  @root Path.expand("../../..", __DIR__)

  test "the guide's handbook section says how to ask, and what get_card carries" do
    {:ok, guide} = SlipdockWeb.APIGuide.section("handbook", [])
    assert guide =~ "`slipdock handbook <board> --paths a,b`"
    assert guide =~ "`git diff --name-only main | slipdock handbook <board> --paths-from -`"
    assert guide =~ "`GET /api/boards/:board/handbook?paths=a,b`"
    assert guide =~ "`rules_more`"
  end

  test "docs/agents.md and the manual show both forms" do
    for doc <- ~w(docs/agents.md docs/manual.md) do
      text = Slipdock.DocsText.read!(Path.join(@root, doc))
      assert text =~ "--paths-from -", doc
      assert text =~ "/api/boards/:board/handbook?paths=a,b", doc
      assert text =~ "rules_more", doc
    end
  end

  test "slipdock-loop checks the diff against the rules before submitting" do
    path = Path.join(@root, "priv/skills/slipdock-loop/SKILL.md")
    text = Slipdock.DocsText.read!(path)
    assert text =~ "**Before\nsubmitting, check the diff against them**", path
    assert text =~ "slipdock handbook <board> --paths-from -", path
  end
end
