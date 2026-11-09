defmodule SlipdockCLI.FlagAttentionTest do
  @moduledoc "`slipdock card`'s Flags line says who clears each flag (#2624)."
  use ExUnit.Case, async: true

  alias SlipdockCLI.Render

  test "each flag on its own line, with who clears it and why" do
    attention = %{
      "review" => %{"attention" => "auto", "why" => "A verifier agent checks it and decides."},
      "waiting" => %{"attention" => "person", "why" => "Waits on a person's answer."},
      "starred" => %{"attention" => "none", "why" => "A bookmark: asks nothing of anyone."}
    }

    assert Render.flags_text(~w(review waiting starred), attention) ==
             "review · clears itself: A verifier agent checks it and decides.\n" <>
               String.duplicate(" ", 14) <>
               "waiting · needs a person: Waits on a person's answer.\n" <>
               String.duplicate(" ", 14) <> "starred · A bookmark: asks nothing of anyone."
  end

  test "no flags is a dash" do
    assert Render.flags_text([], %{}) == "-"
    assert Render.flags_text(nil, nil) == "-"
  end

  test "a server older than flag_attention gets the flags on one line" do
    assert Render.flags_text(~w(review blocked), nil) == "review, blocked"
    assert Render.flags_text(~w(review blocked), %{}) == "review, blocked"
  end

  test "a flag the server gave no attention for is shown bare" do
    attention = %{"review" => %{"attention" => "auto", "why" => "Merging."}}

    assert Render.flags_text(~w(review later), attention) =~
             ~r/review · clears itself: Merging.\n +later$/
  end
end
