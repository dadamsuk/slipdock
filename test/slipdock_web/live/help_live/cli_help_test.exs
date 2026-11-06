defmodule SlipdockWeb.HelpLive.CLIHelpTest do
  @moduledoc """
  The CLI's help parsed for the web's command reference (#1884): groups by
  their capitals, entries by their indent, each entry's command split from
  its description, and the filter. The real help is checked in full by the
  LiveView test; these pin the layouts it has to cope with.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.HelpLive.CLIHelp

  # The card's list (#1884), in the help's order.
  @groups ["START HERE", "FIND ANYTHING", "AUTH", "ADMIN", "READ", "FAVOURITES", "WIKI"] ++
            ["FOLDERS", "YOUR WIKI", "SYNC", "SKILLS", "TOOLS", "MEETINGS", "WRITE"] ++
            ["VIEW OPTIONS", "VALUES", "OUTPUT"]

  test "the real help has every group, in its order, after USAGE" do
    parsed = CLIHelp.parse(CLIHelp.text())

    assert Enum.map(parsed.groups, & &1.name) == @groups
    assert parsed.usage == ["slipdock <command> [args] [--json] [--url URL]"]
    assert parsed.title =~ "slipdock — read and write cards"
    assert Enum.all?(parsed.groups, &(&1.entries != []))
  end

  test "the text is the CLI's own file" do
    assert CLIHelp.text() == File.read!("cli/help.txt")
  end

  test "a group's note runs on until its parenthesis closes" do
    %{groups: [g, next]} =
      CLIHelp.parse("""
      title

      FIND ANYTHING  (semantic: matched by meaning,
                      over two lines)
        search <words...>                   search every board

      VIEW OPTIONS (one line)
        --view V              start from a saved view
      """)

    assert g.id == "cli-find-anything"
    assert g.title == "Find anything"
    assert g.note == "(semantic: matched by meaning, over two lines)"
    assert [%{usage: "search <words...>", desc: "search every board"}] = g.entries
    assert next.note == "(one line)"
    assert [%{usage: "--view V", desc: "start from a saved view"}] = next.entries
  end

  test "an entry at the left edge is an entry, not a heading" do
    %{groups: [g]} =
      CLIHelp.parse("""
      title
      ADMIN  (needs an admin token)
      admin settings                      what this server allows
      admin approve|reject <email>
      """)

    assert Enum.map(g.entries, & &1.usage) == ["admin settings", "admin approve|reject <email>"]
    assert Enum.map(g.entries, & &1.desc) == ["what this server allows", ""]
  end

  test "descriptions carry on, options are kept verbatim and dedented" do
    %{groups: [%{entries: [e]}]} =
      CLIHelp.parse("""
      title
      READ
        cards <board> [filters]             list cards on a board,
                                            all of them
            --column C  --tag T
              --open
      """)

    assert e.usage == "cards <board> [filters]"
    assert e.desc == "list cards on a board, all of them"
    assert e.details == ["--column C  --tag T", "  --open"]
  end

  test "a command that runs into its description with one space is still split" do
    %{groups: [%{entries: entries}]} =
      CLIHelp.parse("""
      title
      WRITE
        blocked-by <id> <card-id>... [--off] mark <id> as waiting on other cards, on any
                                            board you can read
        update-view <board> <view> [view opts] [--name N] change a saved view
        set-automation <board> <rule> [--on|--off] [--name N]
                                               [--tree|--no-tree] also watch subcards
        pause <board> --reason "…"          hold the runner work
        accept <id> [--reason TEXT]  |  reject <id> --reason TEXT
                                            the same as verify
      """)

    assert Enum.map(entries, &{&1.usage, &1.desc}) == [
             {"blocked-by <id> <card-id>... [--off]",
              "mark <id> as waiting on other cards, on any board you can read"},
             {"update-view <board> <view> [view opts] [--name N]", "change a saved view"},
             {"set-automation <board> <rule> [--on|--off] [--name N] [--tree|--no-tree]",
              "also watch subcards"},
             {~s(pause <board> --reason "…"), "hold the runner work"},
             {"accept <id> [--reason TEXT]  |  reject <id> --reason TEXT", "the same as verify"}
           ]
  end

  test "chunks/1 keeps each [ … ] and quoted part whole, so a line wraps between options" do
    assert CLIHelp.chunks(~s(wait <id> "what you need" [--on EMAIL] [--folder F | --no-folder])) ==
             ["wait", "<id>", ~s("what you need"), "[--on EMAIL]", "[--folder F | --no-folder]"]

    assert CLIHelp.chunks("repeat <id> [--a [--b c]] x") == [
             "repeat",
             "<id>",
             "[--a [--b c]]",
             "x"
           ]

    assert CLIHelp.chunks("done <id>...  |  undone <id>...") ==
             ["done", "<id>...", "|", "undone", "<id>..."]
  end

  describe "filter/2" do
    setup do
      %{groups: CLIHelp.parse(CLIHelp.text()).groups}
    end

    test "an empty query keeps everything", %{groups: groups} do
      assert CLIHelp.filter(groups, "") == groups
      assert CLIHelp.filter(groups, "   ") == groups
      assert CLIHelp.filter(groups, nil) == groups
    end

    test "keeps the commands whose usage matches, whatever the case, and drops empty groups",
         %{groups: groups} do
      filtered = CLIHelp.filter(groups, "  PAGE LS ")

      assert [%{name: "WIKI", entries: [%{usage: "page ls" <> _}]}] = filtered
    end

    test "matches the command, not its description", %{groups: groups} do
      # "permanently delete" is delete's description, not its usage.
      assert CLIHelp.filter(groups, "permanently") == []
    end
  end
end
