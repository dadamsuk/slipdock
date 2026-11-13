defmodule Slipdock.ToolCliFlagsTest do
  @moduledoc """
  Every `slipdock …` flag a Tool's recurring card tells an agent to use is
  one the command it is given to reads (#2779, #2904): a card whose
  procedure names a flag the CLI doesn't have fails every run (`unknown
  option(s)`), and one that names a flag of another command (`add --list`)
  is ignored or refused.

  What a command reads is its entry in `cli/help.txt`, the CLI's usage text
  (`slipdock help` prints it, and the web app's command reference reads it):
  the `--flags` on the entry's lines. Each is also checked against the CLI's
  parse list, `@switches` in `cli/lib/slipdock_cli.ex`. Both are read as
  files, since the CLI is a project of its own.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Flags every command takes (`slipdock <command> [args] [--json] [--url URL]`).
  @global ~w(json url help)

  # A bare flag span (`--message "…"`) belongs to the nearest `slipdock`
  # span before it on its own line (a numbered step). One with none there
  # is named here: {card title, span} => the command it extends.
  @bare %{
    {"Sweep the code", ~s(`--message "#<this card> sweep <area> × <lens>"`)} => ~w(page section),
    {"Reconcile the handbook", ~s(`--message "#<this card> reconcile <range>"`)} =>
      ~w(page section),
    {"Triage findings", ~s(`--message "#<this card> triage"`)} => ~w(page section)
  }

  defp switches do
    source = File.read!(Path.join(@root, "cli/lib/slipdock_cli.ex"))
    [_, list] = Regex.run(~r/@switches \[(.*?)\n  \]/s, source)

    ~r/^\s*([a-z_]+): :/m
    |> Regex.scan(list)
    |> Enum.map(fn [_, name] -> String.replace(name, "_", "-") end)
    |> MapSet.new()
  end

  @doc false
  # The flags each command's help entry names: %{["page", "section"] => set}.
  # An entry starts on a line at indent 0 or 2 with the command's name
  # (`  page section <page> <path>`, `  finding <id> dismiss|promote|reopen`)
  # and runs on over the more deeply indented lines under it. A command
  # with several entries reads the flags of them all.
  def help_flags(help) do
    help
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        cond do
          entry?(line) and acc != nil -> {:cont, acc, {line, [line]}}
          entry?(line) -> {:cont, {line, [line]}}
          acc != nil and continuation?(line) -> {:cont, put_elem(acc, 1, [line | elem(acc, 1)])}
          acc != nil -> {:cont, acc, nil}
          true -> {:cont, nil}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reduce(%{}, fn {head, lines}, map ->
      flags = lines |> Enum.join("\n") |> flags_in() |> MapSet.new()

      head
      |> entry_names()
      |> Enum.reduce(map, fn name, map ->
        Map.update(map, name, flags, &MapSet.union(&1, flags))
      end)
    end)
  end

  defp entry?(line), do: Regex.match?(~r/^ {0,2}[a-z]/, line)
  defp continuation?(line), do: Regex.match?(~r/^ {3,}\S/, line)

  # `finding <id> dismiss|promote|reopen  …` => [~w(finding dismiss), ~w(finding promote), …]:
  # its literal words up to the first flag, option group or the gap before
  # the description, the placeholders (`<id>`) left out.
  defp entry_names(head) do
    [usage | _] = head |> String.trim() |> String.split(~r/\s{2,}/, parts: 2)

    usage
    |> String.split()
    |> Enum.take_while(&(not String.starts_with?(&1, ["--", "[", "("])))
    |> Enum.filter(&Regex.match?(~r/^[a-z][a-z-]*(\|[a-z][a-z-]*)*$/, &1))
    |> Enum.map(&String.split(&1, "|"))
    |> Enum.reduce([[]], fn alts, acc -> for name <- acc, alt <- alts, do: name ++ [alt] end)
  end

  defp flags_in(text) do
    for [_, flag] <- Regex.scan(~r/(?:^|[\s\[(|`])--([a-z][a-z-]*)/, text), uniq: true, do: flag
  end

  @doc false
  # Each `slipdock …` span of a card's text and each bare one that starts
  # with a flag, with the command it is given to and the flags it names:
  # [{span, ["page", "section"] | {:bare, span}, ["message"]}]. A bare span
  # takes the command of the nearest `slipdock` span before it on its line.
  def uses(text), do: text |> String.split("\n") |> Enum.flat_map(&line_uses/1)

  defp line_uses(line) do
    ~r/`(?:slipdock |--)[^`]*`/
    |> Regex.scan(line)
    |> Enum.map_reduce(nil, &span_use/2)
    |> elem(0)
  end

  defp span_use([span], last) do
    flags = for [_, f] <- Regex.scan(~r/(?:^`|\s)--([a-z][a-z-]*)/, span), uniq: true, do: f

    case span do
      "`slipdock " <> rest ->
        words = command_words(rest)
        {{span, words, flags}, words}

      _ ->
        {{span, last || {:bare, span}, flags}, last}
    end
  end

  # `add <board> "<what is wrong, where>" --column …` => ["add"]: the words
  # before the first flag, its placeholders and quoted arguments left out.
  defp command_words(rest) do
    rest
    |> String.replace(~r/"[^"]*"|<[^>]*>/, " ")
    |> String.trim_trailing("`")
    |> String.split()
    |> Enum.take_while(&(not String.starts_with?(&1, "-")))
    |> Enum.filter(&Regex.match?(~r/^[a-z][a-z-]*$/, &1))
  end

  @doc false
  # The help entry a span's words name: the longest one they start with.
  def command(words, help) do
    help
    |> Map.keys()
    |> Enum.filter(&(&1 != [] and List.starts_with?(words, &1)))
    |> Enum.max_by(&length/1, fn -> nil end)
  end

  @doc false
  # What is wrong with one card's flags, as messages; [] when nothing is.
  def problems(title, text, help, known) do
    for {span, cmd, flags} <- uses(text),
        problem <- check(title, span, cmd, flags, help, known),
        do: problem
  end

  defp check(title, span, {:bare, _}, flags, help, known) do
    case Map.fetch(@bare, {title, span}) do
      {:ok, words} ->
        check(title, span, words, flags, help, known)

      :error ->
        ["“#{title}”: #{span} has no `slipdock` command before it on its line; name it in @bare"]
    end
  end

  defp check(title, span, words, flags, help, known) do
    case command(words, help) do
      nil ->
        [
          "“#{title}”: #{span} names `slipdock #{Enum.join(words, " ")}`, which cli/help.txt has no entry for"
        ]

      cmd ->
        reads = help |> Map.fetch!(cmd) |> MapSet.union(MapSet.new(@global))

        for flag <- flags, not (MapSet.member?(reads, flag) and MapSet.member?(known, flag)) do
          "“#{title}”: #{span} gives `slipdock #{Enum.join(cmd, " ")}` --#{flag}, which it doesn't read"
        end
    end
  end

  defp help, do: help_flags(File.read!(Path.join(@root, "cli/help.txt")))

  defp descriptions do
    [Slipdock.Sweep.blueprint(), Slipdock.Handbook.blueprint()]
    |> Enum.flat_map(& &1["cards"])
    |> Enum.map(&{&1["title"], &1["description"] || ""})
  end

  test "every flag a Tool's card names is one the command it is given to reads" do
    help = help()
    known = switches()
    assert MapSet.member?(help[["add"]], "column")
    assert MapSet.member?(help[["page", "section"]], "message")
    assert MapSet.member?(help[["finding", "merge"]], "into")

    assert Enum.flat_map(descriptions(), fn {title, text} ->
             problems(title, text, help, known)
           end) == []
  end

  test "every @bare entry names a span its card still has" do
    for {{title, span}, _} <- @bare do
      {_, text} = Enum.find(descriptions(), fn {t, _} -> t == title end)
      assert String.contains?(text, span), "“#{title}” no longer has #{span}"
    end
  end

  describe "a flag held to its command" do
    setup do: %{help: help(), known: switches()}

    test "another command's flag is caught (add --list)", %{help: help, known: known} do
      # `list` is a switch (`multiboard --list`), just not one `add` reads.
      assert MapSet.member?(known, "list")

      assert [message] =
               problems("T", ~s(run `slipdock add <board> "x" --list Housekeeping`), help, known)

      assert message =~ "slipdock add` --list"
    end

    test "the swap the card names, in the Triage card itself", %{help: help, known: known} do
      {_, text} = Enum.find(descriptions(), fn {t, _} -> t == "Triage findings" end)
      assert problems("Triage findings", text, help, known) == []

      swapped =
        String.replace(
          text,
          "--column Housekeeping --origin findings`",
          "--list Housekeeping --origin findings`"
        )

      assert swapped != text
      assert [message] = problems("Triage findings", swapped, help, known)
      assert message =~ "--list"
    end

    test "a bare span takes the command before it on its line", %{help: help, known: known} do
      text = "file it: `slipdock add <board> \"x\"`, in Triage (`--column Triage --origin sweep`)"
      assert [{_, ["add"], ~w()}, {_, ["add"], ~w(column origin)}] = uses(text)
      assert problems("T", text, help, known) == []

      bad = "file it: `slipdock add <board> \"x\"`, in Triage (`--list Triage`)"
      assert [message] = problems("T", bad, help, known)
      assert message =~ "add` --list"
    end

    test "a bare span with no command on its line must be named", %{help: help, known: known} do
      text = "`slipdock add B \"x\"`\nthen `--message \"m\"`"
      assert [message] = problems("T", text, help, known)
      assert message =~ "@bare"
    end

    test "a command help.txt has no entry for is caught", %{help: help, known: known} do
      assert [message] = problems("T", "`slipdock frobnicate <board> --column X`", help, known)
      assert message =~ "no entry"
    end

    test "a flag nothing parses is caught (a typo)", %{help: help, known: known} do
      assert [message] =
               problems("T", "`slipdock add B \"x\" --column C --orign sweep`", help, known)

      assert message =~ "--orign"
    end

    test "a flag help.txt names but the CLI doesn't parse is caught", %{known: known} do
      # help.txt can run ahead of (or behind) @switches: a flag an entry
      # names is still refused unless the CLI parses it too.
      help = %{["add"] => MapSet.new(~w(column made-up))}
      refute MapSet.member?(known, "made-up")
      assert problems("T", "`slipdock add B \"x\" --column C`", help, known) == []

      assert [message] = problems("T", "`slipdock add B \"x\" --made-up y`", help, known)
      assert message =~ "--made-up"
    end

    test "a subcommand and its alternatives are told apart", %{help: help} do
      assert command(~w(finding dismiss), help) == ~w(finding dismiss)
      assert command(~w(finding promote), help) == ~w(finding promote)
      assert command(~w(garden propose), help) == ~w(garden propose)
      assert command(~w(page section), help) == ~w(page section)
      refute MapSet.member?(help[["page", "section"]], "summary")
      assert MapSet.member?(help[["page", "edit"]], "summary")
    end
  end

  describe "help_flags/1" do
    test "an entry runs over its indented lines, and ends at the next" do
      help = """
      WRITE
        add <board> <title> [opts]          create a card
            --column C  --desc TEXT
        edit <id> [--title T]               change a card
      admin allow <entry>                   let an address in
            --note N
      """

      flags = help_flags(help)
      assert flags[["add"]] == MapSet.new(~w(column desc))
      assert flags[["edit"]] == MapSet.new(~w(title))
      assert flags[["admin", "allow"]] == MapSet.new(~w(note))
    end

    test "alternatives make an entry each, and a repeated command adds up" do
      help = """
        finding <id> dismiss|promote [--note TEXT]
        finding <id> merge --into ID      fold a repeat
        page section <page> <path> --append TEXT
        page section <page> <path> --body -  [--message M]
      """

      flags = help_flags(help)
      assert flags[["finding", "dismiss"]] == MapSet.new(~w(note))
      assert flags[["finding", "promote"]] == MapSet.new(~w(note))
      assert flags[["finding", "merge"]] == MapSet.new(~w(into))
      # Each entry brings its own flags; the command reads them all.
      assert flags[["page", "section"]] == MapSet.new(~w(append body message))
    end

    test "a line that is neither entry nor continuation ends the entry" do
      for gap <- ["", "WRITE"] do
        help =
          "  add <board> <title>   create a card\n      --column C\n#{gap}\n      --stray X\n"

        assert help_flags(help)[["add"]] == MapSet.new(~w(column)), "gap #{inspect(gap)}"
      end
    end

    test "a flag line at indent 2 is not a continuation" do
      # cli/help.txt lists shared flags (`--view`, `--group`, `--json`) at
      # indent 2 under a section; they belong to no entry before them.
      help = "  cards <board> [opts]   list cards\n      --column C\n  --view V   one view\n"
      assert help_flags(help)[["cards"]] == MapSet.new(~w(column))
    end
  end
end
