defmodule Slipdock.Meetings.Schema do
  @moduledoc """
  The findings format: what a reading of a meeting produces, and what an
  agent may send with a capture (`slipdock capture new --findings f.json`).
  Published as JSON Schema at `GET /api/meetings/findings-schema`.

  `validate/1` checks a document in code — every finding, every field — and
  says what is wrong in words a model (or a person) can act on. It is the
  gate between what a model wrote and what anybody sees; anything it lets
  through is still checked against the transcript word for word afterwards
  (see `Slipdock.Meetings.Verify`).
  """

  @kinds ~w(decision action card_change open_question idea)
  # What a model's reading is asked for: the things that go on the board.
  # Ideas and open questions are the summary's and topics' to tell; an
  # agent may still send them.
  @read_kinds ~w(decision action card_change)
  @change_fields ~w(due_date start_date assignee list title priority completed description)

  def kinds, do: @kinds
  def read_kinds, do: @read_kinds
  def change_fields, do: @change_fields

  @doc "The JSON Schema, as a map."
  def json_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://slipdock.us/schemas/meeting-findings.json",
      "title" => "Meeting findings",
      "description" =>
        "What a meeting produced, each finding tied to the exact words it came from. " <>
          "Quotes are checked against the transcript character for character; a finding " <>
          "whose quote is not there is dropped.",
      "type" => "object",
      "required" => ["findings"],
      "properties" => %{
        "summary" => %{
          "type" => "string",
          "description" => "What the meeting was for and what came of it, in a few sentences."
        },
        "topics" => %{
          "type" => "array",
          "description" =>
            "The main subjects discussed, each with what was said and where it landed. " <>
              "Opinions, background and ideas belong here rather than in findings.",
          "items" => %{
            "type" => "object",
            "required" => ["title", "summary"],
            "properties" => %{
              "title" => %{"type" => "string", "maxLength" => 120},
              "summary" => %{"type" => "string"}
            }
          }
        },
        "findings" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["kind", "title", "evidence"],
            "properties" => %{
              "kind" => %{"enum" => @kinds},
              "title" => %{
                "type" => "string",
                "maxLength" => 200,
                "description" => "What it is, in a short line: the card title or the decision."
              },
              "body" => %{
                "type" => "string",
                "description" => "More detail, if the meeting gave any."
              },
              "evidence" => %{
                "type" => "array",
                "minItems" => 1,
                "items" => %{
                  "type" => "object",
                  "required" => ["line", "quote"],
                  "properties" => %{
                    "line" => %{
                      "type" => "string",
                      "pattern" => "^L[0-9]+$",
                      "description" => "The transcript line id, e.g. L12."
                    },
                    "quote" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Words copied exactly from that line."
                    }
                  }
                }
              },
              "owner" => %{
                "type" => "string",
                "description" => "Who an action was given to, as the meeting named them."
              },
              "due" => %{
                "type" => "string",
                "description" =>
                  "A deadline as said, rewritten as one of: today, tomorrow, mon…sun, " <>
                    "next mon…next sun, next week, next month, eow, eom, in 3 days, in 2 weeks, " <>
                    "1 oct, 2026-10-01."
              },
              "card" => %{
                "type" => "string",
                "description" => "The existing card or page it is about: #412, PL-14 or W-31."
              },
              "change" => %{
                "type" => "object",
                "required" => ["field", "to"],
                "properties" => %{
                  "field" => %{"enum" => @change_fields},
                  "to" => %{"type" => ["string", "boolean"]}
                }
              },
              "comment" => %{
                "type" => "string",
                "description" => "What to say on the card it is about."
              },
              "topic" => %{
                "type" => "string",
                "description" => "For a decision: the subject it belongs under, e.g. Pricing."
              },
              "decided_by" => %{"type" => "string"},
              "supersedes" => %{
                "type" => "string",
                "description" => "For a decision: the earlier decision it replaces, in its words."
              },
              "confirmed" => %{
                "type" => "boolean",
                "description" => "Whether somebody else in the meeting agreed to it out loud."
              }
            }
          }
        }
      }
    }
  end

  @doc """
  Checks a findings document. `{:ok, findings}` (the list, each finding a map
  with string keys and nothing unknown kept), or `{:error, [problem]}` naming
  each problem with the finding it is in.
  """
  def validate(doc) do
    case partition(doc) do
      {:ok, kept, []} -> {:ok, kept}
      {:ok, _kept, problems} -> {:error, problems}
      error -> error
    end
  end

  @doc """
  Like `validate/1`, but keeps what fits: `{:ok, kept, problems}`, the
  findings that passed and one problem per finding that didn't. A document
  that isn't a findings list at all is still `{:error, [problem]}`.
  """
  def partition(%{"findings" => findings}) when is_list(findings) do
    {kept, problems} =
      findings
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {finding, n}, {kept, problems} ->
        case validate_finding(finding) do
          {:ok, f} -> {[f | kept], problems}
          {:error, why} -> {kept, ["finding #{n}: #{why}" | problems]}
        end
      end)

    {:ok, Enum.reverse(kept), Enum.reverse(problems)}
  end

  def partition(%{}), do: {:error, ["the answer has no \"findings\" list"]}
  def partition(_), do: {:error, ["the answer is not a JSON object"]}

  @max_topics 12

  @doc """
  The summary and topics of a findings document, as
  `%{"summary" => text | nil, "topics" => [%{"title", "summary"}]}`. Lenient:
  they are notes for a person to read, so a malformed one is left out rather
  than failing the reading — a topic needs a title, takes `summary` (or
  `body`, `text`) for its words, and at most #{@max_topics} are kept.
  """
  def notes(%{} = doc) do
    %{
      "summary" => text(doc["summary"]) && String.trim(doc["summary"]),
      "topics" =>
        case doc["topics"] do
          list when is_list(list) -> list |> Enum.flat_map(&topic/1) |> Enum.take(@max_topics)
          _ -> []
        end
    }
  end

  def notes(_doc), do: %{"summary" => nil, "topics" => []}

  defp topic(%{} = t) do
    title = text(t["title"]) || text(t["name"]) || text(t["topic"])
    words = text(t["summary"]) || text(t["body"]) || text(t["text"])

    if title,
      do: [
        %{"title" => shorten(String.trim(title), 120), "summary" => words && String.trim(words)}
      ],
      else: []
  end

  defp topic(title) when is_binary(title) do
    case text(title) do
      nil -> []
      t -> [%{"title" => shorten(String.trim(t), 120), "summary" => nil}]
    end
  end

  defp topic(_), do: []

  @title_aliases ~w(text decision action question summary name)

  @doc """
  Mends the slips a model makes most often before a model's answer is
  checked: a finding with no `title` takes it from the field the model put
  it in instead (`text`, `decision`, `question`…), or from the first
  sentence of its `body`; a title over 200 characters is cut at a word.
  Never invents anything: a finding with no words to take a title from
  stays without one, and fails the check. Not used on an agent's findings,
  which are sent back to the agent to put right.
  """
  def mend(%{"findings" => findings} = doc) when is_list(findings),
    do: %{doc | "findings" => Enum.map(findings, &mend_finding/1)}

  def mend(doc), do: doc

  defp mend_finding(%{} = f) do
    title =
      if is_binary(f["title"]) and String.trim(f["title"]) != "" do
        f["title"]
      else
        Enum.find_value(@title_aliases, &text(f[&1])) || first_sentence(f["body"])
      end

    case title do
      nil -> f
      title -> Map.put(f, "title", shorten(String.trim(title)))
    end
  end

  defp mend_finding(f), do: f

  defp text(v) when is_binary(v), do: if(String.trim(v) != "", do: v)
  defp text(_), do: nil

  defp first_sentence(body) when is_binary(body) do
    case body |> String.trim() |> String.split(~r/(?<=[.!?])\s|\n/, parts: 2) do
      [""] -> nil
      [first | _] -> first
    end
  end

  defp first_sentence(_), do: nil

  defp shorten(title, max \\ 200) do
    if String.length(title) <= max do
      title
    else
      cut = String.slice(title, 0, max - 1)
      String.replace(cut, ~r/\s+\S*$/, "") <> "…"
    end
  end

  @fields ~w(kind title body evidence owner due card change comment topic decided_by supersedes confirmed)

  defp validate_finding(%{} = f) do
    cond do
      f["kind"] not in @kinds ->
        {:error, "kind must be one of #{Enum.join(@kinds, ", ")}"}

      not (is_binary(f["title"]) and String.trim(f["title"]) != "") ->
        {:error, "title is required"}

      String.length(f["title"]) > 200 ->
        {:error, "title is longer than 200 characters"}

      not (is_list(f["evidence"]) and f["evidence"] != []) ->
        {:error, "evidence must list at least one {line, quote}"}

      not Enum.all?(f["evidence"], &evidence?/1) ->
        {:error, "each evidence item needs a line like \"L12\" and a non-empty quote"}

      not optional_strings?(f) ->
        {:error, "owner, due, card, comment, topic, decided_by, supersedes and body must be text"}

      f["change"] != nil and not change?(f["change"]) ->
        {:error,
         "change must be {field, to} with field one of #{Enum.join(@change_fields, ", ")}"}

      f["confirmed"] not in [nil, true, false] ->
        {:error, "confirmed must be true or false"}

      true ->
        {:ok, f |> Map.take(@fields) |> Map.update!("title", &String.trim/1)}
    end
  end

  defp validate_finding(_), do: {:error, "is not an object"}

  defp evidence?(%{"line" => line, "quote" => quote}) when is_binary(line) and is_binary(quote),
    do: Regex.match?(~r/^L\d+$/, line) and quote != ""

  defp evidence?(_), do: false

  defp optional_strings?(f) do
    ~w(owner due card comment topic decided_by supersedes body)
    |> Enum.all?(&(f[&1] == nil or is_binary(f[&1])))
  end

  defp change?(%{"field" => field, "to" => to}) when field in @change_fields,
    do: is_binary(to) or is_boolean(to)

  defp change?(_), do: false
end
