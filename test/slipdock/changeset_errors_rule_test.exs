defmodule Slipdock.ChangesetErrorsRuleTest do
  @moduledoc """
  One way to turn a changeset's errors into words (#3164):
  `Slipdock.ChangesetErrors`. Copies written by hand drifted, and nine of
  them printed a literal `%{count}` to people (#2873, #3052, #3124, #3140).

  This reads every module under `lib/` and `test/support/` and fails on a
  line that formats a changeset's errors by hand:

    * `traverse_errors(` anywhere but the helper itself;
    * a function over an errors list that takes each error's message and
      drops its opts (`fn {field, {msg, _}} -> …`), so a placeholder stays;
    * a message pulled out of an error with its opts dropped
      (`{msg, _} = …`, `{message, _opts} -> …`);
    * `inspect(changeset.errors)`, which shows a person Elixir terms;
    * a placeholder filled by hand (a `%{(\\w+)}` regex).

  Use `ChangesetErrors.message/2` (or `lines/2`) for a sentence,
  `by_field/1` for a map by field, and `text/1` for one error.
  """
  use ExUnit.Case, async: true

  @helper "lib/slipdock/changeset_errors.ex"

  # What a hand-rolled copy calls an error's message.
  @msg "(?:msg|message|text|m|error_message|reason)"

  @patterns [
    {~r/traverse_errors\(/, "traverse_errors outside the helper"},
    {~r/\{\s*\w+\s*,\s*\{\s*#{@msg}\s*,\s*_\w*\s*\}\s*\}/,
     "an error's message taken with its opts dropped"},
    {~r/\{\s*#{@msg}\s*,\s*_\w*\s*\}\s*(?:=[^=>]|->)/,
     "an error's message taken with its opts dropped"},
    {~r/inspect\(\s*[\w.]+\.errors\s*\)/, "inspect of a changeset's errors"},
    {~r/%\{\(/, "a placeholder filled by hand"}
  ]

  defp sources do
    Path.wildcard("lib/**/*.{ex,exs}") ++ Path.wildcard("test/support/**/*.{ex,exs}")
  end

  @doc false
  # `{line number, line, why}` for each line of `source` that formats
  # errors by hand; comments are skipped.
  def hand_rolled(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> line |> String.trim_leading() |> String.starts_with?("#") end)
    |> Enum.flat_map(fn {line, n} -> hit(line, n) end)
  end

  defp hit(line, n) do
    case Enum.find(@patterns, fn {re, _} -> line =~ re end) do
      {_, why} -> [{n, line, why}]
      nil -> []
    end
  end

  test "no module formats changeset errors except through Slipdock.ChangesetErrors" do
    hits =
      for path <- sources(),
          path != @helper,
          {n, line, why} <- hand_rolled(File.read!(path)),
          do: "#{path}:#{n}: #{why}: #{String.trim(line)}"

    assert hits == [],
           "Turn changeset errors into words with Slipdock.ChangesetErrors " <>
             "(message/2, lines/2, by_field/1 or text/1), never by hand (#3164):\n" <>
             Enum.join(hits, "\n")
  end

  test "the helper is the one place that calls traverse_errors" do
    assert File.read!(@helper) =~ "traverse_errors("
  end

  describe "the scan" do
    test "catches each hand-rolled spelling" do
      for line <- [
            ~s/|> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)/,
            ~s/Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->/,
            ~s/|> traverse_errors(fn {msg, opts} ->/,
            ~s/Enum.map_join(cs.errors, "; ", fn {field, {msg, _}} -> "\#{field} \#{msg}" end)/,
            ~s/|> Enum.map(fn {field, {m, _}} -> "\#{field} \#{m}" end)/,
            ~s/{field, {message, _}} = hd(changeset.errors)/,
            ~s/{msg, _} = Keyword.fetch!(cs.errors, :name)/,
            ~s/      {message, _opts} -> message/,
            ~s/"Couldn't: " <> inspect(changeset.errors)/,
            ~s/"\#{inspect(cs.errors)}"/,
            ~S|Regex.replace(~r/%{(\w+)}/, message, fn _, key ->|
          ] do
        assert [_] = hand_rolled(line), "missed: #{line}"
      end
    end

    test "passes the helper's calls, comments and other tuples" do
      for line <- [
            ~s/{:error, ChangesetErrors.message(changeset, separator: ": ")}/,
            ~s/def errors(cs), do: Slipdock.ChangesetErrors.by_field(cs)/,
            ~s/error -> "View name \#{error_text(error)}."/,
            ~s/  # never traverse_errors(fn {msg, _} -> msg end) by hand/,
            ~s/{:ok, _} -> :ok/,
            ~s/{key, _} = pair/,
            ~s/for {id, {board, _opts}} <- boards,/,
            ~s/{_, {value, _}} ->/,
            ~s/if msg == {msg, _} do/,
            ~s/changeset.errors |> Enum.reject(&match?({:signup_mode, _}, &1))/
          ] do
        assert hand_rolled(line) == [], "flagged: #{line}"
      end
    end
  end
end
