defmodule Slipdock.Boards.Wait do
  @moduledoc """
  Waiting on a person (#1114): what a card needs, who it waits on (a person,
  or anyone when `on_user_id` is nil), since when, and optionally a short
  list of answers to pick from. A card has at most one open wait.

      open → answered | skipped | withdrawn | card_completed | archived

  A wait asks one thing (`needs`) or a numbered series of `questions`
  (#1220), answered one by one in `answers` (same order, "" for one left
  blank). `needs` is then the line in front of them: the words before the
  list, or "N questions: the first…" when there were none. A `needs`
  written as a numbered list (`1. …` `2. …`) is split into questions as it
  is opened, so an agent that asks in one block still asks a series.
  Skipping (`skipped`) closes it unanswered and moves the card on as an
  answer would.

  Unlike a handoff a wait has a lifecycle: it is opened, then closed once,
  by a conditional update on `closed_at IS NULL`, so of two answers racing
  one wins and the other is told who beat it. While it is open the card is
  flagged `waiting`; `set_flag` says whether the wait put the flag there,
  and so whether closing it takes the flag off again.

  Who opened it is kept as `Slipdock.Actor` has it (`kind`, `via`, `agent`
  label), with the runner job it was asked from when there is one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @reasons ~w(answered skipped withdrawn card_completed archived)
  @requeue_states ~w(none queued pending failed skipped)
  @max_choices 10
  @max_questions 20

  schema "card_waits" do
    field :needs, :string
    field :choices, {:array, :string}, default: []
    field :questions, {:array, :string}, default: []
    field :answers, {:array, :string}, default: []
    field :kind, :string
    field :via, :string
    field :agent, :string
    field :set_flag, :boolean, default: false
    field :closed_at, :utc_datetime
    field :close_reason, :string
    field :answer, :string
    field :choice, :integer
    field :requeue_state, :string, default: "none"
    field :requeue_note, :string

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :on_user, Slipdock.Accounts.User
    belongs_to :opened_by, Slipdock.Accounts.User
    belongs_to :closed_by, Slipdock.Accounts.User
    belongs_to :job, Slipdock.Runners.Job
    # The fresh job the answer started (#1115).
    belongs_to :requeue_job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def close_reasons, do: @reasons
  def requeue_states, do: @requeue_states
  def max_questions, do: @max_questions

  def changeset(wait, attrs) do
    wait
    |> cast(attrs, [:needs, :choices, :questions, :on_user_id, :job_id])
    |> update_change(:needs, &String.trim/1)
    |> update_change(:choices, &clean_choices/1)
    |> update_change(:questions, &clean_choices/1)
    |> put_questions()
    |> validate_required([:needs], message: "can't be blank: say what you need")
    |> validate_length(:needs, max: 1000)
    |> validate_length(:choices, max: @max_choices, message: "at most %{count}")
    |> validate_change(:choices, fn :choices, choices ->
      if Enum.any?(choices, &(String.length(&1) > 100)),
        do: [choices: "must each be at most 100 characters"],
        else: []
    end)
    |> validate_length(:questions, max: @max_questions, message: "at most %{count}")
    |> validate_change(:questions, fn :questions, questions ->
      if Enum.any?(questions, &(String.length(&1) > 1000)),
        do: [questions: "must each be at most 1000 characters"],
        else: []
    end)
    |> unique_constraint(:card_id,
      name: :card_waits_one_open,
      message: "already has an open wait"
    )
  end

  # Questions given: `needs` is what was said in front of them, or made up
  # from them. None given: a numbered `needs` is split into them.
  defp put_questions(changeset) do
    needs = get_field(changeset, :needs)

    case get_field(changeset, :questions) || [] do
      [] ->
        case split_questions(needs) do
          {intro, [_, _ | _] = questions} ->
            changeset
            |> put_change(:questions, questions)
            |> put_change(:needs, intro || summary(questions))

          _ ->
            changeset
        end

      questions when needs in [nil, ""] ->
        put_change(changeset, :needs, summary(questions))

      _ ->
        changeset
    end
  end

  defp summary([one]), do: String.slice(one, 0, 1000)

  defp summary([first | _] = questions),
    do: String.slice("#{length(questions)} questions: #{first}", 0, 1000)

  @doc ~S"""
  Splits text written as a numbered list into `{intro, questions}`: the
  lines before `1.` (nil when none), then each item with the lines that
  follow it. Only a list of two or more counting up from 1 is split;
  anything else answers `{nil, []}`.

      iex> Slipdock.Boards.Wait.split_questions("Two things:\n1. Which region?\n2) How many seats?")
      {"Two things:", ["Which region?", "How many seats?"]}
  """
  def split_questions(text) when is_binary(text) do
    {intro, items} =
      text
      |> String.split(~r/\R/)
      |> Enum.reduce({[], []}, fn line, {intro, items} ->
        case {numbered(line), items} do
          {{n, rest}, _} when n == length(items) + 1 -> {intro, [[rest] | items]}
          {_, []} -> {[line | intro], items}
          {_, [current | done]} -> {intro, [[line | current] | done]}
        end
      end)

    questions = items |> Enum.reverse() |> Enum.map(&join_lines/1)
    intro = join_lines(intro)

    if length(questions) >= 2 and Enum.all?(questions, &(&1 != "")),
      do: {if(intro == "", do: nil, else: intro), questions},
      else: {nil, []}
  end

  def split_questions(_), do: {nil, []}

  defp numbered(line) do
    case Regex.run(~r/^\s*(\d{1,2})[.)]\s+(.*)$/, line) do
      [_, n, rest] -> {String.to_integer(n), rest}
      _ -> nil
    end
  end

  defp join_lines(reversed), do: reversed |> Enum.reverse() |> Enum.join("\n") |> String.trim()

  @doc "What the wait asks, as a list: its questions, or `needs` as the one."
  def questions(%__MODULE__{questions: [_ | _] = qs}), do: qs
  def questions(%__MODULE__{needs: needs}), do: [needs]

  @doc "Whether the wait asks a numbered series rather than one thing."
  def series?(%__MODULE__{questions: [_ | _]}), do: true
  def series?(_), do: false

  @doc """
  What the answer said, as Markdown: for a series each question numbered
  with its answer under it, then any choice or answer given for the whole;
  for one question, the choice and the answer. "" when nothing was said.
  """
  def answered_text(%__MODULE__{} = w) do
    whole =
      [choice_text(w, w.choice), w.answer]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" — ")

    if series?(w) do
      pairs =
        w.questions
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {q, i} ->
          a = Enum.at(w.answers || [], i)
          "#{i + 1}. #{q}\n   → #{if a in [nil, ""], do: "(not answered)", else: a}"
        end)

      if whole == "", do: pairs, else: pairs <> "\n\n" <> whole
    else
      whole
    end
  end

  @doc "Whether the wait is still open."
  def open?(%__MODULE__{closed_at: nil}), do: true
  def open?(_), do: false

  @doc "The text of choice `n` (counted from 1), or nil."
  def choice_text(%__MODULE__{choices: choices}, n) when is_integer(n) and n > 0,
    do: Enum.at(choices, n - 1)

  def choice_text(_, _), do: nil

  @doc "Who it waits on, in words: their name, or anyone."
  def on_name(%__MODULE__{on_user: %Slipdock.Accounts.User{} = u}),
    do: Slipdock.Accounts.User.display_name(u)

  def on_name(_), do: "anyone"

  defp clean_choices(choices) do
    choices
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
  end
end
