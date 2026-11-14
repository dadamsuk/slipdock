defmodule Slipdock.FeatureDigestCommandsTest do
  @moduledoc """
  Every `slipdock <command>` the feature digest
  (`docs/manual/every-feature-in-brief.md`) gives as an example is one the
  CLI has (#3133): its entry in `cli/help.txt` (`Slipdock.CLIHelp`), the
  usage text `slipdock help` prints. Before this only the digest's links
  were held by a test, so a misspelt command (`slipdock wiats 12`) passed.

  A command is the span's words before its first flag or `-`, with
  numbers, placeholders (`<board>`) and quoted arguments left out; `a|b`
  gives a command each. It must start with a help entry, and
  where that entry has subcommands (`tools install`, `tools download`) the
  next word must be one of them, so `slipdock tools instal` is caught too.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @digest "docs/manual/every-feature-in-brief.md"

  defp digest, do: File.read!(Path.join(@root, @digest))
  defp help, do: Slipdock.CLIHelp.help_flags(Slipdock.CLIHelp.read!())

  @doc false
  # Each `slipdock …` span in the text, with the commands it names:
  # [{span, [["runner", "ls"], ["runner", "show"]]}].
  def spans(text) do
    for [span, rest] <- Regex.scan(~r/`slipdock ([^`]*)`/, text), do: {span, commands(rest)}
  end

  defp commands(rest) do
    rest
    |> String.replace(~r/"[^"]*"|<[^>]*>/, " ")
    |> String.split()
    |> Enum.take_while(&(not String.starts_with?(&1, "-")))
    |> Enum.filter(&Regex.match?(~r/^[a-z][a-z-]*(\|[a-z][a-z-]*)*$/, &1))
    |> Enum.map(&String.split(&1, "|"))
    |> Enum.reduce([[]], fn alts, acc -> for name <- acc, alt <- alts, do: name ++ [alt] end)
  end

  @doc false
  # What is wrong with the text's commands, as messages; [] when nothing is.
  def problems(text, help) do
    for {span, commands} <- spans(text),
        words <- commands,
        problem <- check(span, words, help),
        do: problem
  end

  defp check(span, [], _help), do: ["#{span} names no command"]

  defp check(span, words, help) do
    case Slipdock.CLIHelp.command(words, help) do
      nil ->
        [
          "#{span}: `slipdock #{Enum.join(unknown(words, help), " ")}` has no entry in cli/help.txt"
        ]

      entry ->
        next = Enum.drop(words, length(entry))

        if next != [] and subcommands?(entry, help) do
          [
            "#{span}: `slipdock #{Enum.join(entry ++ [hd(next)], " ")}` has no entry in cli/help.txt"
          ]
        else
          []
        end
    end
  end

  # The words up to the first one no entry goes on with: `runner shwo`
  # where help.txt has `runner show` but no `runner` of its own.
  defp unknown(words, help) do
    known =
      Enum.find(length(words)..1//-1, 0, fn n ->
        prefix = Enum.take(words, n)
        Enum.any?(Map.keys(help), &List.starts_with?(&1, prefix))
      end)

    Enum.take(words, known + 1)
  end

  defp subcommands?(entry, help) do
    Enum.any?(Map.keys(help), &(length(&1) > length(entry) and List.starts_with?(&1, entry)))
  end

  test "every slipdock command the feature digest gives is one cli/help.txt has" do
    spans = spans(digest())
    # The digest gives dozens; a pattern that found none would pass vacuously.
    assert length(spans) > 40
    assert {"`slipdock waits 12`", [["waits"]]} in spans
    assert problems(digest(), help()) == []
  end

  describe "a misspelt command in the digest" do
    setup do: %{help: help(), text: digest()}

    test "fails, the command itself (waits => wiats)", %{help: help, text: text} do
      bad = String.replace(text, "`slipdock waits 12`", "`slipdock wiats 12`")
      assert bad != text
      assert [message] = problems(bad, help)
      assert message =~ "`slipdock wiats` has no entry"
    end

    test "fails, a subcommand (tools install => tools instal)", %{help: help, text: text} do
      bad =
        String.replace(text, "`slipdock tools install <name>`", "`slipdock tools instal <name>`")

      assert bad != text
      assert [message] = problems(bad, help)
      assert message =~ "`slipdock tools instal` has no entry"
    end

    test "fails, one alternative of several (runner ls|shwo)", %{help: help} do
      assert problems("`slipdock runner ls|show`", help) == []
      assert [message] = problems("`slipdock runner ls|shwo`", help)
      assert message =~ "`slipdock runner shwo`"
    end

    test "fails, a span with no command at all", %{help: help} do
      assert ["`slipdock --json` names no command"] = problems("`slipdock --json`", help)
    end
  end

  describe "what is a command and what is an argument" do
    setup do: %{help: help()}

    test "numbers, placeholders, quotes, flags and option groups are left out", %{help: help} do
      assert spans(~s(`slipdock repeat 12 "every mon" --x`)) ==
               [{~s(`slipdock repeat 12 "every mon" --x`), [["repeat"]]}]

      assert [{_, [["quality"]]}] = spans("`slipdock quality <board> [--days N] [--rules]`")
      assert [{_, [["wait"]]}] = spans("`slipdock wait 12 -`")
      # A lone `-` reads stdin: what comes after it is not the command.
      assert [{_, [["wait"]]}] = spans("`slipdock wait 12 - then more`")
      assert problems(~s(`slipdock edit 12 --bar "…"`), help) == []
    end

    test "a word after a command with no subcommands is its argument", %{help: help} do
      # `names [full|short]`: `short` is a value, not a subcommand.
      refute Enum.any?(Map.keys(help), &match?(["names", _ | _], &1))
      assert problems("`slipdock names short`", help) == []
    end
  end

  describe "Slipdock.CLIHelp.help_flags/1" do
    test "a usage of two forms names each, and a bare flag form names nothing" do
      help = """
        hook install lane-check | hook uninstall lane-check
                                         a git pre-commit hook
        incident-of <card> <deploy-id> | --clear    say which deploy
      """

      assert help |> Slipdock.CLIHelp.help_flags() |> Map.keys() |> Enum.sort() ==
               [~w(hook install lane-check), ~w(hook uninstall lane-check), ~w(incident-of)]
    end

    test "the digest's runner ls is one help.txt has, as the CLI does" do
      help = help()
      assert Slipdock.CLIHelp.command(~w(runner ls), help) == ~w(runner ls)

      assert Slipdock.CLIHelp.command(~w(hook install lane-check), help) ==
               ~w(hook install lane-check)
    end
  end
end
