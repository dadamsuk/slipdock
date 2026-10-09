defmodule Slipdock.Meetings.Speakers do
  @moduledoc """
  Who spoke (pipeline steps 3 and 4). Who said something decides who owns an
  action and who made a decision, so it gets its own processing, its own
  evidence, and its own review screen (*Who said what*).

  ## Voices (step 3)

  How voices are separated is the admin's choice (Configuration › Meetings):

    * `"labels"` (the default) — the transcript's own speaker labels are the
      voices: one per distinct label.
    * `"endpoint"` — a diarisation service of the admin's, sent the
      recording, answering `{"segments": [{"start": 1.2, "end": 4.0,
      "speaker": "SPEAKER_00"}, …]}` (seconds). A pyannote or WhisperX
      server fits. Each line takes the voice it overlaps most; a line two
      voices share for more than a third of it is *voice unsure*. It is used
      for a recording whose transcript has no labels of its own.

  ## Who each voice is (step 4)

  Evidence, each kept and shown:

    * **the transcript's label** — a name or address matching a member or an
      attendee (strong when it is the whole name, weaker for a first name
      alone; "Speaker 3" is nothing);
    * **dialogue** (unless the admin turns it off) — being addressed by name
      and then answering ("Good question, Sam." then this voice), introducing
      themselves ("I'm Sam", "Sam here");
    * **a voiceprint** (only where an admin has turned voiceprints on, and only
      for people who enrolled themselves — `Slipdock.Meetings.Voiceprints`) —
      the voice's own lines sound like that person's voiceprint;
    * **elimination** — the one voice left, and the one attendee left.

  A voice with strong or agreeing evidence is *sure*; one weak signal is
  *please confirm*; none is *unknown*. Two voices that land on the same
  person were one person split in two: they are merged, and the merge shows.
  Lines two voices talk over are *voice unsure*, and only become a question
  when a finding depends on them (`Slipdock.Meetings.Verify`).

  ## Changing a voice's person

  A finding that took its owner or decision-maker from who was speaking
  remembers the voice (`owner_voice_id`, `decided_by_voice_id` in its effect).
  `reassign/3` changes the voice and re-derives exactly those findings —
  no model is asked again.
  """
  import Ecto.Query, warn: false, except: [first: 1]

  alias Slipdock.{Meetings, Repo, Settings}
  alias Slipdock.Accounts.User
  alias Slipdock.Meetings.{Capture, Finding, Utterance, Voice, Voiceprints}

  ## Step 3: voices ----------------------------------------------------------

  @doc "Separates the voices (step 3)."
  def diarise(%Capture{} = capture, opts \\ []) do
    lines = lines(capture)
    labelled? = Enum.any?(lines, & &1.speaker)
    s = Settings.get()

    turns =
      cond do
        labelled? ->
          {:labels, nil}

        s.meetings_diarisation == "endpoint" and capture.audio_key ->
          diarisation_turns(capture, s, opts)

        true ->
          {:labels, nil}
      end

    case turns do
      {:error, reason} ->
        {:error, reason}

      {:labels, _} ->
        store_voices(capture, Enum.map(lines, &{&1, &1.speaker, false}))

      {:turns, segments} ->
        store_voices(capture, Enum.map(lines, &assign_turn(&1, segments)))
    end
  end

  defp lines(capture) do
    Repo.all(from(u in Utterance, where: u.capture_id == ^capture.id, order_by: u.position))
  end

  defp store_voices(capture, assigned) do
    labels = assigned |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.transaction(fn ->
      Repo.update_all(from(u in Utterance, where: u.capture_id == ^capture.id),
        set: [voice_id: nil]
      )

      Repo.delete_all(from(v in Voice, where: v.capture_id == ^capture.id))

      voices =
        Map.new(labels, fn label ->
          {label, Repo.insert!(%Voice{capture_id: capture.id, label: label})}
        end)

      for {line, label, unsure} <- assigned, label do
        Repo.update_all(from(u in Utterance, where: u.id == ^line.id),
          set: [voice_id: voices[label].id, voice_unsure: unsure]
        )
      end
    end)

    {:ok, capture}
  end

  defp diarisation_turns(capture, s, opts) do
    path = Meetings.audio_path(capture)

    req =
      Req.new(
        [base_url: s.meetings_diarisation_url, receive_timeout: 600_000, retry: false] ++
          Keyword.get(Slipdock.Config.get(:meetings, []), :diarisation_req_options, []) ++
          (opts[:req] || [])
      )

    case Req.post(req,
           form_multipart: [
             file: {File.read!(path), filename: capture.audio_filename || "recording"}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"segments" => segments}}} when is_list(segments) ->
        {:turns,
         Enum.map(segments, fn seg ->
           %{
             start: round((seg["start"] || 0) * 1000),
             stop: round((seg["end"] || 0) * 1000),
             speaker: to_string(seg["speaker"])
           }
         end)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         "the diarisation endpoint said #{status}: #{inspect(body) |> String.slice(0, 200)}"}

      {:error, e} ->
        {:error, "couldn't reach the diarisation endpoint (#{Exception.message(e)})"}
    end
  end

  # The voice a line overlaps most; unsure when another overlaps it by more
  # than a third.
  defp assign_turn(%Utterance{start_ms: nil} = line, _segments), do: {line, nil, false}

  defp assign_turn(line, segments) do
    stop = line.end_ms || line.start_ms + 1

    overlaps =
      segments
      |> Enum.map(fn s ->
        {s.speaker, max(0, min(stop, s.stop) - max(line.start_ms, s.start))}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {speaker, ms} -> {speaker, Enum.sum(ms)} end)
      |> Enum.filter(&(elem(&1, 1) > 0))
      |> Enum.sort_by(&elem(&1, 1), :desc)

    case overlaps do
      [] -> {line, nil, false}
      [{best, _}] -> {line, label(best), false}
      [{best, _}, {_, second} | _] -> {line, label(best), second > (stop - line.start_ms) / 3}
    end
  end

  defp label(speaker), do: "Voice #{speaker}"

  ## Step 4: who each voice is ------------------------------------------------

  @doc "Attributes each voice to a person (step 4)."
  def attribute(%Capture{} = capture, opts \\ []) do
    voices = Repo.all(from(v in Voice, where: v.capture_id == ^capture.id, order_by: v.id))
    lines = lines(capture)
    people = people(capture)
    dialogue? = Settings.get().meetings_dialogue_inference != false

    evidence =
      Map.new(voices, fn v -> {v.id, label_evidence(v, people)} end)
      |> add_all(if(dialogue?, do: dialogue_evidence(lines, people), else: []))
      |> add_all(Voiceprints.evidence(capture, voices, people, opts))

    decided = Map.new(voices, fn v -> {v.id, decide(Map.get(evidence, v.id, []))} end)
    decided = eliminate(voices, decided, people, capture)

    Repo.transaction(fn ->
      for v <- voices do
        {person, confidence, items} = decided[v.id]

        v
        |> Voice.changeset(%{
          name: person && person.name,
          user_id: person && person.user_id,
          evidence: items,
          confidence: confidence
        })
        |> Repo.update!()
      end

      merge_split_voices(capture)
    end)

    {:ok, capture}
  end

  # Everybody a voice could be: the board's members and the attendees.
  defp people(capture) do
    board = Repo.get!(Slipdock.Boards.Board, capture.board_id)
    members = Slipdock.Wiki.Links.members(board)

    from_members =
      Enum.map(members, fn u ->
        %{name: u.name || handle(u.email), user_id: u.id, email: u.email, attendee?: false}
      end)

    attendees =
      Enum.map(capture.attendees || [], fn a ->
        %{
          name: a["name"] || a["email"],
          user_id: a["user_id"],
          email: a["email"],
          attendee?: true
        }
      end)

    (attendees ++ from_members)
    |> Enum.reject(&is_nil(&1.name))
    |> Enum.uniq_by(&(&1.user_id || String.downcase(&1.name)))
    |> Enum.map(fn p ->
      member = p.user_id && Enum.find(members, &(&1.id == p.user_id))

      %{
        p
        | attendee?:
            p.attendee? or
              Enum.any?(capture.attendees || [], &(&1["user_id"] && &1["user_id"] == p.user_id)),
          name: (member && member.name) || p.name
      }
    end)
  end

  defp handle(email), do: email |> String.split("@") |> hd()

  defp label_evidence(%Voice{label: label}, people) do
    said = String.downcase(String.trim(label))

    cond do
      Regex.match?(~r/^(speaker|voice|spk|unknown|participant)\b/i, label) ->
        []

      p =
          Enum.find(
            people,
            &(String.downcase(&1.name) == said or (&1.email && String.downcase(&1.email) == said))
          ) ->
        [
          %{
            "kind" => "label",
            "person" => key(p),
            "name" => p.name,
            "strength" => "strong",
            "detail" => "the transcript calls this voice “#{label}”"
          }
        ]

      p = Enum.find(people, &(first(&1.name) == said)) ->
        [
          %{
            "kind" => "label",
            "person" => key(p),
            "name" => p.name,
            "strength" => "medium",
            "detail" => "the transcript calls this voice “#{label}”"
          }
        ]

      true ->
        []
    end
  end

  defp first(name), do: name |> String.downcase() |> String.split() |> List.first()
  defp key(p), do: if(p.user_id, do: "user:#{p.user_id}", else: "name:#{p.name}")

  # Being addressed and then answering; introducing oneself.
  defp dialogue_evidence(lines, people) do
    firsts =
      people
      |> Enum.map(&{first(&1.name), &1})
      |> Enum.reject(fn {f, _} -> is_nil(f) or String.length(f) < 2 end)
      |> Enum.uniq_by(&elem(&1, 0))

    indexed = Enum.with_index(lines)

    Enum.flat_map(indexed, fn {line, i} ->
      text = line.text

      addressed =
        for {f, p} <- firsts,
            addressed?(text, f),
            reply = next_other_voice(lines, i, line.voice_id),
            reply do
          {reply.voice_id,
           %{
             "kind" => "addressed",
             "person" => key(p),
             "name" => p.name,
             "line" => reply.line_id,
             "strength" => "weak",
             "detail" =>
               "“#{String.slice(text, 0, 60)}” (#{line.line_id}), then this voice answered (#{reply.line_id})"
           }}
        end

      intro =
        for {f, p} <- firsts,
            line.voice_id,
            Regex.match?(
              ~r/\b(i'?m|i am|this is|it'?s)\s+#{Regex.escape(f)}\b|^#{Regex.escape(f)}\s+here\b/iu,
              text
            ) do
          {line.voice_id,
           %{
             "kind" => "introduced",
             "person" => key(p),
             "name" => p.name,
             "line" => line.line_id,
             "strength" => "medium",
             "detail" => "introduced themselves: “#{String.slice(text, 0, 60)}” (#{line.line_id})"
           }}
        end

      addressed ++ intro
    end)
  end

  # "Sam, can you…", "Good question, Sam.", "…that's yours then, Sam?"
  defp addressed?(text, first) do
    f = Regex.escape(first)
    Regex.match?(~r/(^|[.!?]\s+)#{f}\s*,|,\s*#{f}\s*[.!?]?\s*$|,\s*#{f}\s*[.!?]/iu, text)
  end

  defp next_other_voice(lines, i, voice_id) do
    lines
    |> Enum.drop(i + 1)
    |> Enum.take(2)
    |> Enum.find(&(&1.voice_id && &1.voice_id != voice_id))
  end

  defp add_all(evidence, pairs) do
    Enum.reduce(pairs, evidence, fn {voice_id, item}, acc ->
      if Map.has_key?(acc, voice_id), do: Map.update!(acc, voice_id, &(&1 ++ [item])), else: acc
    end)
  end

  @points %{"strong" => 3, "medium" => 2, "weak" => 1}

  # The person the evidence points at most, and how sure that is.
  defp decide([]), do: {nil, "unknown", []}

  defp decide(items) do
    scores =
      items
      |> Enum.group_by(& &1["person"])
      |> Enum.map(fn {person, its} ->
        {person, its |> Enum.map(&@points[&1["strength"]]) |> Enum.sum(), hd(its)["name"]}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    [{person, score, name} | rest] = scores
    rival = Enum.any?(rest, fn {_, s, _} -> s >= score end)

    confidence = if score >= 2 and not rival, do: "sure", else: "confirm"
    {person_of(person, name), confidence, items}
  end

  defp person_of("user:" <> id, name), do: %{user_id: String.to_integer(id), name: name}
  defp person_of("name:" <> name, _), do: %{user_id: nil, name: name}

  # The one voice nobody has, and the one attendee nobody is.
  defp eliminate(voices, decided, people, capture) do
    open = Enum.filter(voices, fn v -> elem(decided[v.id], 0) == nil end)

    taken =
      decided
      |> Map.values()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(&1.user_id || &1.name))

    left =
      Enum.filter(people, fn p ->
        p.attendee? and (p.user_id || p.name) not in taken
      end)

    case {open, left, capture.attendees} do
      {[voice], [p], [_ | _]} when length(voices) > 1 ->
        item = %{
          "kind" => "elimination",
          "person" => key(p),
          "name" => p.name,
          "strength" => "weak",
          "detail" => "every other voice is somebody else, and #{p.name} is the attendee left"
        }

        Map.put(decided, voice.id, {%{user_id: p.user_id, name: p.name}, "confirm", [item]})

      _ ->
        decided
    end
  end

  # Two voices on the same person were one person, split: the later folds
  # into the first, its lines with it.
  defp merge_split_voices(capture) do
    voices =
      Repo.all(
        from(v in Voice,
          where: v.capture_id == ^capture.id and is_nil(v.merged_into_id),
          order_by: v.id
        )
      )

    voices
    |> Enum.filter(&(&1.user_id || &1.name))
    |> Enum.group_by(&(&1.user_id || &1.name))
    |> Enum.each(fn
      {_, [keep | split]} when split != [] ->
        for v <- split do
          Repo.update_all(from(u in Utterance, where: u.voice_id == ^v.id),
            set: [voice_id: keep.id]
          )

          v |> Ecto.Changeset.change(merged_into_id: keep.id) |> Repo.update!()
        end

        keep
        |> Ecto.Changeset.change(
          evidence:
            keep.evidence ++
              [
                %{
                  "kind" => "merged",
                  "detail" =>
                    "#{Enum.map_join(split, ", ", & &1.label)} merged into this voice: the same person"
                }
              ]
        )
        |> Repo.update!()

      _ ->
        :ok
    end)
  end

  ## Reviewing ----------------------------------------------------------------

  @doc "A voice's person as a reader names them."
  def name(%Voice{name: name, label: label}), do: name || label

  @doc """
  A person decides who a voice is (`%{"user_id" => id}` or `%{"name" =>
  name}`), and every finding that took its owner or decision-maker from that
  voice follows — those, and no others. Recorded as theirs.
  """
  def reassign(%Voice{} = voice, who, %User{} = by) do
    capture = Repo.get!(Capture, voice.capture_id)
    board = Repo.get!(Slipdock.Boards.Board, capture.board_id)
    # Only somebody on the board: a voice's person is who questions about
    # their words are emailed to.
    user =
      with id when is_integer(id) <- who["user_id"],
           %User{} = u <- Repo.get(User, id),
           true <- Slipdock.Access.can_read?(Slipdock.Access.board_permission(u, board)) do
        u
      else
        _ -> nil
      end

    name = (user && (user.name || user.email)) || blank(who["name"])

    cond do
      capture.state in ~w(committed discarded) ->
        {:error, "this capture is #{capture.state}: who spoke can no longer change what it wrote"}

      who["user_id"] != nil and is_nil(user) ->
        {:error, "that person isn't on this board"}

      is_nil(name) ->
        {:error, "say who it is: one of the people offered, or a name"}

      true ->
        Repo.transaction(fn ->
          voice =
            voice
            |> Ecto.Changeset.change(
              user_id: user && user.id,
              name: name,
              confidence: "confirmed",
              confirmed_by_id: by.id,
              confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
              evidence:
                voice.evidence ++
                  [
                    %{
                      "kind" => "confirmed",
                      "detail" => "#{by.name || by.email} said this is #{name}"
                    }
                  ]
            )
            |> Repo.update!()

          changed = rederive(capture, voice, user, name)

          Meetings.record(
            capture,
            "voice",
            "#{voice.label} is #{name}#{if changed > 0, do: " (#{changed} finding#{if changed == 1, do: "", else: "s"} follow)", else: ""}.",
            user: by,
            data: %{"voice_id" => voice.id}
          )

          voice
        end)
        |> tap(fn _ -> Meetings.broadcast(capture) end)
    end
  end

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  # The findings whose owner or decision-maker was this voice.
  defp rederive(capture, voice, user, name) do
    findings =
      Repo.all(from(f in Finding, where: f.capture_id == ^capture.id and f.status == "kept"))

    findings
    |> Enum.map(fn f ->
      effect = f.effect

      effect =
        if effect["owner_voice_id"] == voice.id do
          case effect do
            %{"type" => "card_change", "changes" => changes} = e ->
              Map.put(e, "changes", Map.put(changes, "assignee_id", user && user.id))

            e ->
              e |> Map.put("assignee_id", user && user.id) |> Map.put("assignee", name)
          end
        else
          effect
        end

      effect =
        if effect["decided_by_voice_id"] == voice.id,
          do: Map.put(effect, "decided_by", name),
          else: effect

      if effect != f.effect do
        f |> Ecto.Changeset.change(effect: effect) |> Repo.update!()
        1
      else
        0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  The lines whose speaker is unsure *and* that a finding depends on — the
  only ones worth a person's attention.
  """
  def unsure_lines_that_matter(%Capture{} = capture) do
    Repo.all(
      from(u in Utterance,
        join: e in Slipdock.Meetings.Evidence,
        on: e.utterance_id == u.id,
        join: f in Finding,
        on: f.id == e.finding_id,
        where: u.capture_id == ^capture.id and u.voice_unsure and f.status == "kept",
        distinct: u.id,
        order_by: u.position
      )
    )
  end
end
