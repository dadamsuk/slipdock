defmodule Slipdock.Meetings.Review do
  @moduledoc """
  What a person does to a capture before it is committed: answer its
  questions, include or leave out each finding, edit one, add what the
  transcript missed.

  Every one of these is recorded as theirs (G4): an answer stores who, when,
  through what (`web`, `api`, `agent`) and after what (a replayed span); an
  edit marks the finding *edited by*; an addition is *added by a person*,
  with no evidence. The transcript is never touched.

  An answer that changes a finding (an owner chosen, the existing card
  picked, a reading preferred) keeps the finding as it was in the question's
  `context`, so un-answering puts it back exactly.

  After each change the capture's state follows its questions: `needs_review`
  while a blocking question is open, `ready` when none is. Everything is
  broadcast, so two reviewers see each other's answers as they happen.
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Meetings, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Meetings.{Capture, Finding, Question}

  @open_states ~w(needs_review ready)

  @doc "Whether a capture can still be reviewed (it is read, and not yet committed or discarded)."
  def reviewable?(%Capture{state: state}), do: state in @open_states

  @doc """
  Answers a question with one of its options (by `value`). Options: `:via`
  (`web`, `api`, `agent`), `:context` (a map stored with the answer: what was
  done first, e.g. `%{"replayed" => "07:38–07:44"}`).
  """
  def answer(%Question{} = question, value, %User{} = user, opts \\ []) do
    question = Repo.preload(question, [:capture, :finding], force: true)

    with :ok <- open_capture(question.capture),
         {:ok, option} <- option(question, value) do
      Repo.transaction(fn ->
        before = question.finding && snapshot(question.finding)
        apply_answer(question, option, user)

        question
        |> Ecto.Changeset.change(
          status: "answered",
          answer: Map.take(option, ["value", "label", "effect"]),
          answered_by_id: user.id,
          answered_at: now(),
          via: to_string(opts[:via] || "web"),
          context:
            question.context
            |> Map.merge(Map.new(opts[:context] || %{}, fn {k, v} -> {to_string(k), v} end))
            |> Map.put("finding_before", before)
        )
        |> Repo.update!()
      end)
      |> tap(fn _ ->
        via = opts[:via] || "web"

        Meetings.record(
          question.capture,
          "answered",
          "“#{question.prompt}” — #{option["label"]}#{via_words(via)}#{after_words(opts[:context])}.",
          user: user,
          via: via,
          data: %{"question_id" => question.id, "value" => option["value"]}
        )
      end)
      |> finish(question.capture)
    end
  end

  @doc "Takes an answer back: the question is open again and its finding as it was."
  def unanswer(%Question{} = question, %User{} = user) do
    question = Repo.preload(question, [:capture, :finding], force: true)

    with :ok <- open_capture(question.capture) do
      Repo.transaction(fn ->
        if before = question.finding && question.context["finding_before"] do
          question.finding |> Ecto.Changeset.change(restore(before)) |> Repo.update!()
        end

        question
        |> Ecto.Changeset.change(
          status: "open",
          answer: nil,
          answered_by_id: nil,
          answered_at: nil,
          via: nil,
          context: Map.delete(question.context, "finding_before")
        )
        |> Repo.update!()
      end)
      |> tap(fn _ ->
        Meetings.record(
          question.capture,
          "unanswered",
          "Took back the answer to “#{question.prompt}”.", user: user)
      end)
      |> finish(question.capture)
    end
  end

  @doc "Includes a finding in the commit, or leaves it out."
  def include(%Finding{} = finding, included?, %User{} = user) do
    capture = Repo.get!(Capture, finding.capture_id)

    with :ok <- open_capture(capture),
         :ok <- kept(finding) do
      finding
      |> Ecto.Changeset.change(included: included?)
      |> Repo.update()
      |> tap(fn _ ->
        Meetings.record(
          capture,
          "included",
          "#{if included?, do: "Included", else: "Left out"} “#{finding.title}”.",
          user: user
        )
      end)
      |> finish(capture)
    end
  end

  @doc """
  Edits what a finding says or does (`title`, `body`, and the effect's
  assignee, due date, list or topic) — never its evidence. Marks it edited by
  the person.
  """
  def edit(%Finding{} = finding, attrs, %User{} = user) do
    capture = Repo.get!(Capture, finding.capture_id)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- open_capture(capture),
         :ok <- kept(finding) do
      effect =
        finding.effect
        |> Map.merge(
          Map.take(attrs, ~w(due_date list topic))
          |> Map.reject(fn {_, v} -> v in [nil, ""] end)
        )
        |> then(fn e ->
          case attrs["title"] do
            t when is_binary(t) and t != "" ->
              if Map.has_key?(e, "title"), do: Map.put(e, "title", t), else: e

            _ ->
              e
          end
        end)
        |> then(fn e ->
          if e["type"] == "decision_entry" and attrs["topic"] not in [nil, ""],
            do: Map.put(e, "page", "Decisions / #{String.trim(attrs["topic"])}"),
            else: e
        end)
        |> then(fn e ->
          if e["type"] == "decision_entry" and is_binary(attrs["title"]),
            do: Map.put(e, "text", attrs["title"]),
            else: e
        end)

      finding
      |> Finding.edit_changeset(Map.take(attrs, ~w(title body)) |> Map.put("effect", effect))
      |> Ecto.Changeset.put_change(:edited_by_id, user.id)
      |> Ecto.Changeset.put_change(:edited_at, now())
      |> Repo.update()
      |> tap(fn
        {:ok, f} -> Meetings.record(capture, "edited", "Edited “#{f.title}”.", user: user)
        _ -> :ok
      end)
      |> finish(capture)
    end
  end

  @doc """
  Adds something the transcript missed: a finding with no evidence, marked
  as added by a person. `attrs`: `kind`, `title`, `body`, and for an action
  `list`, `assignee_id`, `due_date`; for a decision `topic`.
  """
  def add(%Capture{} = capture, attrs, %User{} = user) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- open_capture(capture) do
      kind = attrs["kind"] || "action"
      title = String.trim(attrs["title"] || "")

      effect =
        case kind do
          "decision" ->
            topic = blank(attrs["topic"]) || "General"

            %{
              "type" => "decision_entry",
              "topic" => topic,
              "page" => "Decisions / #{topic}",
              "text" => title
            }

          _ ->
            %{
              "type" => "new_card",
              "title" => title,
              "description" => blank(attrs["body"]),
              "list" => blank(attrs["list"]),
              "assignee_id" => int(attrs["assignee_id"]),
              "due_date" => blank(attrs["due_date"])
            }
            |> Map.reject(fn {_, v} -> is_nil(v) end)
        end

      position =
        (Repo.one(from(f in Finding, where: f.capture_id == ^capture.id, select: max(f.position))) ||
           0) + 1

      %Finding{capture_id: capture.id, origin: "person", added_by_id: user.id, position: position}
      |> Finding.changeset(%{
        kind: kind,
        title: title,
        body: blank(attrs["body"]),
        effect: effect,
        signals: ["added_by_person"],
        included: true
      })
      |> Repo.insert()
      |> tap(fn
        {:ok, f} ->
          Meetings.record(capture, "added", "Added “#{f.title}”, which the transcript missed.",
            user: user
          )

        _ ->
          :ok
      end)
      |> finish(capture)
    end
  end

  @doc """
  Moves the capture between `needs_review` and `ready` to follow its open
  blocking questions.
  """
  def refresh_state(%Capture{} = capture) do
    capture = Repo.get!(Capture, capture.id)
    open = length(Meetings.open_questions(capture))

    cond do
      capture.state == "needs_review" and open == 0 ->
        Meetings.transition(capture, "ready", message: "Nothing left to settle. Ready to commit.")

      capture.state == "ready" and open > 0 ->
        Meetings.transition(capture, "needs_review", message: "A question is open again.")

      true ->
        {:ok, capture}
    end
  end

  ## Answers ------------------------------------------------------------------

  defp option(%Question{options: options}, value) do
    case Enum.find(options, &(&1["value"] == value)) do
      nil -> {:error, "that is not one of the answers to this question"}
      option -> {:ok, option}
    end
  end

  # What an answer does to the finding it is about.
  defp apply_answer(%Question{finding: nil}, _option, _user), do: :ok

  defp apply_answer(
         %Question{kind: "which_reading", finding: f},
         %{"finding" => raw} = option,
         _user
       )
       when is_map(raw) do
    _ = option
    effect = f.effect

    effect =
      cond do
        raw["due_date"] && effect["type"] == "new_card" ->
          Map.put(effect, "due_date", raw["due_date"])

        true ->
          effect
      end
      |> then(fn e ->
        if e["type"] == "new_card", do: Map.put(e, "title", raw["title"]), else: e
      end)
      |> then(fn e ->
        if e["type"] == "decision_entry", do: Map.put(e, "text", raw["title"]), else: e
      end)

    f
    |> Ecto.Changeset.change(title: String.slice(raw["title"], 0, 255), effect: effect)
    |> Repo.update!()
  end

  defp apply_answer(%Question{kind: "which_reading"}, %{"value" => "none"}, _user), do: :ok

  defp apply_answer(%Question{kind: kind, finding: f}, %{"value" => "user:" <> id}, _user)
       when kind in ["who_is_meant", "who_said_it"] do
    user = Repo.get(User, String.to_integer(id))

    effect =
      case f.effect do
        %{"type" => "decision_entry"} = e ->
          Map.put(e, "decided_by", user && (user.name || user.email))

        %{"type" => "card_change", "changes" => changes} = e ->
          Map.put(e, "changes", Map.put(changes, "assignee_id", user && user.id))

        e ->
          e
          |> Map.put("assignee_id", user && user.id)
          |> Map.put("assignee", user && (user.name || user.email))
      end

    f
    |> Ecto.Changeset.change(effect: effect, signals: Enum.uniq(f.signals -- ["owner_unknown"]))
    |> Repo.update!()
  end

  defp apply_answer(%Question{kind: kind, finding: f}, %{"value" => "name:" <> name}, _user)
       when kind in ["who_is_meant", "who_said_it"] do
    effect =
      case f.effect do
        %{"type" => "decision_entry"} = e -> Map.put(e, "decided_by", name)
        e -> e
      end

    f |> Ecto.Changeset.change(effect: effect) |> Repo.update!()
  end

  defp apply_answer(%Question{kind: kind, finding: f}, %{"value" => "none"}, _user)
       when kind in ["who_is_meant", "who_said_it"] do
    effect = f.effect |> Map.delete("assignee_id") |> Map.delete("assignee")
    f |> Ecto.Changeset.change(effect: effect) |> Repo.update!()
  end

  defp apply_answer(
         %Question{kind: "existing_or_new", finding: f},
         %{"value" => "card:" <> id},
         _user
       ) do
    card = Repo.get(Slipdock.Boards.Card, String.to_integer(id))

    changes =
      [{"due_date", f.effect["due_date"]}, {"assignee_id", f.effect["assignee_id"]}]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    effect = %{
      "type" => "card_change",
      "card_id" => card && card.id,
      "ref" => card && "##{card.id}",
      "card_title" => card && card.title,
      "changes" => Map.merge(f.effect["changes"] || %{}, changes),
      "comment" => f.effect["comment"] || f.title
    }

    link = %{
      "type" => "card",
      "id" => card && card.id,
      "ref" => card && "##{card.id}",
      "title" => card && card.title,
      "board_id" => card && card.board_id,
      "version" => card && Slipdock.Meetings.Version.of(card),
      "strength" => "person"
    }

    f
    |> Ecto.Changeset.change(kind: "card_change", effect: effect, links: [link], included: true)
    |> Repo.update!()
  end

  defp apply_answer(%Question{kind: "existing_or_new", finding: f}, %{"value" => "new"}, _user) do
    effect =
      if f.effect["type"] == "new_card",
        do: f.effect,
        else: %{"type" => "new_card", "title" => f.title, "description" => f.body}

    f
    |> Ecto.Changeset.change(
      kind: if(f.kind == "card_change", do: "action", else: f.kind),
      effect: effect,
      links: [],
      included: true
    )
    |> Repo.update!()
  end

  defp apply_answer(%Question{kind: "existing_or_new", finding: f}, %{"value" => "none"}, _user) do
    f |> Ecto.Changeset.change(included: false) |> Repo.update!()
  end

  defp apply_answer(_question, _option, _user), do: :ok

  # The parts of a finding an answer may change, to put back on un-answer.
  defp snapshot(%Finding{} = f) do
    %{
      "kind" => f.kind,
      "title" => f.title,
      "effect" => f.effect,
      "links" => f.links,
      "included" => f.included,
      "signals" => f.signals
    }
  end

  defp restore(before) do
    [
      kind: before["kind"],
      title: before["title"],
      effect: before["effect"],
      links: before["links"],
      included: before["included"],
      signals: before["signals"]
    ]
  end

  ## Helpers ------------------------------------------------------------------

  defp open_capture(%Capture{} = capture) do
    if reviewable?(capture),
      do: :ok,
      else: {:error, "this capture is #{capture.state}: there is nothing left to review"}
  end

  defp kept(%Finding{status: "kept"}), do: :ok
  defp kept(_), do: {:error, "a dropped finding cannot be included or edited"}

  # After any change: the state follows the questions, and everyone watching
  # hears about it.
  defp finish({:ok, result}, capture) do
    {:ok, _} = refresh_state(capture)
    Meetings.broadcast(Repo.get!(Capture, capture.id))
    {:ok, result}
  end

  defp finish({:error, %Ecto.Changeset{}} = error, _capture), do: error
  defp finish({:error, _} = error, _capture), do: error

  defp via_words("agent"), do: " (via agent)"
  defp via_words(:agent), do: " (via agent)"
  defp via_words(_), do: ""

  defp after_words(nil), do: ""

  defp after_words(context) do
    case Map.new(context, fn {k, v} -> {to_string(k), v} end) do
      %{"replayed" => span} -> ", after replaying #{span}"
      _ -> ""
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp blank(nil), do: nil
  defp blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp blank(s), do: s

  defp int(nil), do: nil
  defp int(""), do: nil
  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
