defmodule Slipdock.DocsTestsStateFactsTest do
  @moduledoc """
  The docs and skill tests hold a doc to the facts a claim states, not to
  its wording (#2794): a whole sentence goes through
  `Slipdock.DocsFacts.assert_states/2`, which needs its commands, flags,
  ids, paths and links, and enough of its key words, near each other, so a
  doc can be reworded without a test edit.

  This keeps them that way. In a docs test (a `*docs*_test.exs`, or a file
  on `test/repo_checks.txt`), an `assert` that matches a sentence (six plain
  words or more, outside code spans) with `=~`, `String.contains?/2`,
  `String.match?/2` or `Regex.match?/2` fails here, naming the file and
  line. The sentence can be a string, a `~s` or a `~r` (its `\s+` and
  escapes read as the text they match), or come through a variable of a
  `for`: a sentence in the list the comprehension walks (a module attribute
  resolved), matched by `assert doc =~ words`, is named by its own line.

  A sentence the server itself sends (an error, an alert's body) is not a
  doc, and stays exact: a `# not a doc` comment on the line, or the one
  above, says so. A `refute` of an old sentence is not covered: it freezes
  nothing. Nor is a sentence bound to a variable with `=`, or passed to a
  helper that does the matching.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @doc false
  # The docs tests: by name, and the repo checks.
  def docs_tests do
    named = Path.wildcard(Path.join(@root, "test/**/*docs*_test.exs"))

    listed =
      for line <- File.read!(Path.join(@root, "test/repo_checks.txt")) |> String.split("\n"),
          line = String.trim(line),
          String.ends_with?(line, "_test.exs"),
          not String.starts_with?(line, ["#", "except"]),
          do: Path.join(@root, line)

    (named ++ listed) |> Enum.uniq() |> Enum.filter(&File.regular?/1) |> Enum.sort()
  end

  @doc false
  # The lines of `source` that assert a doc says a whole sentence.
  def pinned_sentences(source) do
    {ast, comments} =
      Code.string_to_quoted_with_comments!(source,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}},
        unescape: false,
        emit_warnings: false
      )

    excused =
      for %{line: line, text: text} <- comments, text =~ "not a doc", into: MapSet.new() do
        line
      end

    attributes = attributes(ast)
    {_, lines} = Macro.prewalk(ast, [], &collect(&1, &2, attributes))

    lines
    |> Enum.reject(&(MapSet.member?(excused, &1) or MapSet.member?(excused, &1 - 1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The module attributes a file sets, by name: a `for` may walk one.
  defp attributes(ast) do
    {_, found} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.put_new(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp collect({:assert, meta, [claim | _]} = node, acc, _attributes) do
    if pins?(claim, &sentence?/1), do: {node, [meta[:line] | acc]}, else: {node, acc}
  end

  # A `for` whose variable an assert matches a doc against: the sentences
  # in the list it walks are pinned as surely as one written in the assert.
  defp collect({:for, _, clauses} = node, acc, attributes) when is_list(clauses) do
    {generators, rest} = Enum.split_with(clauses, &match?({:<-, _, [_, _]}, &1))

    lines =
      for {:<-, _, [pattern, list]} <- generators,
          matched_through?(rest, variables(pattern)),
          line <- sentence_lines(list, attributes),
          do: line

    {node, lines ++ acc}
  end

  defp collect(node, acc, _attributes), do: {node, acc}

  defp variables(pattern) do
    {_, names} =
      Macro.prewalk(pattern, [], fn
        {name, _, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # Whether an assert in `body` matches something against one of `names`.
  defp matched_through?(body, names) do
    variable? = fn
      {name, _, context} when is_atom(name) and is_atom(context) -> name in names
      _ -> false
    end

    {_, found?} =
      Macro.prewalk(body, false, fn
        {:assert, _, [claim | _]} = node, found? -> {node, found? or pins?(claim, variable?)}
        node, found? -> {node, found?}
      end)

    found?
  end

  # The line of each sentence written in the list a `for` walks.
  defp sentence_lines({:@, _, [{name, _, context}]}, attributes) when is_atom(context),
    do: sentence_lines(Map.get(attributes, name), attributes)

  defp sentence_lines(list, _attributes) do
    {_, lines} =
      Macro.prewalk(list, [], fn
        {_, meta, _} = node, acc ->
          if sentence?(node), do: {node, [meta[:line] | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  # Whether a claim matches a doc against a right side that `pinned?` holds
  # to be a sentence (or the variable carrying one).
  defp pins?({:=~, _, [_, rhs]}, pinned?), do: pinned?.(rhs)

  defp pins?({{:., _, [{:__aliases__, _, [:String]}, fun]}, _, [_, rhs]}, pinned?)
       when fun in [:contains?, :match?],
       do: pinned?.(rhs)

  defp pins?({{:., _, [{:__aliases__, _, [:Regex]}, :match?]}, _, [regex, _]}, pinned?),
    do: pinned?.(regex)

  defp pins?(_, _), do: false

  @doc false
  # A literal (or literals joined with `<>`) of six plain words or more
  # outside its code spans, most of what is there: prose, not a command.
  def sentence?(node) do
    case text(node) do
      nil ->
        false

      text ->
        outside = text |> String.split("`") |> Enum.take_every(2) |> Enum.join(" ")
        tokens = outside |> String.replace(~r/\\[nt]/, " ") |> String.split()
        words = Enum.count(tokens, &(&1 =~ ~r/^[("*]*[A-Za-z][a-z']*[,.;:!?)"*]*$/))
        words >= 6 and words >= 0.6 * length(tokens)
    end
  end

  defp text({:__block__, _, [s]}) when is_binary(s), do: s

  defp text({:<>, _, [a, b]}) do
    with x when is_binary(x) <- text(a), y when is_binary(y) <- text(b), do: x <> y
  end

  defp text({sigil, _, [{:<<>>, _, parts}, _]}) when sigil in [:sigil_s, :sigil_S] do
    if Enum.all?(parts, &is_binary/1), do: Enum.join(parts), else: nil
  end

  # A regex reads as the text it matches: `\s+` is the space between two
  # words, and an escaped mark is the mark.
  defp text({sigil, _, [{:<<>>, _, parts}, _]}) when sigil in [:sigil_r, :sigil_R] do
    if Enum.all?(parts, &is_binary/1) do
      parts
      |> Enum.join()
      |> String.replace(~r/\\s[+*?]?/, " ")
      |> String.replace(~r/\\([^A-Za-z0-9])/, "\\1")
    else
      nil
    end
  end

  defp text(_), do: nil

  test "no docs test pins a whole sentence of a doc" do
    pinned =
      for path <- docs_tests(),
          line <- pinned_sentences(File.read!(path)),
          do: "#{Path.relative_to(path, @root)}:#{line}"

    assert pinned == [],
           "these assert a doc says a whole sentence; use " <>
             "Slipdock.DocsFacts.assert_states/2, or mark server text `# not a doc`:\n" <>
             Enum.join(pinned, "\n")
  end

  test "it finds the docs tests: this card's example among them" do
    tests = Enum.map(docs_tests(), &Path.relative_to(&1, @root))
    assert "test/slipdock_web/lanes_broad_skills_docs_test.exs" in tests
    assert "test/slipdock/nothing_personal_test.exs" in tests
  end

  test "a sentence pinned with =~ or String.contains? is found, by line" do
    source = """
    defmodule X do
      test "x" do
        assert doc =~ "Install it only when the person says yes"
        assert String.contains?(doc, "Install it only when the person says yes")
        assert(doc =~ "Keep them " <> "as narrow as the brief allows", "msg")
      end
    end
    """

    assert pinned_sentences(source) == [3, 4, 5]
  end

  test "facts, commands, refutes, assert_states and server text are not" do
    source = """
    defmodule X do
      test "x" do
        assert doc =~ "`slipdock done <id> --pr <url>`"
        assert doc =~ "set-column <board> <column> --no-show-images"
        assert doc =~ "advice, not a refusal"
        refute doc =~ "Install it only when the person says yes"
        assert_states(doc, "Install it only when the person says yes")
        # not a doc: the API's own error
        assert error =~ "a new card has no field called that one"
        assert body =~ "Run the install one-liner on its machine again" # not a doc
      end
    end
    """

    assert pinned_sentences(source) == []
  end

  test "a sentence in a regex is found: its \\s+ and escapes read as the text they match" do
    source = """
    defmodule X do
      test "x" do
        assert doc =~ ~r/apply only\\s+what they\\s*approve; never\\s+dismiss\\sone/
        assert doc =~ ~r/to apply \\(or undo\\)\\. An agent \\(or runner\\) can't/
        assert String.match?(doc, ~r/install it only when the person says yes/i)
        assert Regex.match?(~r/install it only when the person says yes/, doc)
        assert doc =~ ~r/^## Tidying up$/m
        assert doc =~ ~r/`garden` and\\s+`garden_decide` \\(tidy-up suggestions\\)/
        assert doc =~ ~r/install it \#{at} the person says yes, never before/
      end
    end
    """

    assert pinned_sentences(source) == [3, 4, 5, 6]
  end

  test "a sentence matched through a for's variable is found, on its own line" do
    source = """
    defmodule X do
      @claims [
        {"docs/agents.md", "goes back to a person: stop before building"},
        {"cli/help.txt", "[--digest-at HH:MM]"}
      ]

      test "x" do
        for {path, words} <- [
              {"README.md", "**Every card says where it came from.**"},
              {"cli/help.txt", "--origin sweep|findings"},
              {"docs/manual.md", ~r/a card that grows goes\\s+back to a person/}
            ] do
          assert read(path) =~ words, "\#{path} doesn't say it"
        end

        for {path, words} <- @claims, do: assert(String.contains?(read(path), words))
      end
    end
    """

    assert pinned_sentences(source) == [3, 9, 11]
  end

  test "a for's list is left alone when nothing matches a doc against its variable" do
    source = """
    defmodule X do
      @titles ["Every card says where it came from"]

      test "x" do
        for title <- ["A Housekeeping card that grows goes back"] do
          card = card_fixture(title: title)
          assert card.title == title
          refute doc =~ title
          assert doc =~ other
        end

        for title <- @titles, do: assert_states(doc, title)
        for title <- @missing, do: assert(doc =~ title)
        # not a doc: the API's own errors
        for error <- ["a new card has no field called that one"], do: assert(body =~ error)
      end
    end
    """

    assert pinned_sentences(source) == []
  end

  test "six plain words make a sentence, five don't; a ~s sigil is read like a string" do
    source = """
    defmodule X do
      test "x" do
        assert doc =~ "install it when the person agrees"
        assert doc =~ "install when the person agrees"
        assert doc =~ ~s{say "yes" only when the person agrees}
        assert doc =~ ~S{say "yes" only when the person agrees}
        assert doc =~ ~s{say \#{word} only when the person agrees to it}
      end
    end
    """

    assert pinned_sentences(source) == [3, 5, 6]
  end
end
