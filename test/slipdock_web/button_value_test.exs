defmodule SlipdockWeb.ButtonValueTest do
  @moduledoc """
  A button's `value` matches its `phx-value-value` (#2092, from findings
  #342 and #553).

  A browser sends a clicked button's own `value` attribute as `value`, and
  that overrides `phx-value-value`. So a button with `phx-value-value` and
  no `value=` sends an empty value, and LiveViewTest, which reads the
  `phx-value-*` attributes alone, never shows it. The toolbar's date and
  sort buttons (`SwimlaneComponents`) keep the two in step by hand; this
  holds every `<button>` (and `<.button>`, which passes its attributes on
  to one) under `lib/slipdock_web` to that, naming the file and line.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp sources do
    @root
    |> Path.join("lib/slipdock_web/**/*.{ex,heex}")
    |> Path.wildcard()
    |> Enum.map(&{Path.relative_to(&1, @root), File.read!(&1)})
  end

  @doc false
  # The buttons in a source that set `phx-value-value` without a `value=`
  # holding the same expression, each as {line, why}. The line is the
  # `phx-value-value` attribute's.
  def mismatches(src) do
    for {offset, attrs} <- buttons(src),
        {"phx-value-value", wanted, at} <- attrs,
        why = mismatch(wanted, attrs),
        why != nil do
      {line_of(src, offset + at), why}
    end
  end

  defp mismatch(wanted, attrs) do
    case for({"value", v, _} <- attrs, do: v) do
      [] -> "no value= (want value=#{wanted})"
      [^wanted] -> nil
      [other | _] -> "value=#{other} differs from phx-value-value=#{wanted}"
    end
  end

  defp line_of(src, offset),
    do: src |> binary_part(0, offset) |> String.split("\n") |> length()

  @doc false
  # Every `<button` or `<.button` opening tag in a source, as
  # {offset, [{name, value, offset_in_tag}]}. A value is its source text
  # with whitespace collapsed (`"x"`, `{@x}`); a bare `{@rest}` is skipped.
  def buttons(src) do
    for [{start, len}] <- Regex.scan(~r/<\.?button(?=[\s>\/])/, src, return: :index) do
      tag_start = start + len
      rest = binary_part(src, tag_start, byte_size(src) - tag_start)
      {start, attrs(rest, len, [])}
    end
  end

  defp attrs(<<c, rest::binary>>, at, acc) when c in ~c[ \t\r\n],
    do: attrs(rest, at + 1, acc)

  defp attrs(<<c, _::binary>>, _at, acc) when c in ~c[>/], do: Enum.reverse(acc)
  defp attrs(<<>>, _at, acc), do: Enum.reverse(acc)

  defp attrs(<<"{", _::binary>> = src, at, acc) do
    {expr, rest} = take_expr(src)
    attrs(rest, at + byte_size(expr), acc)
  end

  defp attrs(src, at, acc) do
    case Regex.run(~r/^[^\s=>\/{]+/, src) do
      [name] -> attr(src, name, at, acc)
      nil -> attrs(binary_part(src, 1, byte_size(src) - 1), at + 1, acc)
    end
  end

  defp attr(src, name, at, acc) do
    after_name = binary_part(src, byte_size(name), byte_size(src) - byte_size(name))

    case after_name do
      <<"=", rest::binary>> ->
        {value, rest} = take_value(rest)
        used = byte_size(name) + 1 + byte_size(value)
        attrs(rest, at + used, [{name, normalise(value), at} | acc])

      _ ->
        attrs(after_name, at + byte_size(name), [{name, true, at} | acc])
    end
  end

  defp normalise(value), do: value |> String.split() |> Enum.join(" ")

  defp take_value(<<q, _::binary>> = src) when q in ~c['"] do
    [quoted] = Regex.run(~r/^#{<<q>>}[^#{<<q>>}]*#{<<q>>}/, src)
    {quoted, binary_part(src, byte_size(quoted), byte_size(src) - byte_size(quoted))}
  end

  defp take_value(<<"{", _::binary>> = src), do: take_expr(src)

  defp take_value(src) do
    [bare] = Regex.run(~r/^[^\s>]*/, src)
    {bare, binary_part(src, byte_size(bare), byte_size(src) - byte_size(bare))}
  end

  # A `{…}` expression, braces balanced and strings skipped, so neither a
  # `}` nor a `>` inside one ends it.
  defp take_expr(src), do: split_at(src, expr_end(src, 0, 0))

  # The byte count up to and including the `}` that closes the expression.
  defp expr_end(src, i, _depth) when i >= byte_size(src), do: byte_size(src)

  defp expr_end(src, i, depth) do
    case :binary.at(src, i) do
      q when q in ~c['"] -> expr_end(src, string_end(src, i + 1, q), depth)
      ?{ -> expr_end(src, i + 1, depth + 1)
      ?} when depth == 1 -> i + 1
      ?} -> expr_end(src, i + 1, depth - 1)
      _ -> expr_end(src, i + 1, depth)
    end
  end

  # The index just past the quote that closes a string, escapes skipped.
  defp string_end(src, i, _q) when i >= byte_size(src), do: i

  defp string_end(src, i, q) do
    case :binary.at(src, i) do
      ?\\ -> string_end(src, i + 2, q)
      ^q -> i + 1
      _ -> string_end(src, i + 1, q)
    end
  end

  defp split_at(src, n), do: {binary_part(src, 0, n), binary_part(src, n, byte_size(src) - n)}

  describe "the scanner" do
    test "passes a button whose value= holds the same expression" do
      src = """
      <button
        type="button"
        phx-click="swim_set"
        phx-value-key="dir"
        phx-value-value={if @config.dir == "asc", do: "desc", else: "asc"}
        value={if @config.dir == "asc", do: "desc", else: "asc"}
      >
      """

      assert mismatches(src) == []
    end

    test "fails a button with phx-value-value and no value=, at the attribute's line" do
      src = """
      <p>before</p>
      <button
        type="button"
        phx-click="swim_set"
        phx-value-value={@nav.prev}
        title="Earlier"
      >
        <.icon name="hero-chevron-left" />
      </button>
      """

      assert [{5, why}] = mismatches(src)
      assert why =~ "no value="
      assert why =~ "{@nav.prev}"
    end

    test "fails a value= that holds a different expression" do
      src = ~s(<button phx-value-value={@nav.next} value={@nav.prev}>Later</button>)
      assert [{1, why}] = mismatches(src)
      assert why =~ "differs"
    end

    test "compares expressions with whitespace collapsed, and literal strings" do
      assert mismatches(~s(<button phx-value-value="" value="">Today</button>)) == []
      assert [_] = mismatches(~s(<button phx-value-value="" value="x">Today</button>))

      src = "<button phx-value-value={if @a,\n do: 1, else: 2} value={if @a, do: 1, else: 2}>"
      assert mismatches(src) == []
    end

    test "holds <.button> too, and leaves other tags and other phx-value-* alone" do
      assert [{1, _}] = mismatches(~s(<.button phx-value-value={@x}>Go</.button>))
      assert mismatches(~s(<a phx-value-value={@x}>Go</a>)) == []
      assert mismatches(~s(<div phx-value-value={@x}></div>)) == []
      assert mismatches(~s(<button phx-value-key="date" phx-click="x">)) == []
      assert mismatches(~s(<.button_group phx-value-value={@x}>)) == []
    end

    test "is not fooled by a > or } inside an expression, or a bare {@rest}" do
      src = ~s(<button {@rest} disabled phx-value-value={if @n > 0, do: "}", else: "a"}>)
      assert [{1, why}] = mismatches(src)
      assert why =~ ~s(else: "a"})

      src = ~s(<button title={"a > b"} value={@v} phx-value-value={@v}>)
      assert mismatches(src) == []
    end

    test "counts lines from the start of the source, across several buttons" do
      src = """
      <button phx-value-value={@a} value={@a}>A</button>
      <button
        phx-value-value={@b}>B</button>
      <button phx-value-value={@c}>C</button>
      """

      assert Enum.map(mismatches(src), &elem(&1, 0)) == [3, 4]
    end
  end

  describe "the templates" do
    test "the toolbar's date and sort buttons are found, so the check has something to hold" do
      src = File.read!(Path.join(@root, "lib/slipdock_web/components/swimlane_components.ex"))

      held =
        for {_, attrs} <- buttons(src), {"phx-value-value", _, _} <- attrs, do: :ok

      assert length(held) >= 4
    end

    test "every button with phx-value-value sets value= to the same expression" do
      found =
        for {path, src} <- sources(),
            {line, why} <- mismatches(src),
            do: "#{path}:#{line}: #{why}"

      assert found == [],
             "a browser sends a button's own value as `value`, over phx-value-value; " <>
               "give each the same value=:\n" <> Enum.join(found, "\n")
    end
  end
end
