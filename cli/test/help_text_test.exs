defmodule SlipdockCLI.HelpTextTest do
  @moduledoc """
  The help lives in `cli/help.txt` (#1884), so the web's command reference
  can read the same text. `slipdock help` prints that file as it is: moving
  it out of a heredoc changed nothing a person sees. The places a heredoc and
  a plain file could differ are pinned here: escapes, and lines at the left
  edge that a heredoc's indentation strip would have treated differently.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @file_text File.read!(Path.expand("../help.txt", __DIR__))

  test "help and --help print the file, with one newline after it" do
    for args <- [["help"], ["--help"], ["help", "cards"]] do
      assert capture_io(fn -> SlipdockCLI.main(args) end) == @file_text <> "\n",
             "#{inspect(args)} printed something other than help.txt"
    end
  end

  test "the file ends with the one newline the heredoc had, so the output ends as before" do
    assert String.ends_with?(@file_text, "else this host's Tailscale IP :4000)\n")
    refute String.ends_with?(@file_text, "\n\n")
  end

  test "text the heredoc wrote with escapes comes out as it did" do
    help = capture_io(fn -> SlipdockCLI.main(["help"]) end)

    # Written \\d in the heredoc: one backslash on the screen.
    assert help =~ ~S"id in its first group (#(\d+))"
    refute help =~ ~S"(#(\\d+))"
  end

  test "lines and groups keep their place and indentation" do
    lines = capture_io(fn -> SlipdockCLI.main(["help"]) end) |> String.split("\n")

    assert hd(lines) == "slipdock — read and write cards on your Slipdock boards"
    assert "USAGE" in lines
    assert "READ" in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "auth <token>  "))
    assert Enum.any?(lines, &String.starts_with?(&1, "  search <words...>  "))
  end

  test "help says - reads stdin for done --evidence and page section --append (#1966)" do
    assert @file_text =~ "(--evidence - reads it from stdin)"
    assert @file_text =~ "--append - and --body - read the text from stdin"
  end
end
