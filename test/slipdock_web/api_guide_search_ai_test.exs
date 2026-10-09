defmodule SlipdockWeb.APIGuideSearchAITest do
  @moduledoc """
  What the agent guide says about whose AI search runs on. An agent once read
  "semantic search's answers" as running on its own key, and concluded search
  was broken when the server's AI was missing. The guide must say search is
  the server's, and what to do when it is not set up.
  """
  # The guide reads the server's settings (meeting mode), so it needs the sandbox.
  use Slipdock.DataCase, async: true

  setup do
    # Wrapping and indentation are the guide's business; the words are ours.
    %{guide: SlipdockWeb.APIGuide.markdown() |> String.split() |> Enum.join(" ")}
  end

  test "search runs on the server's AI, chosen by an admin, not the caller's", %{guide: guide} do
    assert guide =~ "**Search is the exception.**"
    assert guide =~ "Configuration → AI for search and automations"
    assert guide =~ "`embed_model` is read only for the admin chosen there"
    refute guide =~ "semantic search's answers"
  end

  test "an agent is told not to retry or ask the user for a key", %{guide: guide} do
    assert guide =~ "Semantic search isn't set up on this server"
    assert guide =~ "do not retry or ask them for a key"
  end
end
