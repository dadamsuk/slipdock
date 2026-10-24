defmodule SlipdockWeb.ReplyDocsTest do
  @moduledoc """
  Replying to a notification as the docs describe it (#1260): the manual's
  section, the README, docs/agents.md, the API guide and both copies of the
  slipdock skill.
  """
  use SlipdockWeb.ConnCase, async: true

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "the manual: which emails, quoted text, waits by reply, bounces" do
    manual = read("docs/manual.md")
    assert manual =~ ~r/^### Replying to a notification$/m
    assert manual =~ "`Reply-To:\nreply-…@<domain>`"
    assert manual =~ "**Quoted history is taken off**"
    assert manual =~ "**Answering a wait by reply.**"
    assert manual =~ "start with the choice's number (`2`) or its text (`EU`)"
    assert manual =~ "answer each in a paragraph of its own, in order"
    assert manual =~ "The wait stays open, and a\n  second comment says why."
    assert manual =~ "**Why a reply bounces.**"
    assert manual =~ "more than a year old"
    assert manual =~ "`Slipdock.Inbound.ReplyToken`"
  end

  test "README links to it from the features and from Receiving email" do
    readme = read("README.md")
    assert Regex.scan(~r/docs\/manual\.md#replying-to-a-notification/, readme) |> length() >= 2
    assert readme =~ "signed `reply-…@` `Reply-To`"
  end

  test "docs/agents.md and the API guide say a reply can be a comment" do
    assert read("docs/agents.md") =~ "manual.md#replying-to-a-notification"

    assert SlipdockWeb.APIGuide.markdown() =~
             "Emails about a card (mentions, waits, rule emails) can be replied to"
  end

  test "both copies of the slipdock skill explain kind reply in the log" do
    installed = Path.expand("~/.claude/skills/slipdock/SKILL.md")

    for path <- [Path.join(@root, "priv/skills/slipdock/SKILL.md"), installed],
        File.exists?(path) do
      assert File.read!(path) =~ ~s(kind "reply" = a reply to a notification email)
    end
  end
end
