defmodule Slipdock.RegexUnicodeTest do
  @moduledoc """
  A regex over card, comment or page text reads characters: it has the `u`
  flag (#2593, after #2019).

  Without `u` a regex reads bytes, and on OTP 27 (CI's and the release's;
  PCRE with Latin-1 tables) `\\w`, `\\W`, `\\b`, `\\B` and the POSIX classes
  count the lead byte of every multi-byte UTF-8 character as a letter and its
  continuation bytes as not one. So `~r/\\w+/` takes `caf` and half the `é` of
  "café", and that half character reaching JSON is a 500. OTP 28 and later
  (PCRE2) keep `\\w` to ASCII and never show it, so a test of the behaviour
  alone can pass on a newer OTP and fail only in CI: this check reads the
  source instead.

  It flags every `~r` sigil, and every `Regex.compile`/`compile!` of a
  literal pattern, in `lib/` that uses one of those classes without `u`.
  Whether a regex reads user text is a matter of where its input comes from,
  which a scan can't follow, so a flagged regex either gets `u` or is listed
  in `@bytes` below with what it reads and why that is never card, comment
  or page text.

  Not flagged: `.`, `[^…]`, `\\S` and `\\D` read any byte, but they cut a
  character only when a count or a lone capture ends inside one, and that
  depends on what follows the class (a `[^\\]]*` ends at the `]`), not on the
  class. Telling those apart needs the regex's grammar and its input: the
  audit for #2593 read them by hand.

  Adding `u` also makes `\\d` match any decimal digit (`٣`), which
  `String.to_integer/1` refuses: a capture that becomes a number is written
  `[0-9]` in a `u` regex.
  """
  use ExUnit.Case, async: true

  @machine_messages "Ecto's own validation messages: `%{key}` names an atom, never user text"

  # {file, the regex's source as written} => what it reads instead.
  @bytes %{
    {"lib/slipdock/boards.ex", "%{(\\w+)}"} => @machine_messages,
    {"lib/slipdock/portable/import.ex", "%{(\\w+)}"} => @machine_messages,
    {"lib/slipdock/runners/config.ex", "%{(\\w+)}"} => @machine_messages,
    {"lib/slipdock/runners/machine_runners.ex", "%{(\\w+)}"} => @machine_messages,
    {"lib/slipdock_web/controllers/api/json.ex", "%{(\\w+)}"} => @machine_messages,
    {"lib/slipdock/deployments.ex", "#(\\d+)\\b"} =>
      "a deploy's commit messages, not card text; captures ASCII digits only",
    {"lib/slipdock_web/mcp/tools/download_file.ex", "\\A[\\w.-]+\\z"} =>
      "validates a whole filename (\\A…\\z) and returns nothing; ASCII on purpose",
    {"lib/slipdock/runners/transcript_summary.ex",
     "^(mix test|npm (run )?test|npx playwright|pytest|go test|cargo test)\\b"} =>
      "a runner's command lines, tested only",
    {"lib/slipdock/runners/transcript_summary.ex",
     "^(mix (compile|format|credo|pre_push|sobelow|dialyzer|hex\\.audit|deps\\.audit)|npx (eslint|tsc))\\b"} =>
      "a runner's command lines, tested only",
    {"lib/slipdock/runners/transcript_summary.ex", "^gh (pr checks|run (watch|view|list))\\b"} =>
      "a runner's command lines, tested only",
    {"lib/slipdock/runners/transcript_summary.ex", "^(git|gh)\\b"} =>
      "a runner's command lines, tested only",
    {"lib/slipdock/runners/transcript_summary.ex", "^slipdock\\b"} =>
      "a runner's command lines, tested only",
    {"lib/slipdock/runners/transcript_summary.ex",
     "^(cat|sed -n|grep|rg|ls|find|head|tail|wc|less|tree|awk)\\b"} =>
      "a runner's command lines, tested only",
    {"lib/slipdock/runners/transcript_summary.ex",
     "^(([A-Z_][A-Z0-9_]*=\\S*|time|timeout \\d+\\w?)\\s+)+"} =>
      "a runner's command lines: strips a leading env assignment, which ends at whitespace"
  }

  # A runner's transcript is what its terminal printed, and `u` raises on a
  # byte that isn't UTF-8: the secret patterns read bytes, and match only
  # ASCII token alphabets, so a redaction never ends inside a character.
  @transcript "lib/slipdock/runners/transcript.ex"
  @transcript_reason "a runner's raw transcript, which may not be UTF-8; ASCII token alphabets"

  @word_class ~r/\\[wWbB]|\[:\^?[a-z]+:\]/

  @doc false
  # The flagged regexes in `source`: [{line, regex source}].
  def flagged(source) do
    {_, hits} =
      source
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn node, acc -> {node, hit(regex(node)) ++ acc} end)

    Enum.reverse(hits)
  end

  defp hit({line, src, false}), do: if(reads_bytes?(src), do: [{line, src}], else: [])
  defp hit(_), do: []

  defp regex({:sigil_r, meta, [{:<<>>, _, parts}, mods]}),
    do: {meta[:line], literal(parts), ?u in mods}

  defp regex({{:., meta, [{:__aliases__, _, [:Regex]}, fun]}, _, [src | opts]})
       when fun in [:compile, :compile!] do
    {meta[:line], literal(src), unicode_opts?(opts)}
  end

  defp regex(_), do: nil

  # The pattern's literal text, an interpolation or a variable as `#{…}`.
  defp literal(parts) when is_list(parts), do: Enum.map_join(parts, &literal/1)
  defp literal(part) when is_binary(part), do: part
  defp literal({:<<>>, _, parts}), do: literal(parts)
  defp literal({:<>, _, [a, b]}), do: literal(a) <> literal(b)
  defp literal(_), do: "\#{…}"

  defp unicode_opts?([opts | _]) when is_binary(opts), do: String.contains?(opts, "u")
  defp unicode_opts?([opts | _]) when is_list(opts), do: :unicode in opts
  defp unicode_opts?(_), do: false

  # An escaped backslash (`\\w` is a backslash and a w) reads no class.
  defp reads_bytes?(src), do: src |> String.replace("\\\\", "") |> then(&(&1 =~ @word_class))

  defp all_flagged do
    for path <- Path.wildcard("lib/**/*.{ex,exs}"),
        {line, src} <- flagged(File.read!(path)),
        do: {path, line, src}
  end

  defp excused?(path, src), do: path == @transcript or Map.has_key?(@bytes, {path, src})

  test "every \\w-style regex in lib/ reads characters, or says why it reads bytes" do
    hits =
      for {path, line, src} <- all_flagged(),
          not excused?(path, src),
          do: "#{path}:#{line}: ~r{#{src}}"

    assert hits == [], """
    These regexes use \\w, \\W, \\b, \\B or a POSIX class without the u flag. On OTP 27
    they cut a multi-byte character in two, and half a character in JSON is a 500.
    Add u (and write a captured number as [0-9]: with u, \\d matches ٣ too), or, if
    the regex never reads card, comment or page text, list it in @bytes in
    #{__ENV__.file} with what it reads:

    #{Enum.join(hits, "\n")}
    """
  end

  test "every listed exception is still in lib/ without u" do
    found = MapSet.new(all_flagged(), fn {path, _, src} -> {path, src} end)
    stale = for key <- Map.keys(@bytes), key not in found, do: key

    assert stale == [],
           "Remove these from @bytes: the regex is gone, or reads characters now:\n" <>
             Enum.map_join(stale, "\n", &inspect/1)

    assert Enum.any?(found, fn {path, _} -> path == @transcript end),
           "#{@transcript} has no byte regex left: drop @transcript (#{@transcript_reason})"
  end

  describe "the scan" do
    test "finds a word class, a boundary or a POSIX class without u" do
      assert [{1, "@(\\w+)"}] = flagged(~S|x = ~r/@(\w+)/|)
      assert [{1, "\\bsprint"}] = flagged(~S|x = ~r/\bsprint/i|)
      assert [{1, "\\W{0,3}"}] = flagged(~S|x = ~r/\W{0,3}/|)
      assert [{1, "[[:alpha:]]+"}] = flagged(~S|x = ~r/[[:alpha:]]+/|)
      assert [{2, "a\\Bb"}] = flagged("x = 1\ny = ~r\"a\\Bb\"m")
    end

    test "passes one with u, and one with none of the classes" do
      assert flagged(~S|x = ~r/@(\w+)/u|) == []
      assert flagged(~S|x = ~r/@(\w+)/iu|) == []
      assert flagged(~S|x = ~r/^[a-z0-9]+(\.\d+)?\s*$/|) == []
      # An escaped backslash before a w is a literal backslash and a w.
      assert flagged(~S|x = ~r/C:\\windows/|) == []
    end

    test "reads Regex.compile's pattern and options" do
      assert [{1, "(?<!\\w)x"}] = flagged(~S|Regex.compile!("(?<!\\w)x", "i")|)
      assert [{1, "\\b(?:\#{…})\\b"}] = flagged(~S|Regex.compile!("\\b(?:#{alts})\\b")|)
      assert [{1, "\\bx\#{…}"}] = flagged(~S|Regex.compile("\\bx" <> @rest)|)
      assert flagged(~S|Regex.compile!("\\bx", "iu")|) == []
      assert flagged(~S|Regex.compile!("\\bx", [:unicode])|) == []
      # A pattern from a variable has no literal text to read.
      assert flagged(~S|Regex.compile(pattern)|) == []
    end
  end
end
