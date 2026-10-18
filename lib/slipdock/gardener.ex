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
    Slipdock.Gardener.Checks.DuplicateCards
  ]

  @doc "Every check, in the order the Tidy-up page shows them."
  def checks, do: @checks

  @doc "The check with that key, or nil."
  def check(key), do: Enum.find(checks(), &(&1.key() == key))

  @doc "The keys of every check."
  def check_keys, do: Enum.map(checks(), & &1.key())

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
      |> Enum.filter(&(is_nil(opts[:only]) or &1.key() in List.wrap(opts[:only])))
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
      for {fp, {key, f}} <- found, Map.get(known, fp) not in ~w(open dismissed applied) do
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

  `{:ok, suggestion}`, or `{:error, reason}`: `:forbidden` without write
  access to the board and everything the steps touch, or a sentence.
  """
  def apply(%Suggestion{} = suggestion, user, opts \\ []) do
    with :ok <- open(suggestion),
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
    end
  end

  @doc "Dismisses `suggestion` as `user`: it is not suggested again while its subject stays as it is."
  def dismiss(%Suggestion{} = suggestion, user) do
    with :ok <- open(suggestion),
         :ok <- can_write(user, suggestion) do
      suggestion
      |> Ecto.Changeset.change(
        state: "dismissed",
        decided_by_id: user.id,
        decided_at: DateTime.utc_now(:second)
      )
      |> Repo.update()
      |> tap_ok(&broadcast/1)
    end
  end

  @doc """
  Undoes an applied `suggestion` as `user`, step by step in reverse, and
  makes it open again. Refused, with nothing changed, when something it
  undoes has moved on since (`{:error, "card #12 … has been reopened since"}`).
  """
  def undo(%Suggestion{state: "applied"} = suggestion, user) do
    inverse = (suggestion.undo || %{})["steps"] || []

    with :ok <- can_write(user, suggestion),
         :ok <- Steps.authorize(inverse, user),
         :ok <- Steps.undo_all(inverse, user) do
      log(suggestion, "undone via gardener: #{suggestion.explanation}")

      suggestion
      |> Ecto.Changeset.change(state: "open", decided_by_id: nil, decided_at: nil, undo: nil)
      |> Repo.update()
      |> tap_ok(&broadcast/1)
    end
  end

  def undo(%Suggestion{}, _user), do: {:error, "only an applied suggestion can be undone"}

  @doc "Applies or dismisses, by name: `decide(s, user, \"apply\" | \"dismiss\", opts)`."
  def decide(suggestion, user, decision, opts \\ [])
  def decide(s, user, "apply", opts), do: __MODULE__.apply(s, user, opts)
  def decide(s, user, "dismiss", _opts), do: dismiss(s, user)
  def decide(_s, _user, _other, _opts), do: {:error, "decision must be apply or dismiss"}

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
        do: Boards.log_activity(card.board_id, card.id, "card", message)

    for id <- Suggestion.page_ids(s),
        page = Repo.get(Slipdock.Wiki.Page, id),
        do: Boards.log_activity_for(page, "page", message)

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
