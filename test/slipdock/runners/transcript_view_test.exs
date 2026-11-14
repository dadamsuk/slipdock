defmodule Slipdock.Runners.TranscriptViewTest do
  # A job's live log read as lines (#1871): one per message, tool call or
  # result, with its time; each keeps the whole of what it shortens.
  use ExUnit.Case, async: true

  alias Slipdock.Runners.TranscriptView, as: View

  defp jl(maps), do: Enum.map_join(maps, "", &(Jason.encode!(&1) <> "\n"))

  test "messages, tool calls and results, in order, numbered by line" do
    text =
      jl([
        %{
          type: "user",
          timestamp: "2026-11-06T12:13:05.123Z",
          message: %{content: "Work on card #4"}
        },
        %{
          type: "assistant",
          timestamp: "2026-11-06T12:13:07Z",
          message: %{
            content: [
              %{type: "thinking", thinking: "hmm"},
              %{type: "text", text: "Reading   the\ncard."},
              %{type: "tool_use", name: "Read", input: %{file_path: "lib/a.ex", limit: 5}}
            ]
          }
        },
        %{
          type: "user",
          timestamp: "2026-11-06T12:13:08Z",
          message: %{
            content: [
              %{type: "tool_result", content: [%{type: "text", text: "one\n\ntwo\nthree"}]}
            ]
          }
        },
        %{
          type: "user",
          message: %{content: [%{type: "tool_result", is_error: true, content: "boom"}]}
        }
      ])

    assert [prompt, message, tool, result, error] = View.entries(text, 10)

    assert %{id: "10-0", line: 10, kind: :prompt, text: "Work on card #4", detail: nil} =
             prompt

    assert prompt.at == ~U[2026-11-06 12:13:05.123Z]
    # Whitespace folds to one line; the whole text stays as the detail.
    assert %{id: "11-0", kind: :message, text: "Reading the card."} = message
    assert message.detail == "Reading   the\ncard."
    assert %{id: "11-1", line: 11, kind: :tool, text: "Read: lib/a.ex"} = tool
    assert Jason.decode!(tool.detail) == %{"file_path" => "lib/a.ex", "limit" => 5}
    assert %{kind: :result, text: "one  (+2 lines)", detail: "one\n\ntwo\nthree"} = result
    assert %{kind: :error, text: "boom", detail: nil, at: nil} = error
  end

  test "a long line is cut to one screen line; the detail has it all" do
    long = String.duplicate("word ", 100)

    [e] =
      View.entries(jl([%{type: "assistant", message: %{content: [%{type: "text", text: long}]}}]))

    assert String.length(e.text) == 160
    assert String.ends_with?(e.text, "…")
    assert e.detail == long
  end

  test "a tool call reads as its command, else its file, else its input" do
    calls = [
      %{name: "Bash", input: %{command: "mix test", description: "Run"}},
      %{name: "Grep", input: %{pattern: "def x"}},
      %{name: "TodoWrite", input: %{todos: [1]}},
      %{name: "Noop", input: %{}}
    ]

    text =
      jl([
        %{
          type: "assistant",
          message: %{content: Enum.map(calls, &Map.put(&1, :type, "tool_use"))}
        }
      ])

    assert [bash, grep, todo, noop] = View.entries(text)
    assert bash.text == "Bash: mix test"
    assert grep.text == "Grep: def x"
    assert todo.text == ~s(TodoWrite: {"todos":[1]})
    assert noop.text == "Noop: {}"
    assert noop.detail == nil
  end

  test "the server's notes read as notes" do
    text =
      jl([
        %{type: "slipdock_cut", bytes: 40_000, limit: 32_768},
        %{type: "slipdock_capped", limit: 8_000_000},
        %{type: "slipdock_run", attempt: 2, runner: "spare"}
      ])

    assert [cut, capped, run] = View.entries(text)
    assert %{kind: :note, text: "a new run started (try 2, on spare)" <> _} = run
    assert %{kind: :note, text: "a line of 40000 bytes was left out (over 32768)"} = cut
    assert capped.text =~ "reached its limit (8000000 bytes)"
  end

  test "lines that are neither, broken lines and meta prompts are left out" do
    text =
      jl([
        %{type: "user", isMeta: true, message: %{content: "<system-reminder>"}},
        %{type: "user", message: %{content: ""}},
        %{type: "assistant", message: %{content: [%{type: "text", text: "  "}]}},
        %{type: "file-history-snapshot"},
        %{type: "system", content: "hook ran"}
      ]) <> "not json\n[1,2]\n"

    assert View.entries(text) == []
    assert View.entries("") == []
  end

  test "format writes the time, the kind's mark and the text" do
    [p, m, t, r, e, n] =
      for kind <- ~w(prompt message tool result error note)a,
          do: %{at: ~U[2026-11-06 12:13:07.5Z], kind: kind, text: "x"}

    assert View.format(p) == "12:13:07  ▸ x"
    assert View.format(m) == "12:13:07  💬 x"
    assert View.format(t) == "12:13:07  ▶ x"
    assert View.format(r) == "12:13:07     ↳ x"
    assert View.format(e) == "12:13:07     ✗ x"
    assert View.format(%{n | at: nil}) == "          … x"
  end
end
