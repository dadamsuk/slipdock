defmodule SlipdockWeb.BoardHandlesTitleTest do
  @moduledoc """
  `board_handles_title/3`, the tooltip on a board's name (#1716): its lead
  line, code, switcher key and hotkey, one per line, with a missing or empty
  lead left out rather than drawn as a blank first line (#2727).
  """
  use ExUnit.Case, async: true

  import SlipdockWeb.SlipdockComponents, only: [board_handles_title: 1, board_handles_title: 3]

  @board %{code: "kbe2e", shortcut: "k"}

  test "the lead, code, switcher key and hotkey, one line each" do
    assert board_handles_title(@board, "Release work", 3) ==
             "Release work\nCode: kbe2e\nSwitcher: b then k\nCtrl+Shift+3 opens it from any page"
  end

  test "an empty lead, as a board with a blank description gives, leaves no blank first line" do
    title = board_handles_title(@board, "", nil)

    assert title == "Code: kbe2e\nSwitcher: b then k"
    refute String.starts_with?(title, "\n")
  end

  test "no lead at all is the same as an empty one" do
    assert board_handles_title(@board) == board_handles_title(@board, "", nil)
  end

  test "a board with no code or shortcut gives only the lead" do
    assert board_handles_title(%{code: nil}, "Board settings", nil) == "Board settings"
    assert board_handles_title(%{}, "", nil) == ""
  end
end
