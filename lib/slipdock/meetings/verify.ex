defmodule Slipdock.Meetings.Verify do
  @moduledoc """
  Checking what the readings found (pipeline step 7), in code rather than by
  asking a model, and turning it into what a person reviews: findings, each
  with its evidence, signals, links and proposed effect, and the questions
  that have to be settled first.

  ## Word for word (G2)

  Every quote is looked for in the transcript. The comparison forgives what
  a copy can change without changing a word — letter case, curly versus
  straight quote marks, dashes, an ellipsis written as three dots, runs of
  spaces — and nothing else. The line the reading named is tried first, then
  every other line (a reading that numbered a line wrongly still quoted it
  right). A finding with a quote that is in no line is **dropped**: kept,
  with the reason, so the review can show what was thrown away and why, and
  the drop is written on the capture's record.

  ## Two readings, one list

  The readings are merged: the same kind of finding drawing on the same
  lines, or with the same title, is one finding. It is marked as found by
  both readings or by only one (or sent by an agent). Where both found it but
  disagree — a different owner, date or change, a different number in the
  title (15% against 50%) — the person is asked which (`which_reading`).

  ## Links (G5, G7, G12)

  A finding about an existing card or page is linked to it only when it
  exists, the capture's owner can open it, and it was among what the context
  step read; its version is kept for the stale check at commit. The link's
  strength is a signal: *linked by id*, *by name*, *by similarity only*. A
  new action that looks like an existing card it is not explicitly about
  asks *existing card or new*.

  ## Questions (G3)

  Besides those: an owner nobody here is called asks *who is meant*, with
  the nearest members; a line whose speaker is unsure asks *who said it*,
  but only when a finding depends on who said it. Every question can be
  answered "not decided" or "nobody yet".

  An open question the wiki already answers is left out by default, with
  the answer linked.

  ## No numbers

  Signals are labels (`signal_label/1`), never a percentage or a score.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Repo
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Column}
  alias Slipdock.Meetings
  alias Slipdock.Meetings.{Capture, Evidence, Finding, Question, Utterance, Version}

  @labels %{
    "quoted" => "quoted word for word",
    "confirmed" => "confirmed in the meeting",
    "both_readings" => "both readings agree",
    "one_reading" => "only one reading found it",
    "readings_differ" => "the readings differ",
    "from_agent" => "sent by an agent",
    "added_by_person" => "added by a person",
    "audio_clear" => "audio clear",
    "audio_unclear" => "audio unclear",
    "relistened" => "re-listened",
    "linked_by_id" => "linked by id",
    "linked_by_name" => "linked by name",
    "linked_by_similarity" => "linked by similarity only",
    "owner_known" => "owner named",
    "owner_unknown" => "name not recognised",
    "answered_in_wiki" => "the wiki already answers it",
    "voice_unsure" => "speaker unsure"
  }

  @doc "How a signal reads to a person. Never a number."
  def signal_label(key), do: Map.get(@labels, key, String.replace(key, "_", " "))

  @doc "Every signal there is, as `{key, label}`."
  def signals, do: @labels

  @doc """
  Verifies a capture's readings: replaces its findings and questions (except
  what a person added) with the verified ones. Returns
  `{:ok, %{kept: n, dropped: n, questions: n}}`.
  """
  def verify(%Capture{} = capture) do
    capture = Repo.preload(capture, [:board], force: true)

    lines =
      Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))

    readings = capture.readings || %{}
    context = capture.context || %{}
    members = people(capture)
    candidates = context["candidates"] || []
    second? = readings["2"] != nil

    tagged =
      tag(readings["1"], 1) ++ tag(readings["2"], 2) ++ tag(readings["agent"], 0)

    {checked, dropped} =
      tagged
      |> Enum.map(&check_quotes(&1, lines))
      |> Enum.split_with(&(&1.status == "kept"))

    merged = merge(checked)

    findings =
      merged
      |> Enum.map(&signals_and_links(&1, second?, candidates, members, capture, lines))
      |> Enum.with_index()

    Repo.transaction(fn ->
      Repo.delete_all(from(q in Question, where: q.capture_id == ^capture.id))

      Repo.delete_all(
        from(f in Finding, where: f.capture_id == ^capture.id and f.origin != "person")
      )

      question_count =
        findings
        |> Enum.map(fn {f, i} -> insert_finding(capture, f, i, lines) end)
        |> Enum.sum()

      Enum.each(Enum.with_index(dropped, length(findings)), fn {f, i} ->
        insert_finding(capture, f, i, lines)
      end)

      for f <- dropped do
        Meetings.record(capture, "dropped", "Dropped “#{f.raw["title"]}”: #{f.reason}.",
          data: %{"reading" => f.reading}
        )
      end

      Meetings.record(
        capture,
        "found",
        "Found #{length(findings)} #{plural(length(findings), "thing", "things")}" <>
          if(dropped == [],
            do: ".",
            else: "; dropped #{length(dropped)} whose words are not in the transcript."
          )
      )

      %{kept: length(findings), dropped: length(dropped), questions: question_count}
    end)
  end

  defp plural(1, one, _), do: one
  defp plural(_, _, many), do: many

  defp tag(nil, _), do: []
  defp tag(findings, n), do: Enum.map(findings, &%{raw: &1, reading: n})

  ## Quotes -------------------------------------------------------------------

  @doc """
  Where `quote` is in `text`, forgiving case, quote marks, dashes, ellipses
  and spacing: `{start, end}` in `text`'s characters, or nil.
  """
  def locate(quote, text) do
    {needle, _} = normalise(quote)
    {haystack, index} = normalise(text)
    needle = String.trim(needle)

    if needle == "" do
      nil
    else
      case :binary.match(haystack, needle) do
        {byte_start, len} ->
          from = char_at(haystack, byte_start, index)
          to = char_at(haystack, byte_start + len - 1, index) + 1
          {from, to}

        :nomatch ->
          nil
      end
    end
  end

  # Each normalised character remembers which character of the original it
  # came from, so a match found in the forgiving text points back into the
  # words as written.
  defp normalise(text) do
    {chars, index, _} =
      text
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce({[], [], false}, fn {g, i}, {chars, index, space?} ->
        case fold(g) do
          " " when space? ->
            {chars, index, true}

          " " ->
            {[" " | chars], [i | index], true}

          folded ->
            out = String.graphemes(folded)
            {Enum.reverse(out) ++ chars, List.duplicate(i, length(out)) ++ index, false}
        end
      end)

    {chars |> Enum.reverse() |> Enum.join(), index |> Enum.reverse() |> List.to_tuple()}
  end

  defp fold(g) when g in ["‘", "’", "‚", "‛", "′", "`", "´"], do: "'"
  defp fold(g) when g in ["“", "”", "„", "‟", "″", "«", "»"], do: "\""
  defp fold(g) when g in ["–", "—", "‒", "―", "−"], do: "-"
  defp fold("…"), do: "..."

  defp fold(g) do
    if String.trim(g) == "", do: " ", else: String.downcase(g)
  end

  # The original character a byte of the normalised text came from.
  defp char_at(haystack, byte, index) do
    chars = haystack |> binary_part(0, byte) |> String.length()
    elem(index, min(chars, tuple_size(index) - 1))
  end

  defp check_quotes(%{raw: raw} = f, lines) do
    by_id = Map.new(lines, &{&1.line_id, &1})

    located =
      Enum.map(raw["evidence"], fn %{"line" => line_id, "quote" => quote} ->
        named = by_id[line_id]

        case named && locate(quote, named.text) do
          {from, to} ->
            {:ok, %{line: named, from: from, to: to, quote: quote}}

          nil ->
            case Enum.find_value(lines, fn l -> (pos = locate(quote, l.text)) && {l, pos} end) do
              {line, {from, to}} -> {:ok, %{line: line, from: from, to: to, quote: quote}}
              nil -> {:missing, quote, line_id}
            end
        end
      end)

    case Enum.find(located, &match?({:missing, _, _}, &1)) do
      nil ->
        Map.merge(f, %{status: "kept", evidence: Enum.map(located, fn {:ok, e} -> e end)})

      {:missing, quote, line_id} ->
        Map.merge(f, %{
          status: "dropped",
          reason: "its quote is not in the transcript: “#{quote}” (#{line_id})",
          evidence: []
        })
    end
  end

  ## Merging the readings -----------------------------------------------------

  defp merge(findings) do
    Enum.reduce(findings, [], fn f, groups ->
      case Enum.find_index(groups, &same?(&1, f)) do
        nil -> groups ++ [[f]]
        i -> List.update_at(groups, i, &(&1 ++ [f]))
      end
    end)
    |> Enum.map(fn [first | _] = group ->
      %{
        first
        | evidence:
            group |> Enum.flat_map(& &1.evidence) |> Enum.uniq_by(&{&1.line.id, &1.from, &1.to})
      }
      |> Map.put(:group, group)
    end)
  end

  # The same finding: one kind, and either the same lines or the same title.
  defp same?([first | _] = group, f) do
    not Enum.any?(group, &(&1.reading == f.reading)) and first.raw["kind"] == f.raw["kind"] and
      (shared_lines?(first, f) or
         Slipdock.Meetings.Context.normalise(first.raw["title"]) ==
           Slipdock.Meetings.Context.normalise(f.raw["title"]))
  end

  defp shared_lines?(a, b) do
    a_lines = MapSet.new(a.evidence, & &1.line.id)
    Enum.any?(b.evidence, &MapSet.member?(a_lines, &1.line.id))
  end

  ## Signals, links, effects, questions ---------------------------------------

  defp signals_and_links(f, second?, candidates, members, capture, lines) do
    raw = f.raw
    readings = f.group |> Enum.map(& &1.reading) |> Enum.uniq() |> Enum.sort()

    agreement =
      cond do
        readings == [0] -> "from_agent"
        not second? -> nil
        Enum.count(readings, &(&1 in [1, 2])) == 2 -> "both_readings"
        true -> "one_reading"
      end

    differences = differences(f.group)
    link = link(raw, f.evidence, candidates)
    owner = owner(raw, members)
    unsure = Enum.any?(f.evidence, & &1.line.voice_unsure)
    answered = raw["kind"] == "open_question" && wiki_answer(f.evidence, candidates)

    signals =
      ["quoted"] ++
        List.wrap(agreement) ++
        if(differences != [], do: ["readings_differ"], else: []) ++
        if(raw["confirmed"], do: ["confirmed"], else: []) ++
        if(link, do: ["linked_by_#{link["strength"]}"], else: []) ++
        owner_signal(owner) ++
        if(unsure, do: ["voice_unsure"], else: []) ++
        if(answered, do: ["answered_in_wiki"], else: [])

    questions =
      which_reading(differences) ++
        who_is_meant(owner, members) ++
        existing_or_new(raw, link, f.evidence, candidates) ++
        who_said_it(raw, unsure, f.evidence, capture)

    effect = effect(raw, link, owner, capture)

    %{
      raw: raw,
      kind: effect_kind(raw, link),
      evidence: f.evidence,
      readings: readings,
      signals: Enum.uniq(signals),
      links: List.wrap(link),
      known: known(link, answered, raw, capture),
      effect: effect,
      included: raw["kind"] != "idea" and answered in [nil, false],
      questions: questions,
      origin: if(readings == [0], do: "agent", else: "reading"),
      lines: lines
    }
  end

  # A change to a card the meeting was explicitly about.
  defp effect_kind(%{"kind" => "action"}, %{"strength" => "id", "type" => "card"}),
    do: "card_change"

  defp effect_kind(%{"kind" => kind}, _), do: kind

  # Where the readings disagree, as `{what, [{reading, value}]}`.
  defp differences(group) do
    models = Enum.filter(group, &(&1.reading in [1, 2]))

    if length(models) < 2 do
      []
    else
      [
        {"owner", Enum.map(models, &{&1.reading, &1.raw["owner"]})},
        {"due", Enum.map(models, &{&1.reading, &1.raw["due_date"] || &1.raw["due"]})},
        {"change", Enum.map(models, &{&1.reading, &1.raw["change"] && &1.raw["change"]["to"]})},
        {"figure", Enum.map(models, &{&1.reading, figures(&1.raw["title"])})}
      ]
      |> Enum.filter(fn {_, values} ->
        distinct =
          values |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 in [nil, "", []])) |> Enum.uniq()

        length(distinct) > 1
      end)
      |> Enum.map(fn {what, values} -> {what, values, Enum.map(models, & &1.raw)} end)
    end
  end

  defp figures(nil), do: []
  defp figures(text), do: Regex.scan(~r/\d+(?:[.,]\d+)?%?/, text) |> List.flatten()

  defp which_reading([]), do: []

  defp which_reading(differences) do
    Enum.map(differences, fn {what, values, raws} ->
      options =
        values
        |> Enum.zip(raws)
        |> Enum.map(fn {{reading, value}, raw} ->
          shown =
            if is_list(value), do: Enum.join(value, ", "), else: to_string(value || "not said")

          %{
            "value" => "reading:#{reading}",
            "label" => shown,
            "effect" => "use the #{ordinal(reading)} reading: “#{raw["title"]}”",
            "finding" => raw
          }
        end)

      %{
        kind: "which_reading",
        prompt: "The two readings heard the #{what_word(what)} differently. Which is right?",
        options: options ++ [not_decided()],
        context: %{"field" => what}
      }
    end)
  end

  defp what_word("owner"), do: "owner"
  defp what_word("due"), do: "date"
  defp what_word("change"), do: "change"
  defp what_word("figure"), do: "figure"

  defp ordinal(1), do: "first"
  defp ordinal(2), do: "second"

  defp not_decided,
    do: %{"value" => "none", "label" => "Not decided", "effect" => "leave it unset"}

  ## Owners ----------------------------------------------------------------------

  # The people a name can mean: the board's members and the meeting's
  # attendees who are members.
  defp people(%Capture{} = capture) do
    board = Repo.get!(Board, capture.board_id)
    Slipdock.Wiki.Links.members(board)
  end

  defp owner(%{"owner" => name}, members) when is_binary(name) and name != "" do
    case Enum.filter(members, &named?(&1, name)) do
      [user] -> {:known, name, user}
      [_ | _] = several -> {:ambiguous, name, several}
      [] -> {:unknown, name}
    end
  end

  defp owner(_, _), do: nil

  defp owner_signal({:known, _, _}), do: ["owner_known"]
  defp owner_signal({_, _, _}), do: ["owner_unknown"]
  defp owner_signal({:unknown, _}), do: ["owner_unknown"]
  defp owner_signal(nil), do: []

  defp named?(%User{} = user, name) do
    name = Slipdock.Meetings.Context.normalise(name)
    full = Slipdock.Meetings.Context.normalise(user.name || "")
    handle = user.email |> String.split("@") |> hd() |> String.downcase()

    name != "" and
      (name == full or name == handle or (full != "" and hd(String.split(full)) == name))
  end

  defp who_is_meant(nil, _), do: []
  defp who_is_meant({:known, _, _}, _), do: []

  defp who_is_meant({:ambiguous, name, several}, _members),
    do: [who_question(name, several)]

  defp who_is_meant({:unknown, name}, members),
    do: [who_question(name, nearest(name, members))]

  defp who_question(name, users) do
    %{
      kind: "who_is_meant",
      prompt: "Who is “#{name}”? Nobody on this board is called that.",
      options:
        Enum.map(users, fn u ->
          %{
            "value" => "user:#{u.id}",
            "label" => u.name || u.email,
            "effect" => "assign it to #{u.name || u.email}"
          }
        end) ++ [%{"value" => "none", "label" => "Nobody yet", "effect" => "leave it unassigned"}],
      context: %{"name" => name}
    }
  end

  # The members whose names are closest to the one said, best first.
  defp nearest(name, members) do
    said = String.downcase(name)

    members
    |> Enum.map(fn u ->
      candidates = [u.name || "", u.email |> String.split("@") |> hd()]

      score =
        candidates |> Enum.map(&String.jaro_distance(String.downcase(&1), said)) |> Enum.max()

      {u, score}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  ## Links -----------------------------------------------------------------------

  # The existing thing a finding is about: what its "card" names, if the
  # context step found it; else a candidate drawn from the same lines.
  defp link(raw, evidence, candidates) do
    named = raw["card"] && find_ref(raw["card"], candidates)
    lines = MapSet.new(evidence, & &1.line.line_id)

    cond do
      named ->
        strength = if named["strength"] == "id", do: "id", else: named["strength"]
        link_json(named, strength)

      raw["kind"] in ["card_change", "action"] ->
        candidates
        |> Enum.filter(&(&1["type"] == "card" and Enum.any?(&1["lines"], fn l -> l in lines end)))
        |> Enum.sort_by(&strength_rank(&1["strength"]), :desc)
        |> List.first()
        |> then(&(&1 && link_json(&1, &1["strength"])))

      true ->
        nil
    end
  end

  defp find_ref(ref, candidates) do
    ref = String.trim(ref)

    Enum.find(candidates, fn c ->
      c["ref"] == ref or
        (c["type"] == "card" and Regex.match?(~r/^[A-Za-z][A-Za-z0-9]*-#{c["id"]}$/, ref) and
           not String.match?(ref, ~r/^[Ww]-/)) or
        (c["type"] == "page" and String.upcase(ref) == String.upcase(c["ref"] || ""))
    end)
  end

  defp strength_rank("id"), do: 3
  defp strength_rank("name"), do: 2
  defp strength_rank(_), do: 1

  defp link_json(c, strength) do
    %{
      "type" => c["type"],
      "id" => c["id"],
      "ref" => c["ref"],
      "title" => c["title"],
      "board_id" => c["board_id"],
      "version" => c["version"] || Version.current(c["type"], c["id"]),
      "strength" => strength
    }
  end

  defp existing_or_new(%{"kind" => "action"} = raw, %{"strength" => s} = link, _ev, _c)
       when s in ["name", "similarity"] do
    [
      %{
        kind: "existing_or_new",
        prompt:
          "Is “#{raw["title"]}” the existing card #{link["ref"]} “#{link["title"]}”, or new work?",
        options: [
          %{
            "value" => "card:#{link["id"]}",
            "label" => "#{link["ref"]} #{link["title"]}",
            "effect" => "change #{link["ref"]} instead of making a card"
          },
          %{"value" => "new", "label" => "A new card", "effect" => "make a new card"},
          %{"value" => "none", "label" => "Neither", "effect" => "leave it out"}
        ],
        context: %{"card_id" => link["id"]}
      }
    ]
  end

  defp existing_or_new(%{"kind" => "card_change"} = raw, nil, _evidence, candidates) do
    cards = candidates |> Enum.filter(&(&1["type"] == "card")) |> Enum.take(3)

    [
      %{
        kind: "existing_or_new",
        prompt:
          "Which card is “#{raw["title"]}” about? #{raw["card"] || "It names none"} isn't one Slipdock read.",
        options:
          Enum.map(cards, fn c ->
            %{
              "value" => "card:#{c["id"]}",
              "label" => "#{c["ref"]} #{c["title"]}",
              "effect" => "change #{c["ref"]}"
            }
          end) ++
            [
              %{"value" => "new", "label" => "A new card", "effect" => "make a new card"},
              %{"value" => "none", "label" => "Neither", "effect" => "leave it out"}
            ],
        context: %{"ref" => raw["card"]}
      }
    ]
  end

  defp existing_or_new(_raw, _link, _evidence, _candidates), do: []

  # Who said it matters when it decides who owns or who decided.
  defp who_said_it(raw, true, evidence, capture) do
    if raw["kind"] in ["decision", "action"] and is_nil(raw["owner"]) and
         is_nil(raw["decided_by"]) do
      line = Enum.find(evidence, & &1.line.voice_unsure).line

      [
        %{
          kind: "who_said_it",
          prompt:
            "Who said “#{String.slice(line.text, 0, 80)}” (#{line.line_id})? It decides who #{if raw["kind"] == "action", do: "owns it", else: "made the decision"}.",
          options:
            Enum.map(capture.attendees || [], fn a ->
              %{
                "value" =>
                  if(a["user_id"],
                    do: "user:#{a["user_id"]}",
                    else: "name:#{a["name"] || a["email"]}"
                  ),
                "label" => a["name"] || a["email"],
                "effect" => "#{a["name"] || a["email"]} said it"
              }
            end) ++
              [%{"value" => "none", "label" => "Not sure", "effect" => "leave it unattributed"}],
          context: %{"line" => line.line_id}
        }
      ]
    else
      []
    end
  end

  defp who_said_it(_raw, false, _evidence, _capture), do: []

  # An open question a page in the context already answers, read off the
  # same lines.
  defp wiki_answer(evidence, candidates) do
    lines = MapSet.new(evidence, & &1.line.line_id)

    Enum.find(candidates, fn c ->
      c["type"] == "page" and c["strength"] in ["id", "name", "similarity"] and
        Enum.any?(c["lines"], &MapSet.member?(lines, &1)) and
        not String.match?(c["title"] || "", ~r/^decisions\b/i)
    end)
  end

  defp known(link, answered, raw, capture) do
    linked =
      case link &&
             Enum.find(
               capture.context["candidates"] || [],
               &(&1["type"] == link["type"] and &1["id"] == link["id"])
             ) do
        nil -> []
        c -> [Map.take(c, ~w(type id ref title summary list done assignees due))]
      end

    answer =
      if answered,
        do: [Map.put(Map.take(answered, ~w(type id ref title summary)), "answers", true)],
        else: []

    superseded =
      if raw["kind"] == "decision" and raw["supersedes"] do
        [%{"type" => "decision", "title" => raw["supersedes"], "superseded" => true}]
      else
        []
      end

    linked ++ answer ++ superseded
  end

  ## Effects ---------------------------------------------------------------------

  defp effect(raw, link, owner, capture) do
    assignee =
      case owner do
        {:known, _, user} -> %{"assignee_id" => user.id, "assignee" => user.name || user.email}
        {_, name, _} -> %{"assignee" => name}
        {:unknown, name} -> %{"assignee" => name}
        nil -> %{}
      end

    due =
      if raw["due_date"],
        do: %{"due_date" => raw["due_date"], "due_said" => raw["due"]},
        else: %{}

    case {raw["kind"], link} do
      {"decision", _} ->
        topic = raw["topic"] |> blank() || "General"

        %{
          "type" => "decision_entry",
          "topic" => topic,
          "page" => "Decisions / #{topic}",
          "text" => raw["title"],
          "supersedes" => raw["supersedes"],
          "decided_by" => raw["decided_by"]
        }

      {kind, %{"type" => "card", "strength" => "id"} = link}
      when kind in ["action", "card_change"] ->
        change_effect(raw, link, assignee, due)

      {"card_change", %{"type" => "card"} = link} ->
        change_effect(raw, link, assignee, due)

      {"open_question", _} ->
        Map.merge(
          %{"type" => "new_card", "title" => raw["title"], "list" => list(capture, :backlog)},
          %{"description" => raw["body"]}
        )

      {_, _} ->
        %{
          "type" => "new_card",
          "title" => raw["title"],
          "description" => raw["body"],
          "list" => list(capture, :ready)
        }
        |> Map.merge(assignee)
        |> Map.merge(due)
    end
  end

  defp change_effect(raw, link, assignee, due) do
    changes =
      case raw["change"] do
        %{"field" => field, "to" => to} -> %{field => to}
        _ -> %{}
      end
      |> Map.merge(
        if(assignee["assignee_id"], do: %{"assignee_id" => assignee["assignee_id"]}, else: %{})
      )
      |> Map.merge(if(due["due_date"], do: %{"due_date" => due["due_date"]}, else: %{}))

    %{
      "type" => "card_change",
      "card_id" => link["id"],
      "ref" => link["ref"],
      "card_title" => link["title"],
      "changes" => changes,
      "comment" => raw["comment"] || (changes == %{} && raw["title"]) || nil
    }
    |> Map.reject(fn {_, v} -> v in [nil, false] end)
  end

  # The list a new card lands in: the ready list — the `todo` list called
  # To Do, Now, Ready, Selected or Next, else the first `todo` list that is
  # not a backlog, else the first list. An open question goes to the backlog
  # (a `todo` list called Backlog, Later or Icebox) when there is one. The
  # same reading of a board as the agents' guide gives.
  @ready ["to do", "todo", "now", "ready", "selected", "next"]
  @backlog ~w(backlog later icebox)

  defp list(capture, which) do
    columns =
      Repo.all(
        from(c in Column, where: c.board_id == ^capture.board_id, order_by: [asc: c.position])
      )

    named = fn names -> Enum.find(columns, &(String.downcase(&1.name) in names)) end
    todo = Enum.filter(columns, &(&1.category == "todo"))

    ready =
      named.(@ready) ||
        Enum.find(todo, &(String.downcase(&1.name) not in @backlog)) ||
        List.first(columns)

    chosen = if which == :backlog, do: named.(@backlog) || ready, else: ready
    chosen && chosen.name
  end

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  ## Writing it down ----------------------------------------------------------------

  defp insert_finding(capture, %{status: "dropped"} = f, position, _lines) do
    Repo.insert!(%Finding{
      capture_id: capture.id,
      position: position,
      kind: valid_kind(f.raw["kind"]),
      title: String.slice(f.raw["title"] || "", 0, 255),
      body: f.raw["body"],
      status: "dropped",
      drop_reason: f.reason,
      included: false,
      origin: if(f.reading == 0, do: "agent", else: "reading"),
      readings: [f.reading],
      effect: %{},
      signals: []
    })

    0
  end

  defp insert_finding(capture, f, position, _lines) do
    finding =
      Repo.insert!(%Finding{
        capture_id: capture.id,
        position: position,
        kind: f.kind,
        title: String.slice(f.raw["title"], 0, 255),
        body: f.raw["body"],
        effect: f.effect,
        included: f.included,
        status: "kept",
        origin: f.origin,
        readings: f.readings,
        signals: f.signals,
        links: f.links,
        known: f.known
      })

    for e <- f.evidence do
      Repo.insert!(%Evidence{
        finding_id: finding.id,
        utterance_id: e.line.id,
        line_id: e.line.line_id,
        char_start: e.from,
        char_end: e.to,
        quote: String.slice(e.line.text, e.from, e.to - e.from),
        speaker: e.line.speaker,
        start_ms: e.line.start_ms
      })
    end

    for q <- f.questions do
      Repo.insert!(%Question{
        capture_id: capture.id,
        finding_id: finding.id,
        kind: q.kind,
        prompt: q.prompt,
        options: q.options,
        blocking: true,
        context: q.context
      })
    end

    length(f.questions)
  end

  defp valid_kind(kind) when kind in ~w(decision action card_change open_question idea), do: kind
  defp valid_kind(_), do: "idea"
end
