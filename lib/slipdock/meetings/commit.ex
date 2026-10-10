defmodule Slipdock.Meetings.Commit do
  @moduledoc """
  Writing a reviewed capture to the board: the change set, its preview, and
  the commit.

  ## One structure, shown and applied (G6)

  `build/1` turns the included findings — as answered and edited — into a
  **change set**: an ordered list of changes (a card to create, fields of a
  card to change with their before and after, a comment, entries on a
  decisions page with the page's body after), plus what is left out, who
  will be told, and what slips as a knock-on. The preview renders exactly
  this map, and its `digest` names it. The commit builds it again and, given
  the digest the person saw, refuses if it is not the same — so what was
  previewed is what is written.

  ## Nothing over newer changes (G7)

  Each change to something that exists carries the version it was read at
  (`Slipdock.Meetings.Version`; a page's content hash). The commit checks
  them all first and refuses, naming each target that moved.

  ## All or nothing (G8)

  Every write happens in one database transaction; if any fails, none is
  kept.

  ## Once (G10)

  A committed capture is never committed again.

  ## Permissions

  The person committing needs write access to every board a change lands
  on, checked at commit time. Activity lines say each change came *via
  meeting capture*, committed by whom.
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Access, Boards, Meetings, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Column}
  alias Slipdock.Meetings.{Capture, Describe, Finding, Version}
  alias Slipdock.Wiki.Page

  ## Building ------------------------------------------------------------------

  @doc "The change set for a capture as it stands now."
  def build(%Capture{} = capture) do
    capture = Repo.preload(capture, [:board], force: true)

    findings =
      Repo.all(
        from(f in Finding,
          where: f.capture_id == ^capture.id,
          order_by: [asc: f.position, asc: f.id],
          preload: [:evidence]
        )
      )

    # What is still to be written: a finding is written once (G10), so one
    # already on the board is neither shown again nor left out.
    findings = Enum.reject(findings, & &1.written_at)

    {included, excluded} =
      Enum.split_with(
        findings,
        &(&1.status == "kept" and &1.included and not waiting?(capture, &1))
      )

    columns = Meetings.lists(capture.board_id)

    card_changes =
      included
      |> Enum.reject(&(&1.effect["type"] == "decision_entry"))
      |> Enum.flat_map(&card_changes(&1, capture, columns))
      |> merge_updates()

    decisions =
      included
      |> Enum.filter(&(&1.effect["type"] == "decision_entry"))
      |> decision_changes(capture)

    changes =
      (card_changes ++ decisions)
      |> Enum.with_index(1)
      |> Enum.map(fn {change, n} -> Map.put(change, "id", "c#{n}") end)

    set = %{
      "changes" => changes,
      "left_out" =>
        Enum.map(excluded, fn f ->
          %{
            "finding_id" => f.id,
            "title" => f.title,
            "why" =>
              cond do
                f.status == "dropped" -> "dropped: #{f.drop_reason}"
                waiting?(capture, f) -> "waiting for the speaker's answer"
                true -> "left out in review"
              end
          }
        end),
      "notify" => notify(changes),
      "knock_on" => knock_on(changes)
    }

    Map.put(set, "digest", digest(set))
  end

  # A finding whose question was put to the speaker waits for their answer;
  # the rest of the capture can still be committed (see `Slipdock.Meetings.Resolve`).
  defp waiting?(capture, finding) do
    Repo.exists?(
      from(q in Slipdock.Meetings.Question,
        where:
          q.capture_id == ^capture.id and q.finding_id == ^finding.id and q.status == "waiting"
      )
    )
  end

  @doc """
  Whether a committed capture has something left to write: an item that
  waited for its speaker and has been answered since.
  """
  def pending?(%Capture{state: "committed", undone_at: nil} = capture) do
    Repo.exists?(
      from(f in Finding,
        where:
          f.capture_id == ^capture.id and f.status == "kept" and f.included and
            is_nil(f.written_at)
      )
    ) and build(capture)["changes"] != []
  end

  def pending?(_capture), do: false

  @doc "Whether this capture can be committed now (the first time, or what waited)."
  def committable?(%Capture{state: "ready"}), do: true
  def committable?(%Capture{} = capture), do: pending?(capture)

  @doc "The fingerprint of a change set: what the preview showed, for the commit to match."
  def digest(set) do
    set
    |> Map.take(["changes", "left_out"])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp card_changes(%Finding{effect: %{"type" => "new_card"} = e} = f, capture, columns) do
    column = column_for(e["list"], columns)
    assignees = assignee_ids(e["assignee_id"])

    [
      %{
        "op" => "create_card",
        "finding_id" => f.id,
        "board_id" => capture.board_id,
        "column_id" => column && column.id,
        "list" => column && column.name,
        "title" => String.slice(e["title"] || f.title, 0, 255),
        "description" => for_someone_else(e["description"], e, assignees),
        "assignee_ids" => assignees,
        "assignees" => names(assignees),
        "due_date" => e["due_date"],
        "provenance" => provenance(f, capture)
      }
    ]
  end

  defp card_changes(%Finding{effect: %{"type" => "card_change"} = e} = f, capture, columns) do
    case Repo.get(Card, e["card_id"]) do
      nil ->
        [
          %{
            "op" => "update_card",
            "finding_id" => f.id,
            "card_id" => e["card_id"],
            "ref" => e["ref"],
            "title" => e["card_title"],
            "base_version" => base_version(f, e["card_id"], capture),
            "fields" => %{},
            "missing" => true
          }
        ]

      card ->
        card = Repo.preload(card, [:column, :assignees])
        fields = field_diffs(card, e["changes"] || %{}, columns)

        # Talking about a card that is done, to change it, reopens it.
        fields =
          if card.completed and fields != %{} and not Map.has_key?(fields, "completed"),
            do: Map.put(fields, "completed", %{"from" => true, "to" => false}),
            else: fields

        update =
          if fields == %{},
            do: [],
            else: [
              %{
                "op" => "update_card",
                "finding_id" => f.id,
                "board_id" => card.board_id,
                "card_id" => card.id,
                "ref" => "##{card.id}",
                "title" => card.title,
                "base_version" => base_version(f, card.id, capture),
                "fields" => fields,
                "provenance" => provenance(f, capture)
              }
            ]

        comment =
          case e["comment"] do
            text when is_binary(text) and text != "" ->
              [
                %{
                  "op" => "comment",
                  "finding_id" => f.id,
                  "board_id" => card.board_id,
                  "card_id" => card.id,
                  "ref" => "##{card.id}",
                  "title" => card.title,
                  "base_version" => base_version(f, card.id, capture),
                  "body" => comment_body(text, f, capture),
                  "provenance" => provenance(f, capture)
                }
              ]

            _ ->
              []
          end

        update ++ comment
    end
  end

  defp card_changes(_finding, _capture, _columns), do: []

  # Two findings changing the same card are one change to it, with both
  # sets of fields (the first finding's value wins where they overlap).
  defp merge_updates(changes) do
    changes
    |> Enum.reduce([], fn
      %{"op" => "update_card", "card_id" => id} = c, acc ->
        case Enum.find_index(acc, &(&1["op"] == "update_card" and &1["card_id"] == id)) do
          nil ->
            acc ++ [Map.put(c, "finding_ids", [c["finding_id"]])]

          i ->
            List.update_at(acc, i, fn first ->
              first
              |> Map.update!("fields", &Map.merge(c["fields"], &1))
              |> Map.update!("finding_ids", &(&1 ++ [c["finding_id"]]))
            end)
        end

      c, acc ->
        acc ++ [c]
    end)
  end

  # The version the review was based on: what the context step read, kept on
  # the finding's link. A link added by a person in review is read then.
  # For an item written after the rest of its capture (it waited for its
  # speaker), a card the earlier commit wrote is judged against what that
  # commit left, not what the review read before it.
  defp base_version(%Finding{links: links}, card_id, capture) do
    case earlier_version(capture, {:card, card_id}) do
      v when is_binary(v) ->
        v

      nil ->
        case Enum.find(links || [], &(&1["type"] == "card" and &1["id"] == card_id)) do
          %{"version" => v} when is_binary(v) -> v
          _ -> Version.current("card", card_id)
        end
    end
  end

  # The version an earlier commit of this capture left a target at, if it
  # wrote it.
  defp earlier_version(%Capture{change_set: %{"changes" => changes}}, target) do
    changes
    |> Enum.filter(&(target(&1) == target and &1["version_after"]))
    |> List.last()
    |> then(&(&1 && &1["version_after"]))
  end

  defp earlier_version(_capture, _target), do: nil

  defp field_diffs(card, changes, columns) do
    Enum.reduce(changes, %{}, fn
      {"due_date", to}, acc ->
        diff(acc, "due_date", card.due_date && Date.to_iso8601(card.due_date), to)

      {"start_date", to}, acc ->
        diff(acc, "start_date", card.start_date && Date.to_iso8601(card.start_date), to)

      {"title", to}, acc ->
        diff(acc, "title", card.title, to)

      {"description", to}, acc ->
        diff(acc, "description", card.description, to)

      {"priority", to}, acc ->
        diff(acc, "priority", card.priority, to)

      {"completed", to}, acc ->
        diff(acc, "completed", card.completed, to in [true, "true", "yes", "done"])

      {"list", name}, acc ->
        case column_for(name, columns) do
          nil ->
            acc

          col ->
            acc
            |> diff("column_id", card.column_id, col.id)
            |> then(
              &if(Map.has_key?(&1, "column_id"),
                do:
                  Map.put(&1, "list", %{
                    "from" => card.column && card.column.name,
                    "to" => col.name
                  }),
                else: &1
              )
            )
        end

      {key, id}, acc when key in ["assignee_id", "assignee"] and is_integer(id) ->
        before = Enum.map(card.assignees, & &1.id)
        diff(acc, "assignee_ids", before, Enum.uniq(before ++ [id]))

      _, acc ->
        acc
    end)
  end

  defp diff(acc, _field, same, same), do: acc
  defp diff(acc, _field, _from, nil), do: acc
  defp diff(acc, field, from, to), do: Map.put(acc, field, %{"from" => from, "to" => to})

  defp column_for(nil, [first | _] = columns), do: ready(columns) || first
  defp column_for(nil, []), do: nil

  defp column_for(name, columns) do
    Enum.find(columns, &(String.downcase(&1.name) == String.downcase(name))) ||
      column_for(nil, columns)
  end

  defp ready(columns),
    do:
      Enum.find(
        columns,
        &(&1.category == "todo" and String.downcase(&1.name) not in ["backlog", "later", "icebox"])
      )

  # Somebody who isn't on the board ("Someone not on this board", or a
  # speaker in the meeting) can't be assigned, so the card says who it's for.
  defp for_someone_else(description, %{"assignee" => name}, [])
       when is_binary(name) and name != "" do
    line = "For #{name} (not on this board)."
    if description in [nil, ""], do: line, else: line <> "\n\n" <> description
  end

  defp for_someone_else(description, _effect, _assignees), do: description

  defp assignee_ids(nil), do: []
  defp assignee_ids(id) when is_integer(id), do: [id]
  defp assignee_ids(_), do: []

  @doc "People's names (or emails), by id."
  def names(ids) do
    Repo.all(from(u in User, where: u.id in ^ids, select: {u.id, u.name, u.email}))
    |> Enum.map(fn {_, name, email} -> name || email end)
  end

  @doc """
  Where a change came from, kept with what it writes (G11): the meeting, when
  it was said, by whom, the words, how it was read, and — filled in at commit
  — who committed it.
  """
  def provenance(%Finding{} = f, %Capture{} = capture) do
    e = List.first(f.evidence || [])

    %{
      "capture_id" => capture.id,
      "meeting" => capture.title,
      "met_at" => capture.started_at && DateTime.to_iso8601(capture.started_at),
      "quote" => e && e.quote,
      "speaker" => e && e.speaker,
      "at_ms" => e && e.start_ms,
      "line" => e && e.line_id,
      "read" =>
        f.signals |> Enum.map(&Slipdock.Meetings.Verify.signal_label/1) |> Enum.join(", "),
      "added_by_person" => f.origin == "person"
    }
  end

  defp comment_body(text, f, capture) do
    e = List.first(f.evidence || [])

    quote =
      if e, do: "\n\n> #{e.quote}\n> — #{e.speaker || "unnamed"}, #{clock(e.start_ms)}", else: ""

    "#{text}#{quote}\n\nFrom the meeting “#{capture.title}”#{met(capture)}."
  end

  defp met(%Capture{started_at: nil}), do: ""
  defp met(%Capture{started_at: at}), do: " on #{Calendar.strftime(at, "%-d %b %Y")}"

  defp clock(nil), do: "—"

  defp clock(ms) do
    s = div(ms, 1000)
    "#{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"
  end

  ## Decisions -------------------------------------------------------------------

  # One page per meeting: every decision a capture writes goes on its own
  # page, "Decisions / <meeting> · <date>", grouped under a `## <topic>`
  # heading when they span more than one topic. An earlier entry a new
  # decision replaces is struck where it is — on this meeting's page, an
  # earlier meeting's, or an older page per topic — found among the
  # decisions the context step read. Each side links to the other's page.
  # One change per page touched.
  defp decision_changes([], _capture), do: []

  defp decision_changes(findings, capture) do
    pages = fn title ->
      Repo.one(
        from(p in Page,
          where: p.board_id == ^capture.board_id and p.title == ^title and is_nil(p.archived_at),
          limit: 1
        )
      )
    end

    {own, earlier} = meeting_page(capture)

    # The page is the meeting's, not the finding's: set here, as the build
    # sees it, whatever an older finding's effect says.
    findings = Enum.map(findings, &%{&1 | effect: Map.put(&1.effect, "page", own)})
    grouped? = length(Enum.uniq(earlier ++ Enum.map(findings, &topic/1))) > 1

    strikes =
      findings
      |> Enum.filter(& &1.effect["supersedes"])
      |> Enum.flat_map(fn f ->
        case where_decided(f, capture, pages) do
          nil -> []
          title -> [{title, f}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # The meeting's page first, then the earlier pages struck on.
    [own | Enum.sort(Map.keys(strikes) -- [own])]
    |> Enum.map(fn title ->
      page = pages.(title)
      group = if title == own, do: findings, else: []
      body = (page && page.body) || header(capture)

      {body, struck} =
        Enum.reduce(Map.get(strikes, title, []), {body, []}, fn f, {body, struck} ->
          {body, now} = strike(body, f.effect["supersedes"], f, title, capture)
          {body, struck ++ now}
        end)

      {body, added} =
        Enum.reduce(group, {body, []}, fn f, {body, added} ->
          entry = entry_line(f, capture, Enum.find(Map.keys(strikes), &(f in strikes[&1])))
          {place(body, topic(f), entry, grouped?, List.first(earlier)), added ++ [entry]}
        end)

      # The page as the review read it (the context step), for the stale
      # check: a page edited since, or made since, is not written over.
      read =
        page &&
          case earlier_version(capture, {:page, page.id}) do
            v when is_binary(v) ->
              %{"version" => v}

            nil ->
              Enum.find((capture.context || %{})["decisions"] || [], &(&1["page_id"] == page.id))
          end

      %{
        "op" => "decision_entry",
        "finding_ids" => Enum.map(group, & &1.id),
        "board_id" => capture.board_id,
        "page_id" => page && page.id,
        "page_title" => title,
        "base_hash" => page && page.content_hash,
        "base_version" => read && read["version"],
        "made_since_read" => page != nil and read == nil,
        "page_slug" => (page && page.slug) || slug_for(title, capture.board_id),
        "lines_added" => added,
        "lines_struck" => struck,
        "body_after" => body
      }
    end)
  end

  # The meeting's page, and the topics already on it (when this capture
  # made it in an earlier commit; none for a page still to be made).
  defp meeting_page(capture) do
    case made_page(capture) do
      %Page{title: title} ->
        earlier =
          Repo.all(
            from(f in Finding,
              where: f.capture_id == ^capture.id and not is_nil(f.written_at),
              order_by: [asc: f.position, asc: f.id]
            )
          )
          |> Enum.filter(&(&1.effect["type"] == "decision_entry"))
          |> Enum.map(&topic/1)
          |> Enum.uniq()

        {title, earlier}

      nil ->
        base = "Decisions / #{String.slice(capture.title || "", 0, 160)} · #{date(capture)}"

        title =
          Stream.iterate(1, &(&1 + 1))
          |> Stream.map(fn
            1 -> base
            n -> "#{base} (#{n})"
          end)
          |> Enum.find(fn title ->
            not Repo.exists?(
              from(p in Page,
                where:
                  p.board_id == ^capture.board_id and p.title == ^title and is_nil(p.archived_at)
              )
            )
          end)

        {title, []}
    end
  end

  # The page an earlier commit of this capture made, while it is still there.
  defp made_page(%Capture{change_set: %{"changes" => changes}}) do
    changes
    |> Enum.find(&(&1["op"] == "decision_entry" and &1["created_page"] == true))
    |> then(&(&1 && Repo.get(Page, &1["page_id"])))
    |> then(fn
      %Page{archived_at: nil} = page -> page
      _ -> nil
    end)
  end

  defp made_page(_capture), do: nil

  defp topic(%Finding{effect: effect}) do
    case String.trim(effect["topic"] || "") do
      "" -> "General"
      topic -> topic
    end
  end

  # A link to a decisions page that survives the " / " in its title (a slash
  # in a wiki link names another board): by slug, labelled with the title.
  defp link(title, capture), do: "[[#{slug_for(title, capture.board_id)}|#{title}]]"

  # The page's slug: its own if it exists, else the one it will be made with.
  defp slug_for(title, board_id) do
    case Repo.one(
           from(p in Page,
             where: p.board_id == ^board_id and p.title == ^title and is_nil(p.archived_at),
             select: p.slug,
             limit: 1
           )
         ) do
      nil ->
        Page.slug_from_title(title, fn slug ->
          Repo.exists?(from(p in Page, where: p.board_id == ^board_id and p.slug == ^slug))
        end)

      slug ->
        slug
    end
  end

  # Which page holds the decision this one replaces: this meeting's page if
  # the words are there (written by an earlier commit of it), else whichever
  # decisions page the context read has them, while it is still there.
  defp where_decided(f, capture, pages) do
    needle = Slipdock.Meetings.Context.normalise(f.effect["supersedes"])
    own = f.effect["page"]

    own_has? =
      case pages.(own) do
        %Page{body: body} ->
          String.contains?(Slipdock.Meetings.Context.normalise(body || ""), needle)

        nil ->
          false
      end

    if own_has? do
      own
    else
      # Only this board's decisions pages: a capture writes to its own board.
      ((capture.context || %{})["decisions"] || [])
      |> Enum.filter(&(&1["board_id"] in [nil, capture.board_id]))
      |> Enum.find(fn d ->
        Enum.any?(
          d["entries"] || [],
          &(not &1["superseded"] and
              String.contains?(Slipdock.Meetings.Context.normalise(&1["text"]), needle))
        )
      end)
      |> then(&(&1 && pages.(&1["title"]) && &1["title"]))
    end
  end

  # The top of a new page: the meeting, its date, who was there and the way
  # back to the capture. Plain sentences, not list items — the context step
  # reads list items as decisions.
  defp header(capture) do
    who =
      (capture.attendees || [])
      |> Enum.map(&(&1["name"] || &1[:name] || &1["email"] || &1[:email]))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [] -> ""
        names -> " Attendees: #{Enum.join(names, ", ")}."
      end

    "Decisions from the meeting “#{capture.title}” on #{date(capture)}.#{who} " <>
      "From [the meeting's capture](/boards/#{capture.board_id}/meetings/#{capture.id}). " <>
      "Newest last; a replaced decision is struck through.\n"
  end

  @doc false
  def entry_line(%Finding{} = f, capture, replaced_on \\ nil) do
    e = List.first(f.evidence || [])
    said = if e, do: " #{e.speaker || "Somebody"}: “#{e.quote}”", else: " (added in review)"
    by = if f.effect["decided_by"], do: " Decided by #{f.effect["decided_by"]}.", else: ""

    replaces =
      cond do
        is_nil(f.effect["supersedes"]) ->
          ""

        replaced_on && replaced_on != f.effect["page"] ->
          " Replaces “#{f.effect["supersedes"]}” on #{link(replaced_on, capture)}."

        true ->
          " Replaces “#{f.effect["supersedes"]}”."
      end

    "- **#{f.effect["text"] || f.title}** — #{date(capture)}, in “#{capture.title}”.#{said}#{by}#{replaces}"
  end

  defp date(%Capture{started_at: nil, inserted_at: at}), do: Calendar.strftime(at, "%-d %b %Y")
  defp date(%Capture{started_at: at}), do: Calendar.strftime(at, "%-d %b %Y")

  # An earlier entry the decision replaces is struck through, saying what
  # replaced it and where — found by its words, among the entries not already
  # struck.
  defp strike(body, supersedes, f, on_page, capture) do
    needle = Slipdock.Meetings.Context.normalise(supersedes)
    lines = String.split(body, "\n")

    case Enum.find_index(lines, fn line ->
           String.match?(line, ~r/^\s*[-*]\s+(?!~~)/) and
             String.contains?(Slipdock.Meetings.Context.normalise(line), needle)
         end) do
      nil ->
        {body, []}

      i ->
        line = Enum.at(lines, i)
        [_, bullet, text] = Regex.run(~r/^(\s*[-*]\s+)(.*)$/, line)

        where =
          if on_page == f.effect["page"], do: "", else: " on #{link(f.effect["page"], capture)}"

        struck = "#{bullet}~~#{text}~~ (replaced by “#{f.effect["text"] || f.title}”#{where})"
        {lines |> List.replace_at(i, struck) |> Enum.join("\n"), [line]}
    end
  end

  # An entry onto the meeting's page: at the end, or — when the meeting's
  # decisions span more than one topic — at the end of its topic's `##`
  # section, made if it is not there. A page an earlier commit wrote with one
  # topic and no headings gets that topic's heading over what is on it first.
  defp place(body, _topic, line, false, _earlier), do: append_line(body, line)

  defp place(body, topic, line, true, earlier) do
    lines = body |> String.trim_trailing() |> String.split("\n")
    lines = if earlier, do: head_up(lines, earlier), else: lines
    heading = "## #{topic}"

    case Enum.find_index(lines, &(String.trim(&1) == heading)) do
      nil ->
        Enum.join(lines, "\n") <> "\n\n" <> heading <> "\n\n" <> line <> "\n"

      i ->
        {section, rest} =
          case Enum.find_index(Enum.drop(lines, i + 1), &topic_heading?/1) do
            nil -> {lines, []}
            j -> Enum.split(lines, i + 1 + j)
          end

        section =
          section |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

        rest = if rest == [], do: [], else: ["" | rest]
        Enum.join(section ++ [line] ++ rest, "\n") <> "\n"
    end
  end

  defp head_up(lines, earlier) do
    with false <- Enum.any?(lines, &topic_heading?/1),
         i when is_integer(i) <- Enum.find_index(lines, &String.match?(&1, ~r/^\s*[-*]\s+/)) do
      {top, entries} = Enum.split(lines, i)
      top ++ ["## #{earlier}", ""] ++ entries
    else
      _ -> lines
    end
  end

  defp topic_heading?(line), do: String.match?(line, ~r/^##(?!#)\s+\S/)

  # A line onto the end of a page; a list starts a paragraph of its own.
  defp append_line(body, line) do
    body = String.trim_trailing(body)
    last = body |> String.split("\n") |> List.last()

    gap =
      cond do
        body == "" -> ""
        String.match?(last, ~r/^\s*[-*]\s+/) -> "\n"
        true -> "\n\n"
      end

    body <> gap <> line <> "\n"
  end

  ## Who hears, and what slips --------------------------------------------------

  defp notify(changes) do
    Enum.flat_map(changes, fn
      %{"op" => "create_card", "assignees" => names, "title" => t} ->
        Enum.map(names, &%{"who" => &1, "why" => "assigned “#{t}”"})

      %{
        "op" => "update_card",
        "fields" => %{"assignee_ids" => %{"from" => from, "to" => to}},
        "title" => t
      } ->
        (to -- from) |> names() |> Enum.map(&%{"who" => &1, "why" => "assigned “#{t}”"})

      _ ->
        []
    end)
  end

  # Cards a changed card blocks, whose own due date is now before the card
  # they wait on is due.
  defp knock_on(changes) do
    Enum.flat_map(changes, fn
      %{
        "op" => "update_card",
        "card_id" => id,
        "fields" => %{"due_date" => %{"to" => to}},
        "ref" => ref
      }
      when is_binary(to) ->
        with {:ok, new_due} <- Date.from_iso8601(to),
             %Card{} = card <- Repo.get(Card, id) do
          card
          |> Repo.preload(:blocks)
          |> Map.get(:blocks)
          |> Enum.filter(
            &((&1.due_date && Date.compare(&1.due_date, new_due) == :lt) and
                is_nil(&1.archived_at))
          )
          |> Enum.map(fn b ->
            %{
              "card_id" => b.id,
              "ref" => "##{b.id}",
              "title" => b.title,
              "why" =>
                "waits on #{ref}, now due #{Describe.date(to)}, but is due #{Describe.date(Date.to_iso8601(b.due_date))}"
            }
          end)
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  ## Checking --------------------------------------------------------------------

  @doc """
  What has moved since the review read it (G7): each change whose target's
  version is no longer the one it was based on, as `%{ref, title, why}`.
  """
  def stale(%{"changes" => changes}) do
    changes
    |> Enum.flat_map(fn
      %{"op" => op, "missing" => true} = c when op in ["update_card", "comment"] ->
        [%{"ref" => c["ref"], "title" => c["title"], "why" => "it no longer exists"}]

      %{"op" => op, "card_id" => id, "base_version" => base} = c
      when op in ["update_card", "comment"] ->
        case Version.current("card", id) do
          nil ->
            [%{"ref" => c["ref"], "title" => c["title"], "why" => "it no longer exists"}]

          ^base ->
            []

          _ ->
            [
              %{
                "ref" => c["ref"],
                "title" => c["title"],
                "why" => "it was changed after the review read it"
              }
            ]
        end

      %{"op" => "decision_entry", "page_id" => nil} = c ->
        if Repo.exists?(
             from(p in Page,
               where:
                 p.board_id == ^c["board_id"] and p.title == ^c["page_title"] and
                   is_nil(p.archived_at)
             )
           ),
           do: [
             %{
               "ref" => nil,
               "title" => c["page_title"],
               "why" => "it was made after the review read the wiki"
             }
           ],
           else: []

      %{"op" => "decision_entry", "made_since_read" => true} = c ->
        [
          %{
            "ref" => nil,
            "title" => c["page_title"],
            "why" => "it was made after the review read the wiki"
          }
        ]

      %{"op" => "decision_entry", "page_id" => id, "base_version" => base} = c ->
        case Repo.get(Page, id) do
          nil ->
            [%{"ref" => nil, "title" => c["page_title"], "why" => "it no longer exists"}]

          %Page{} = p ->
            if Version.of(p) == base,
              do: [],
              else: [
                %{
                  "ref" => p.code,
                  "title" => c["page_title"],
                  "why" => "it was edited after the review read it"
                }
              ]
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # Every board a change lands on, that the committer may not write to.
  defp unwritable(%{"changes" => changes}, user) do
    changes
    |> Enum.map(& &1["board_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(fn id ->
      board = Repo.get!(Slipdock.Boards.Board, id)
      Access.can_write?(Access.board_permission(user, board))
    end)
  end

  ## Committing --------------------------------------------------------------------

  @doc """
  Commits a capture. Options: `:digest` (the preview's — refused if the
  change set is no longer the one previewed), `:via` (`web`, `api`,
  `agent`).

  `{:ok, capture}`, or `{:error, :conflict, message}` (already committed, not
  ready, changed since the preview), `{:error, :stale, [target]}` (G7),
  `{:error, :forbidden, message}`, or `{:error, message}` when a write fails
  (and nothing was written).
  """
  def commit(%Capture{} = capture, %User{} = user, opts \\ []) do
    capture = Repo.get!(Capture, capture.id)
    set = build(capture)

    with :ok <- committable(capture),
         :ok <- something(set),
         [] <- unwritable(set, user) |> forbidden(),
         [] <- stale(set),
         :ok <- same_preview(set, opts[:digest]) do
      apply_set(capture, set, user, opts)
    else
      {:error, _, _} = error -> error
      {:forbidden, message} -> {:error, :forbidden, message}
      stale when is_list(stale) -> {:error, :stale, stale}
    end
  end

  # A capture committed while an item waited for its speaker: once they
  # answer, that item is written in a commit of its own. Nothing else is
  # written twice.
  defp committable(%Capture{state: "committed", undone_at: nil} = capture) do
    if pending?(capture),
      do: :ok,
      else: {:error, :conflict, "this capture was committed already; it is never written twice"}
  end

  defp committable(%Capture{state: "committed"}),
    do: {:error, :conflict, "this capture was committed already; it is never written twice"}

  defp committable(%Capture{state: "discarded"}),
    do: {:error, :conflict, "this capture was discarded, so nothing from it can be written"}

  defp committable(%Capture{state: "ready"}), do: :ok

  defp committable(%Capture{state: "needs_review"}),
    do: {:error, :conflict, "questions are still open: answer them before committing"}

  defp committable(%Capture{state: state}),
    do: {:error, :conflict, "this capture is #{state}, not ready to commit"}

  defp same_preview(_set, nil), do: :ok
  defp same_preview(%{"digest" => d}, d), do: :ok

  defp same_preview(_set, _digest),
    do:
      {:error, :conflict,
       "the review changed since that preview: look at the preview again before committing"}

  defp something(%{"changes" => []}),
    do: {:error, :conflict, "nothing is included, so there is nothing to commit"}

  defp something(_), do: :ok

  defp forbidden([]), do: []

  defp forbidden(board_ids) do
    names = Repo.all(from(b in Slipdock.Boards.Board, where: b.id in ^board_ids, select: b.name))
    {:forbidden, "you can't write to #{Enum.join(names, ", ")}, where this capture would write"}
  end

  defp apply_set(capture, set, user, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {result, effects} =
      Slipdock.Deferred.collect(fn ->
        Repo.transaction(fn ->
          # The capture's row, held: two commits at once (two tabs, an agent
          # retrying) queue here, and the second finds the first's work done.
          locked = Repo.one!(from(c in Capture, where: c.id == ^capture.id, lock: "FOR UPDATE"))

          case committable(locked) do
            :ok -> :ok
            {:error, :conflict, message} -> Repo.rollback({:conflict, message})
          end

          ids = Enum.flat_map(set["changes"], &(&1["finding_ids"] || [&1["finding_id"]]))

          if Repo.exists?(from(f in Finding, where: f.id in ^ids and not is_nil(f.written_at))),
            do:
              Repo.rollback(
                {:conflict, "this capture was committed already; it is never written twice"}
              )

          capture = locked
          commit_inside(capture, set, user, opts, now)
        end)
      end)

    case result do
      {:ok, capture} ->
        Slipdock.Deferred.run(effects)
        Meetings.broadcast(capture)
        {:ok, capture}

      {:error, {:conflict, message}} ->
        {:error, :conflict, message}

      {:error, {change, reason}} ->
        {:error, "nothing was written: #{change_words(change)} failed (#{reason_words(reason)})"}
    end
  end

  defp commit_inside(capture, set, user, opts, now) do
    applied =
      set["changes"]
      |> Enum.with_index(1)
      |> Enum.map(fn {change, n} ->
        case apply_change(change, capture, user) do
          {:ok, done} ->
            # A test's way in, to fail a write part of the way through.
            case opts[:after_change] && opts[:after_change].(n, change) do
              {:error, reason} -> Repo.rollback({change, reason})
              _ -> Map.merge(change, done)
            end

          {:error, reason} ->
            Repo.rollback({change, reason})
        end
      end)

    # What each target looks like once everything is written: undo
    # compares with it to see what has been edited since.
    applied = Enum.map(applied, &with_version_after/1)

    written_ids =
      applied
      |> Enum.flat_map(&(&1["finding_ids"] || [&1["finding_id"]]))
      |> Enum.reject(&is_nil/1)

    Repo.update_all(from(f in Finding, where: f.id in ^written_ids), set: [written_at: now])

    {:ok, capture} =
      if capture.state == "committed" do
        # What waited for its speaker, written now: added to the record of
        # the commit, numbered on from it, so undo reverses the lot.
        # Earlier changes to a target this commit writes again now
        # stand at this commit's version, so undo does not mistake our
        # own later write for somebody's edit.
        touched = MapSet.new(applied, &target/1)

        earlier =
          Enum.map(capture.change_set["changes"] || [], fn c ->
            if MapSet.member?(touched, target(c)), do: with_version_after(c), else: c
          end)

        applied =
          applied
          |> Enum.with_index(length(earlier) + 1)
          |> Enum.map(fn {c, n} -> Map.put(c, "id", "c#{n}") end)

        later = %{
          "at" => DateTime.to_iso8601(now),
          "by" => user.email,
          "changes" => length(applied)
        }

        capture
        |> Ecto.Changeset.change(
          change_set:
            Map.merge(capture.change_set, %{
              "changes" => earlier ++ applied,
              "later" => (capture.change_set["later"] || []) ++ [later]
            })
        )
        |> Repo.update()
      else
        capture
        |> Capture.transition("committed", %{
          change_set:
            Map.merge(set, %{
              "changes" => applied,
              "committed_at" => DateTime.to_iso8601(now),
              "committed_by" => user.email
            }),
          committed_at: now,
          committed_by_id: user.id,
          state_reason: nil
        })
        |> Repo.update()
      end

    Meetings.record(
      capture,
      "committed",
      "Committed #{length(applied)} #{if length(applied) == 1, do: "change", else: "changes"}#{via_words(opts[:via])}.",
      user: user,
      via: opts[:via],
      data: %{"digest" => set["digest"]}
    )

    capture
  end

  defp target(%{"op" => "decision_entry", "page_id" => id}), do: {:page, id}
  defp target(%{"card_id" => id}), do: {:card, id}
  defp target(_), do: nil

  defp with_version_after(%{"op" => "decision_entry", "page_id" => id} = c),
    do: Map.put(c, "version_after", Version.current("page", id))

  defp with_version_after(%{"card_id" => id} = c) when is_integer(id),
    do: Map.put(c, "version_after", Version.current("card", id))

  defp with_version_after(c), do: c

  defp via_words("agent"), do: " via agent"
  defp via_words(_), do: ""

  defp change_words(%{"op" => "create_card", "title" => t}), do: "making the card “#{t}”"
  defp change_words(%{"op" => "update_card", "ref" => r}), do: "changing #{r}"
  defp change_words(%{"op" => "comment", "ref" => r}), do: "commenting on #{r}"
  defp change_words(%{"op" => "decision_entry", "page_title" => t}), do: "writing to #{t}"

  defp reason_words(%Ecto.Changeset{} = cs) do
    Slipdock.Quota.refusal_message(cs) ||
      Enum.map_join(cs.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp reason_words(reason) when is_binary(reason), do: reason
  defp reason_words(reason), do: inspect(reason)

  # Each change applied through the same functions every other writer uses,
  # so quotas, mentions, automations and the search index see it as usual.
  defp apply_change(%{"op" => "create_card"} = c, capture, user) do
    column = c["column_id"] && Repo.get(Column, c["column_id"])

    if is_nil(column) do
      {:error, "the board has no list to put it in"}
    else
      attrs =
        %{"title" => c["title"], "description" => c["description"], "due_date" => c["due_date"]}
        |> Map.reject(fn {_, v} -> is_nil(v) end)
        |> then(fn a ->
          if c["assignee_ids"] != [], do: Map.put(a, "assignee_ids", c["assignee_ids"]), else: a
        end)

      with {:ok, card} <- Boards.create_card(column, attrs, by: user) do
        :ok = provenance_for(card, c, user)
        log(card.board_id, card.id, "added “#{card.title}”", capture, user)
        {:ok, %{"card_id" => card.id, "ref" => "##{card.id}"}}
      end
    end
  end

  defp apply_change(
         %{"op" => "update_card", "card_id" => id, "fields" => fields} = c,
         capture,
         user
       ) do
    card = Repo.get!(Card, id)

    attrs =
      Enum.reduce(fields, %{}, fn
        {"assignee_ids", %{"to" => to}}, acc -> Map.put(acc, "assignee_ids", to)
        {"list", _}, acc -> acc
        {field, %{"to" => to}}, acc -> Map.put(acc, field, to)
      end)

    with {:ok, card} <- Boards.update_card(card, attrs, by: user) do
      :ok = provenance_for(card, c, user)

      log(
        card.board_id,
        card.id,
        "changed #{Enum.join(Map.keys(fields) -- ["list"], ", ")} on “#{card.title}”",
        capture,
        user
      )

      {:ok, %{}}
    end
  end

  defp apply_change(%{"op" => "comment", "card_id" => id, "body" => body}, capture, user) do
    card = Repo.get!(Card, id)

    with {:ok, comment} <- Boards.add_comment(card, body, by: user) do
      log(card.board_id, card.id, "commented on “#{card.title}”", capture, user)
      {:ok, %{"comment_id" => comment.id}}
    end
  end

  defp apply_change(%{"op" => "decision_entry"} = c, capture, user) do
    board = Repo.get!(Slipdock.Boards.Board, c["board_id"])

    result =
      case c["page_id"] && Repo.get(Page, c["page_id"]) do
        nil ->
          with {:ok, page} <-
                 Wiki.create_page(
                   board,
                   %{
                     "title" => c["page_title"],
                     "slug" => c["page_slug"],
                     "body" => c["body_after"]
                   },
                   user: user,
                   via: "meeting",
                   message: "From the meeting “#{capture.title}”"
                 ) do
            {:ok, page, nil}
          end

        page ->
          before = page.body

          case Wiki.update_page(page, %{"body" => c["body_after"]},
                 user: user,
                 via: "meeting",
                 message: "From the meeting “#{capture.title}”",
                 base_hash: c["base_hash"],
                 new_revision: true
               ) do
            {:ok, page} ->
              {:ok, page, before}

            {:error, :conflict, _} ->
              {:error, "#{c["page_title"]} was edited after the review read it"}

            other ->
              other
          end
      end

    with {:ok, page, before} <- result do
      log(
        board.id,
        nil,
        "wrote #{length(c["lines_added"])} decision(s) to “#{page.title}”",
        capture,
        user
      )

      {:ok,
       %{
         "page_id" => page.id,
         "page_slug" => page.slug,
         "page_code" => page.code,
         "created_page" => before == nil and c["page_id"] == nil,
         "body_before" => before,
         "hash_after" => page.content_hash
       }}
    end
  end

  # Where it came from, on the card itself (G11), and into the search index
  # with it.
  defp provenance_for(card, change, user) do
    if prov = change["provenance"] do
      kind = if change["op"] == "create_card", do: "created", else: "changed"

      Slipdock.Meetings.Provenance.record(
        card,
        Map.put(prov, "committed_by", user.name || user.email),
        kind
      )

      Slipdock.Search.Indexer.enqueue(card)
    end

    :ok
  end

  defp log(board_id, card_id, what, capture, user) do
    Boards.log_activity(
      board_id,
      card_id,
      "meeting",
      "#{what} via meeting capture “#{capture.title}”, committed by #{user.name || user.email}"
    )
  end
end
