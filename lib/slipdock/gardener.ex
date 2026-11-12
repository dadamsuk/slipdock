defmodule Slipdock.Gardener do
  @moduledoc """
  The board gardener (W-1807): it looks a board over for rot — epics done
  but never closed, cards stuck in progress, duplicates, orphaned pages,
  mistyped links — and proposes a fix for each. Nothing changes until a
  person applies a suggestion; one they dismiss stays dismissed.

  A run (`run/2`) goes over the board and every board beneath it with each
  check that is on (see `Slipdock.Gardener.Check`, `checks/0`), and keeps
  what it finds as suggestions. Each carries a fingerprint — the check, the
  subjects and the state that made it a finding — so a later run neither
  repeats an open suggestion nor brings back one that was dismissed or
  applied; when the subject changes, the fingerprint does, and it may be
  suggested afresh. An open suggestion a later run no longer finds expires.

  `apply/3` takes a suggestion's steps through the ordinary functions (see
  `Slipdock.Gardener.Steps`) and records how to undo them; `undo/2` does,
  unless something has moved on since; `dismiss/2` remembers the no.

  **Proposals** (#1788). An agent can't change the handbook's rules on its
  own say; it files a proposal instead (`propose/4`): an open suggestion of
  the check `"proposal"`, made of the steps in `proposal_ops/0`, with an
  explanation and its evidence (findings, cards). Runs never expire one.
  A proposal, and any suggestion that edits a section, is a person's to
  decide: `person_only?/1`, which `apply/3`, `dismiss/3` and `undo/3`
  settle only for a person on the Tidy-up page (`actor:` the web actor,
  `in_person?/1`) and refuse to every API token (#2668).
  """

  import Ecto.Query

  alias Slipdock.Access
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Gardener.{Context, Run, Settings, Steps, Suggestion}
  alias Slipdock.Repo

  @checks [
    Slipdock.Gardener.Checks.EpicDone,
    Slipdock.Gardener.Checks.DoneNotCompleted,
    Slipdock.Gardener.Checks.CompletedNotDone,
    Slipdock.Gardener.Checks.StaleInProgress,
    Slipdock.Gardener.Checks.NoNextAction,
    Slipdock.Gardener.Checks.LongOverdue,
    Slipdock.Gardener.Checks.AbandonedBacklog,
    Slipdock.Gardener.Checks.DuplicateCards,
    Slipdock.Gardener.Checks.OrphanPages,
    Slipdock.Gardener.Checks.BrokenLinks,
    Slipdock.Gardener.Checks.HandbookGap,
    Slipdock.Gardener.Checks.LongSection,
    Slipdock.Gardener.Checks.BroadCovers,
    Slipdock.Gardener.Checks.RuleWithoutCheck,
    Slipdock.Gardener.Checks.StaleDecision,
    Slipdock.Gardener.Checks.RuleChanged
  ]

  @doc "Every check, in the order the Tidy-up page shows them."
  def checks, do: @checks

  @doc "The check with that key, or nil."
  def check(key), do: Enum.find(checks(), &(&1.key() == key))

  @doc "The keys of every check."
  def check_keys, do: Enum.map(checks(), & &1.key())

  @proposal "proposal"
  @proposal_ops ~w(edit_section comment file_page)

  @doc "The check key proposals are filed under."
  def proposal_check, do: @proposal

  @doc "The steps a proposal may take."
  def proposal_ops, do: @proposal_ops

  @doc "Every key a suggestion can carry: the checks', then `\"proposal\"`."
  def suggestion_keys, do: check_keys() ++ [@proposal]

  @doc "A suggestion key's human name."
  def label(@proposal), do: "Proposed edits"

  def label(key) do
    case check(key) do
      nil -> key
      check -> check.label()
    end
  end

  @doc """
  Looks `board` over and keeps what it finds. Options:

    * `:trigger` – `"manual"` (the default), `"schedule"` or `"mcp"`
    * `:user` – who asked for it, if anybody
    * `:only` – check keys to run (default: every check that is on)
    * `:checks` – the check modules to choose from (default `checks/0`)
    * `:now`

  `{:ok, run}`, its `counts` saying how many open suggestions there are in
  all (`"total"`), how many are new this run (`"new"`), and per check.
  """
  def run(%Board{} = board, opts \\ []) do
    now = (opts[:now] || DateTime.utc_now()) |> DateTime.truncate(:second)
    trigger = opts[:trigger] || "manual"
    board = Repo.get!(Board, board.id)

    checks =
      (opts[:checks] || checks())
      |> Enum.filter(&(is_nil(opts[:only]) or Enum.member?(List.wrap(opts[:only]), &1.key())))
      |> Enum.filter(&Settings.enabled?(board, &1))

    {:ok, run} =
      %Run{
        board_id: board.id,
        user_id: opts[:user] && opts[:user].id,
        trigger: trigger,
        started_at: now
      }
      |> Repo.insert()

    ctx = Context.new(board, now)

    findings =
      for check <- checks,
          finding <- check.find(ctx, Settings.for(board, check)),
          do: {check.key(), finding}

    found = Map.new(findings, fn {key, f} -> {fingerprint(key, f), {key, f}} end)
    known = known_states(board.id, Map.keys(found))

    new =
      for {fp, {key, f}} <- found,
          not Enum.member?(~w(open dismissed applied), Map.get(known, fp)) do
        Repo.insert!(%Suggestion{
          run_id: run.id,
          board_id: board.id,
          check: key,
          subject: f.subject,
          fingerprint: fp,
          proposal: f.proposal,
          alternatives: Map.get(f, :alternatives, %{}),
          explanation: f.explanation,
          state: "open"
        })
      end

    expire_missing(board.id, Enum.map(checks, & &1.key()), Map.keys(found), now)

    open = list_open(board)

    counts =
      open
      |> Enum.frequencies_by(& &1.check)
      |> Map.merge(%{"total" => length(open), "new" => length(new)})

    run
    |> Ecto.Changeset.change(finished_at: DateTime.utc_now(:second), counts: counts)
    |> Repo.update()
    |> tap_ok(&broadcast/1)
  end

  # fingerprint => the state of the newest suggestion with it.
  defp known_states(_board_id, []), do: %{}

  defp known_states(board_id, fps) do
    from(s in Suggestion,
      where: s.board_id == ^board_id and s.fingerprint in ^fps,
      order_by: [asc: s.id],
      select: {s.fingerprint, s.state}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp expire_missing(board_id, keys, found, now) do
    from(s in Suggestion,
      where: s.board_id == ^board_id and s.state == "open" and s.check in ^keys,
      where: s.fingerprint not in ^found
    )
    |> Repo.update_all(set: [state: "expired", updated_at: now])
  end

  @doc """
  The fingerprint of a finding of the check `key`: the check, its subjects
  and the state that made it one.
  """
  def fingerprint(key, %{subject: subject, state: state}) do
    cards = subject |> Map.get("cards", []) |> Enum.sort()
    pages = subject |> Map.get("pages", []) |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({key, cards, pages, state}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc "The board's open suggestions, grouped by check in `checks/0` order. `check:` narrows to one."
  def list_open(%Board{id: board_id}, opts \\ []) do
    order = checks() |> Enum.with_index() |> Map.new(fn {c, i} -> {c.key(), i} end)

    from(s in Suggestion, where: s.board_id == ^board_id and s.state == "open", order_by: s.id)
    |> then(fn q -> if opts[:check], do: where(q, [s], s.check == ^opts[:check]), else: q end)
    |> Repo.all()
    |> Enum.sort_by(&{Map.get(order, &1.check, 999), &1.id})
  end

  @doc "How many open suggestions `board` has."
  def open_count(%Board{id: board_id}) do
    Repo.aggregate(
      from(s in Suggestion, where: s.board_id == ^board_id and s.state == "open"),
      :count
    )
  end

  @doc "The board's suggestions applied most recently, newest first: what can still be undone."
  def list_applied(%Board{id: board_id}, limit \\ 20) do
    from(s in Suggestion,
      where: s.board_id == ^board_id and s.state == "applied",
      order_by: [desc: s.decided_at, desc: s.id],
      limit: ^limit,
      preload: [:decided_by]
    )
    |> Repo.all()
  end

  @doc "The suggestion with that id, or nil."
  def get_suggestion(id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> Repo.get(Suggestion, n)
      _ -> nil
    end
  end

  @doc "The latest run on `board`, or nil."
  def last_run(%Board{id: board_id}) do
    from(r in Run, where: r.board_id == ^board_id, order_by: [desc: r.id], limit: 1)
    |> Repo.one()
  end

  @doc """
  Applies `suggestion` as `user`. Options: `:choice` takes one of its
  `alternatives` instead of the proposal; `:keep` is the card that stays,
  when a step asks the person to pick (a duplicate).

  `actor:` is who is asking (a `Slipdock.Actor`): a suggestion that is
  `person_only?/1` is refused to any but `in_person?/1`'s, and to none.

  `{:ok, suggestion}`, or `{:error, reason}`: `:forbidden` without write
  access to the board and everything the steps touch, or a sentence.
  """
  def apply(%Suggestion{} = suggestion, user, opts \\ []) do
    with :ok <- open(suggestion),
         :ok <- a_persons(suggestion, opts[:actor], "apply"),
         :ok <- can_write(user, suggestion),
         {:ok, steps} <- chosen_steps(suggestion, opts[:choice]),
         {:ok, steps} <- Steps.resolve_picks(steps, opts[:keep]),
         :ok <- Steps.authorize(steps, user),
         {:ok, inverse} <- Steps.apply_all(steps, user) do
      log(suggestion, "via gardener: #{suggestion.explanation}")

      suggestion
      |> Ecto.Changeset.change(
        state: "applied",
        decided_by_id: user.id,
        decided_at: DateTime.utc_now(:second),
        undo: %{"steps" => inverse, "applied" => steps}
      )
      |> Repo.update()
      |> tap_ok(&broadcast/1)
      |> tap_ok(&Slipdock.Findings.Promote.decided(&1, :applied))
    end
  end

  @doc """
  Dismisses `suggestion` as `user`: it is not suggested again while its
  subject stays as it is. `actor:` as `apply/3`.
  """
  def dismiss(%Suggestion{} = suggestion, user, opts \\ []) do
    with :ok <- open(suggestion),
         :ok <- a_persons(suggestion, opts[:actor], "dismiss"),
         :ok <- can_write(user, suggestion) do
      suggestion
      |> Ecto.Changeset.change(
        state: "dismissed",
        decided_by_id: user.id,
        decided_at: DateTime.utc_now(:second)
      )
      |> Repo.update()
      |> tap_ok(&broadcast/1)
      |> tap_ok(&Slipdock.Findings.Promote.decided(&1, :dismissed))
    end
  end

  @doc """
  Undoes an applied `suggestion` as `user`, step by step in reverse, and
  makes it open again. Refused, with nothing changed, when something it
  undoes has moved on since (`{:error, "card #12 … has been reopened since"}`).
  """
  def undo(suggestion, user, opts \\ [])

  def undo(%Suggestion{state: "applied"} = suggestion, user, opts) do
    inverse = (suggestion.undo || %{})["steps"] || []

    with :ok <- a_persons(suggestion, opts[:actor], "undo"),
         :ok <- can_write(user, suggestion),
         :ok <- Steps.authorize(inverse, user),
         :ok <- Steps.undo_all(inverse, user) do
      log(suggestion, "undone via gardener: #{suggestion.explanation}")

      suggestion
      |> Ecto.Changeset.change(state: "open", decided_by_id: nil, decided_at: nil, undo: nil)
      |> Repo.update()
      |> tap_ok(&broadcast/1)
      |> tap_ok(&Slipdock.Findings.Promote.decided(&1, :undone))
    end
  end

  def undo(%Suggestion{}, _user, _opts),
    do: {:error, "only an applied suggestion can be undone"}

  @doc """
  Closes an open `suggestion` with nobody deciding, saying why in `note`
  (#2129): a proposal drafted from a finding that triage has since decided
  (`Slipdock.Findings.Promote.settled/2`). It is dismissed, so its
  fingerprint is remembered, nothing it proposes is applied, and each card
  it is about logs the note. `reopen_closed/1` takes it back.
  """
  def close(%Suggestion{state: "open"} = suggestion, note) when is_binary(note) do
    log(suggestion, "proposal ##{suggestion.id} closed: #{note}")

    suggestion
    |> Ecto.Changeset.change(
      state: "dismissed",
      note: note,
      decided_by_id: nil,
      decided_at: DateTime.utc_now(:second)
    )
    |> Repo.update()
    |> tap_ok(&broadcast/1)
  end

  def close(%Suggestion{}, _note), do: {:error, "only an open suggestion can be closed"}

  @doc """
  Opens again a suggestion `close/2` closed; one a person dismissed is
  refused.
  """
  def reopen_closed(%Suggestion{state: "dismissed", decided_by_id: nil, note: note} = suggestion)
      when is_binary(note) do
    log(suggestion, "proposal ##{suggestion.id} reopened (was closed: #{note})")

    suggestion
    |> Ecto.Changeset.change(state: "open", note: nil, decided_at: nil)
    |> Repo.update()
    |> tap_ok(&broadcast/1)
  end

  def reopen_closed(%Suggestion{}), do: {:error, "only a suggestion the server closed reopens"}

  @doc "Applies or dismisses, by name: `decide(s, user, \"apply\" | \"dismiss\", opts)`."
  def decide(suggestion, user, decision, opts \\ [])
  def decide(s, user, "apply", opts), do: __MODULE__.apply(s, user, opts)
  def decide(s, user, "dismiss", opts), do: dismiss(s, user, opts)
  def decide(_s, _user, _other, _opts), do: {:error, "decision must be apply or dismiss"}

  @doc """
  Whether only a person may decide `suggestion`: a proposal, or one with a
  step that edits a page's section (the handbook's rules among them).
  """
  def person_only?(%Suggestion{check: @proposal}), do: true

  def person_only?(%Suggestion{proposal: steps, alternatives: alts}) do
    Enum.any?([steps | Map.values(alts || %{})], fn steps ->
      Enum.any?(steps || [], &(&1["op"] == "edit_section"))
    end)
  end

  @doc """
  Whether `actor` is a person deciding in the web app: the signed-in,
  CSRF-guarded Tidy-up page, which passes `Slipdock.Actor.web/1`. Only such
  a decision settles a `person_only?/1` suggestion (W-1945 §Permissions).
  A request with an API token never is.
  """
  def in_person?(%{kind: "human", via: "web"}), do: true
  def in_person?(_actor), do: false

  defp a_persons(suggestion, actor, what) do
    if person_only?(suggestion) and not in_person?(actor),
      do:
        {:error,
         "only a person can #{what} a proposed handbook edit, signed in on the board's " <>
           "Tidy-up page: #{tidy_url(suggestion)} (no API token can)"},
      else: :ok
  end

  @doc "The Tidy-up page of the board `suggestion` is on."
  def tidy_url(%Suggestion{board_id: board_id}),
    do: "#{Slipdock.Automations.Runner.base_url()}/boards/#{board_id}/tidy"

  ## Proposals --------------------------------------------------------------------

  @doc """
  Files a proposal on `board` (its root's suggestions: where the handbook
  is) as `user`, who needs write access to it and to everything its steps
  touch. `attrs` (string keys):

    * `"explanation"` – what it changes and why, required
    * `"steps"` – one or more, of `proposal_ops/0`. An `edit_section`
      names its page by id or code (`W-12`); its `base` (see
      `Slipdock.Gardener.Steps`) is filled in from the section as it is now
      when not given, and refused when given and already stale.
    * `"findings"`, `"cards"` – ids of the evidence

  `{:ok, suggestion, :new}`; `{:ok, suggestion, :exists}` when the same
  proposal is open, applied or dismissed already (a dismissal is
  remembered); or `{:error, :forbidden}` / `{:error, sentence}`.

  `round:` (an option) is part of what makes it the same proposal: the
  server's promotion of a finding (`Slipdock.Findings.Promote`) passes the
  finding and its count, so a draft dismissed once can be filed again when
  the finding has been seen more since.
  """
  def propose(%Board{} = board, user, attrs, opts \\ []) do
    board = Slipdock.Handbook.root(board)

    attrs = Map.new(attrs || %{}, fn {k, v} -> {to_string(k), v} end)

    with {:ok, explanation} <- explanation(attrs["explanation"]),
         {:ok, steps} <- proposal_steps(attrs["steps"]),
         :ok <- can_write(user, %Suggestion{board_id: board.id}),
         :ok <- Steps.authorize(steps, user),
         {:ok, findings} <- ids(attrs["findings"], "findings"),
         {:ok, cards} <- ids(attrs["cards"], "cards") do
      pages = steps |> Enum.map(& &1["page"]) |> Enum.filter(&is_integer/1) |> Enum.uniq()
      step_cards = steps |> Steps.touched_card_ids() |> Enum.uniq()
      subject = %{"cards" => Enum.uniq(step_cards ++ cards), "pages" => pages}
      subject = if findings == [], do: subject, else: Map.put(subject, "findings", findings)
      state = if opts[:round], do: {steps, opts[:round]}, else: steps
      fp = fingerprint(@proposal, %{subject: subject, state: state})

      case filed(board.id, fp) do
        %Suggestion{} = existing -> {:ok, existing, :exists}
        nil -> insert_proposal(board, subject, fp, steps, explanation)
      end
    end
  end

  # The newest proposal with that fingerprint a person hasn't let lapse.
  defp filed(board_id, fp) do
    from(s in Suggestion,
      where: s.board_id == ^board_id and s.fingerprint == ^fp,
      where: s.state in ~w(open applied dismissed),
      order_by: [desc: s.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp insert_proposal(board, subject, fp, steps, explanation) do
    %Suggestion{
      board_id: board.id,
      check: @proposal,
      subject: subject,
      fingerprint: fp,
      proposal: steps,
      alternatives: %{},
      explanation: explanation,
      state: "open"
    }
    |> Repo.insert()
    |> tap_ok(&broadcast/1)
    |> case do
      {:ok, s} -> {:ok, s, :new}
      error -> error
    end
  end

  defp explanation(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "explanation is required: what the proposal changes, and why"}
      text -> {:ok, text}
    end
  end

  defp explanation(_), do: {:error, "explanation is required: what the proposal changes, and why"}

  defp ids(nil, _what), do: {:ok, []}

  defp ids(list, what) when is_list(list) do
    parsed =
      Enum.map(list, fn
        id when is_integer(id) and id > 0 -> id
        id when is_binary(id) -> id |> String.trim_leading("#") |> Integer.parse() |> int()
        _ -> nil
      end)

    if Enum.all?(parsed, &is_integer/1),
      do: {:ok, Enum.uniq(parsed)},
      else: {:error, "#{what} are ids, like [12, 14]"}
  end

  defp ids(_, what), do: {:error, "#{what} are ids, like [12, 14]"}

  defp int({n, ""}) when n > 0, do: n
  defp int(_), do: nil

  defp proposal_steps(steps) when is_list(steps) and steps != [] do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, i}, {:ok, acc} ->
      case proposal_step(step) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, message} -> {:halt, {:error, "steps[#{i}]: #{message}"}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  defp proposal_steps(_),
    do: {:error, "steps is required: a list of #{Enum.join(@proposal_ops, ", ")} steps"}

  defp proposal_step(%{"op" => op} = step) when op in @proposal_ops do
    with {:ok, step} <- step_page(step, op) do
      shape(op, step)
    end
  end

  defp proposal_step(%{"op" => op}) when is_binary(op),
    do: {:error, "a proposal can't take a “#{op}” step: only #{Enum.join(@proposal_ops, ", ")}"}

  defp proposal_step(_), do: {:error, "a step is an object with an op"}

  defp step_page(%{"page" => ref} = step, _op) when not is_nil(ref) do
    case Slipdock.Wiki.find_page(if(is_integer(ref), do: ref, else: to_string(ref))) do
      {:ok, page} -> {:ok, Map.put(step, "page", page.id)}
      _ -> {:error, "no page #{inspect(ref)}"}
    end
  end

  defp step_page(_step, op) when op in ~w(edit_section file_page),
    do: {:error, "#{op} needs a page"}

  defp step_page(step, _op), do: {:ok, step}

  defp shape("edit_section", %{"section" => path, "body" => body} = step)
       when is_binary(path) and is_binary(body) and path != "" do
    page = Repo.get!(Slipdock.Wiki.Page, step["page"])

    case Steps.current_section_hash(page, path) do
      {:ok, hash} -> same_section(step, hash, page, path)
      {:error, message} -> {:error, message}
    end
  end

  defp shape("edit_section", _step),
    do: {:error, "edit_section needs a page, a section (its heading path) and a body"}

  defp shape("comment", %{"card" => card, "body" => body})
       when is_integer(card) and is_binary(body) and body != "",
       do: {:ok, %{"op" => "comment", "card" => card, "body" => body}}

  defp shape("comment", _step), do: {:error, "comment needs a card (an id) and a body"}

  defp shape("file_page", %{"page" => page} = step) do
    case Map.fetch(step, "folder") do
      {:ok, folder} when is_integer(folder) or is_nil(folder) ->
        {:ok, %{"op" => "file_page", "page" => page, "folder" => folder}}

      _ ->
        {:error, "file_page needs a folder (an id, or null for none)"}
    end
  end

  # A base given must be the section as it is now; none is filled in.
  defp same_section(%{"base" => base} = step, hash, _page, _path)
       when base in [nil, ""] or base == hash,
       do: {:ok, base_step(step, hash)}

  defp same_section(%{"base" => _stale}, _hash, page, path),
    do:
      {:error,
       "“#{page.title}” §#{path} has changed since that base: read it again and propose afresh"}

  defp same_section(step, hash, _page, _path), do: {:ok, base_step(step, hash)}

  defp base_step(step, hash),
    do: %{
      "op" => "edit_section",
      "page" => step["page"],
      "section" => step["section"],
      "body" => step["body"],
      "base" => hash
    }

  defp open(%Suggestion{state: "open"}), do: :ok
  defp open(%Suggestion{state: state}), do: {:error, "that suggestion is #{state}, not open"}

  defp can_write(user, %Suggestion{board_id: board_id}) do
    board = Repo.get!(Board, board_id)

    if Access.can_write?(Access.board_permission(user, board)),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp chosen_steps(%Suggestion{proposal: steps}, choice) when choice in [nil, ""],
    do: {:ok, steps}

  defp chosen_steps(%Suggestion{alternatives: alts}, choice) do
    case Map.fetch(alts || %{}, choice) do
      {:ok, steps} ->
        {:ok, steps}

      :error ->
        {:error,
         "no fix called “#{choice}”: choose from #{Enum.join(Map.keys(alts || %{}), ", ")}"}
    end
  end

  # One line in the activity log for each card and page it was about.
  defp log(%Suggestion{} = s, message) do
    for id <- Suggestion.card_ids(s),
        card = Repo.get(Boards.Card, id),
        do: Boards.ActivityLog.log_activity(card.board_id, card.id, "card", message)

    for id <- Suggestion.page_ids(s),
        page = Repo.get(Slipdock.Wiki.Page, id),
        do: Boards.ActivityLog.log_activity_for(page, "page", message)

    :ok
  end

  @doc "Subscribes the caller to `{:garden_changed, board_id}` whenever a suggestion on the board changes."
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(Slipdock.PubSub, topic(board_id))

  defp topic(board_id), do: "garden:#{board_id}"

  defp broadcast(%{board_id: board_id}),
    do: Phoenix.PubSub.broadcast(Slipdock.PubSub, topic(board_id), {:garden_changed, board_id})

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end
