defmodule SlipdockWeb.APIGuideCommentAccessTest do
  @moduledoc """
  What the agent guide says about the comment level (#863): that it exists,
  what a commenter may do, and the two refusals an agent will meet — so a
  403 on a field edit is read as the grant it is, not a fault to work around.
  """
  # The guide reads the server's settings (meeting mode), so it needs the sandbox.
  use Slipdock.DataCase, async: true

  setup do
    %{guide: SlipdockWeb.APIGuide.markdown() |> String.split() |> Enum.join(" ")}
  end

  test "comment is a share level, between read and write", %{guide: guide} do
    assert guide =~ "**Comment access** (#863) sits between read and write"
    assert guide =~ "`read`, `comment` or `write`"
  end

  test "it names what a commenter may do and the refusals for the rest", %{guide: guide} do
    assert guide =~ "comment (`POST …/comments`), report a status (`POST …/status`)"
    assert guide =~ "`403 you don't edit this card`"
    assert guide =~ "`403 you don't comment on this card`"
  end
end
