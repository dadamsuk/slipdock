defmodule Slipdock.Verified do
  @moduledoc """
  Verified work (#1620): optional, per-board checks on what an agent says it
  finished. Every switch is off by default, and with them all off nothing
  here changes anything.

    * **The bar** (`Board.bar_required`, #1631): what done means for a card,
      written before work starts. An agent can't move a card into a doing
      list without one, and the bar locks the first time the card enters a
      doing list with one written. After that an agent can't change it; a
      person still can.
    * **Evidence** (`Board.evidence_required`, #1632): an agent completing a
      card says what it checked (`evidence`) and, if there is one, the commit
      it checked at (`evidence_commit`), in the same write or beforehand. The
      evidence is posted as a comment when the card completes, and cleared
      when it is reopened, so the next completion carries its own.
    * **Verification** (`Board.verify_work`, #1633): an agent completing a
      card submits it instead. It stays open, `verify_state: "pending"`,
      flagged `review`, until a different actor decides (`decide/5`):
      accepting completes it and moves it to the done list; rejecting needs
      a reason, which is kept and commented (the handoff only points at it),
      the builder's own assignment comes off, and the card goes back to the
      top of the ready list with its rejection counted, next for the feed. A person completing a pending card accepts it.
    * **Shipping by pull request** (`Board.ship_via`, #1654): the builder
      opens a pull request instead of pushing the default branch, and names
      it in `evidence_pr`, which a board asking for evidence requires. A
      card that changes no code names why in `evidence_no_code` instead
      (#1938), and accepting it merges nothing.
    * **Verify jobs** (`Board.verify_pool`, #1634): with a pool named, a
      card going pending is queued for that runner pool as a `verify` job,
      its prompt saying what to check and how to decide. A decision cancels
      any other verify job still open on the card.

  Two checks have no switch. An agent can't complete (or submit) a card
  whose sub-board still has open cards, by a write or a move into a done
  list; the refusal names them (`open_subcards/1`, #1758). And an agent
  can't reopen a completed card, by unticking it or moving it out of a done
  list (`reopen_message/2`, #1850). Each guards against a contradiction, an
  epic done over unfinished work or finished work undone by a script,
  rather than asking more of an agent's work, so they hold on every board.

  The checks apply to agents (`Slipdock.Actor` kind `"agent"`), not to the
  in-app assistant, which acts on a person's say in the web app, nor to
  people or automations: a person is who the checks report to.
  """

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Boards.{Board, Card, CardMove, Column}
  alias Slipdock.Repo
  alias Slipdock.Verified.Circling

  @doc "Whether the checks apply to a change made by `actor`."
  def gated?(%{kind: "agent", via: via}) when via != "assistant", do: true
  def gated?(_actor), do: false

  @doc """
  Whether `card` is awaiting verification on a board that ships by push
  (#1661). Its work is on the default branch already and nobody is editing
  its files, so while it is pending it releases its lane (`Slipdock.Lanes`)
  and counts as finished for the cards that depend on it
  (`Slipdock.Boards.Card.blocked?/1`, through `Boards.dependency_query/0`).
  A rejection ends both. On a board that ships by pull request the work is
  on an unmerged branch, so a pending card keeps both until the merge.

  The queries in `Slipdock.Lanes`, `Slipdock.Rollup` and
  `Boards.dependency_query/0` say the same in SQL.
  """
  def released?(card, board \\ nil)

  def released?(%Card{verify_state: "pending"} = card, board),
    do: not Board.ships_by_pr?(board || board(card))

  def released?(_card, _board), do: false

  @doc "Whether `board` has any of the switches on, and which."
  def switches(%Board{} = board) do
    [bar: board.bar_required, evidence: board.evidence_required, verify: board.verify_work]
    |> Enum.filter(fn {_, on} -> on == true end)
    |> Keyword.keys()
  end

  ## The bar ------------------------------------------------------------------

  @evidence_message "is required: this board asks an agent completing a card for what it " <>
                      "checked — none of evidence (what you checked), evidence_commit (and " <>
                      "evidence_branch), evidence_tests (the test files), evidence_suite " <>
                      "({result: passed|failed, passed, failed}) or evidence_pr (the pull " <>
                      "request's URL) was given"

  @both_message "can't go with evidence_pr: a card either changes no code or names the " <>
                  "pull request its code is in, not both"

  @pr_message "is required: this board ships by pull request, so an agent completing a " <>
                "card names the pull request its work is in (evidence_pr, `slipdock done " <>
                "--pr URL`); push the card's branch and open one, never the default branch " <>
                "(an epic, whose subcards ship their own, needs none; a card that changes no " <>
                "code says why instead: evidence_no_code, `slipdock done --no-code REASON`)"

  @spike_pr_message "can't be given for a spike: a spike merges nothing, so complete it with " <>
                      "--no-code and the branch its prototype is on (evidence_no_code, " <>
                      "`slipdock done --no-code \"spike: answer on W-…, prototype on card-<id>\"`) " <>
                      "and close any pull request you opened for it"

  @pr_commit_message "is required with evidence_pr: the pull request is merged at the commit " <>
                       "the card names, so give its head (evidence_commit, `slipdock done " <>
                       "--pr URL --evidence-commit SHA`, the sha `gh pr view URL --json " <>
                       "headRefOid -q .headRefOid` shows), on a resubmission too"

  @dash_message "was a bare '-', which is no evidence: a client that doesn't read stdin " <>
                  "sends the dash itself, so what was piped in (the Handbook: line, the " <>
                  "Findings: block) never arrived. Pass the text itself (--evidence \"…\", " <>
                  "complete_card evidence) or pipe it with --evidence - from a CLI that reads " <>
                  "stdin (the slipdock CLI since #1966)"

  @doc """
  `{:ok, attrs, changes}` — `attrs` as they are to be cast, and `changes` to
  put on the card besides (the verification fields, which are never cast) —
  or `{:error, field, message}` when `actor` may not make the change they
  describe to `card`: an agent changing a locked bar, completing a card
  whose sub-board has open cards (on any board), or completing one with no
  evidence on a board that asks for it.

  On a board that verifies work, an agent's completion becomes a
  submission, and a person's completion of a pending card an acceptance.
  """
  def check_update(%Card{} = card, attrs, actor) do
    with :ok <- check_reopen(card, attrs, actor),
         :ok <- check_dash(card, attrs, actor),
         :ok <- check_bar_edit(card, attrs, actor),
         :ok <- check_profile_edit(card, attrs, actor),
         :ok <- check_subcards(card, attrs, actor),
         :ok <- check_evidence(card, attrs, actor),
         :ok <- check_spike_pr(card, attrs, actor),
         :ok <- check_change(attrs) do
      {attrs, changes} = card |> clear_evidence(attrs) |> verification(card, actor)
      {:ok, attrs, changes}
    end
  end

  defp check_bar_edit(%Card{bar_locked_at: nil}, _attrs, _actor), do: :ok

  defp check_bar_edit(%Card{} = card, attrs, actor) do
    new = fetch(attrs, :bar)

    cond do
      new == :none or not gated?(actor) ->
        :ok

      trim(new) == trim(card.bar) ->
        :ok

      not board(card).bar_required ->
        :ok

      true ->
        {:error, :bar,
         "is locked: it was set before work started and only a person can change it now"}
    end
  end

  ## The profile (#2016) -------------------------------------------------------

  @doc """
  The message an agent gets setting `card`'s profile to `new` (nil or ""
  clears it), or nil when it may. On a board with profiles on, once the card
  has been started or a person set its profile, an agent may keep the
  profile or raise it to a stricter one (`Slipdock.Profiles.rank/1`), never
  lower or clear it: the profile decides how the work is checked and who
  must look before it merges. A person can do either.
  """
  def profile_message(%Card{} = card, new, actor) do
    new = if blank?(new), do: nil, else: String.downcase(trim(new))

    if gated?(actor) and new != card.profile and profile_locked?(card),
      do: lowering_message(card, new)
  end

  defp lowering_message(%Card{profile: nil}, nil), do: nil

  defp lowering_message(%Card{} = card, nil) do
    "card ##{card.id}'s profile (#{card.profile}) can't be cleared by an agent once work has " <>
      "started: only a person can lower or clear it"
  end

  # An unknown name is the changeset's to refuse, with the list.
  defp lowering_message(%Card{} = card, new) do
    was = card.profile || Slipdock.Profiles.profile_of(card)

    if Slipdock.Profiles.name?(new) and Slipdock.Profiles.rank(new) < Slipdock.Profiles.rank(was),
      do:
        "card ##{card.id}'s profile can only be raised by an agent once work has started " <>
          "(#{was} to #{new} lowers it): only a person can lower or clear it"
  end

  defp check_profile_edit(card, attrs, actor) do
    with new when new != :none <- fetch(attrs, :profile),
         message when is_binary(message) <- profile_message(card, new, actor) do
      {:error, :profile, "is refused: " <> message}
    else
      _ -> :ok
    end
  end

  # Whether an agent's profile edits are held to raising (#2016): on a board
  # with profiles on, once a person set it or work on the card has started
  # (in a doing list now or ever before, its bar locked, inferred at an
  # agent's start or claim, completed, or submitted for verification). Once
  # started, a card stays started.
  defp profile_locked?(%Card{} = card) do
    board(card).profiles == true and
      (Enum.member?(["person", "inferred"], card.profile_source) or started?(card))
  end

  defp started?(%Card{} = card) do
    card.completed == true or not is_nil(card.bar_locked_at) or
      not is_nil(card.verify_state) or
      doing?(Repo.get(Column, card.column_id)) or
      entered_doing?(card)
  end

  # Whether the move ledger has the card entering a doing list (created in
  # one, moved or restored into one). The ledger snapshots the list's
  # category, so a list renamed or recategorised since still counts.
  defp entered_doing?(%Card{id: id}) do
    Repo.exists?(
      from m in CardMove,
        where:
          m.card_id == ^id and m.to_category == "doing" and
            m.kind in ^CardMove.entry_kinds()
    )
  end

  @doc """
  `:ok`, or `{:error, message}` when `actor` may not move `card` into `to`:
  an agent taking a completed card out of a done list (on any board),
  starting work on a card with no bar on a board that asks for one,
  completing one by a move while its sub-board has open cards (on any
  board), or with no evidence on a board that asks for it.
  """
  def check_move(%Card{} = card, %Column{} = to, actor) do
    cond do
      message = reopen_move_message(card, to, actor) ->
        {:error, message}

      doing?(to) and blank?(card.bar) and gated?(actor) and board(card).bar_required ->
        {:error,
         "this board asks for each card's bar before work starts: write what done means " <>
           "for card ##{card.id} (its `bar`), then move it"}

      message = check_subcards_move(card, to, actor) ->
        {:error, message}

      message = check_done_move(card, to, actor) ->
        {:error, message}

      Column.done?(to) and not card.completed and gated?(actor) and board(card).verify_work ->
        {:error,
         "this board verifies work: submit card ##{card.id} by completing it (complete_card, " <>
           "`slipdock done`), and a different agent or a person accepts it into the done list"}

      true ->
        :ok
    end
  end

  @doc """
  After `card` has moved into `to`: the bar locks when work starts, if it is
  written and the board asks for one.
  """
  def moved(%Card{bar_locked_at: nil} = card, %Column{} = to) do
    if doing?(to) and not blank?(card.bar) and board(card).bar_required do
      card
      |> Ecto.Changeset.change(bar_locked_at: DateTime.utc_now(:second))
      |> Repo.update()
    else
      {:ok, card}
    end
  end

  def moved(%Card{} = card, _to), do: {:ok, card}

  @doc """
  The checks of a move into `column`, for a card being created there (#1815):
  `changeset` (a new card's) with a `bar` error when `actor` (an agent) may
  not start work on it, because the list is a doing list, the board asks for
  a bar and the card has none; else with the bar locked, as a move into the
  list would lock it.

  Created finished (#1918), in a done list or with `completed` set, the card
  meets what an agent completing it would: on a board that verifies work it
  is refused (a submission needs a card to submit; a board that ships by
  pull request always verifies), and on one that asks for evidence it needs
  some. A changeset already invalid, or for any other list, comes back as
  it was.
  """
  def check_create(%Ecto.Changeset{valid?: true} = changeset, %Column{} = column, actor) do
    card = Ecto.Changeset.apply_changes(changeset)

    if (Column.done?(column) or card.completed) and gated?(actor),
      do: check_create_done(changeset, card, column),
      else: check_create_doing(changeset, card, column, actor)
  end

  def check_create(%Ecto.Changeset{} = changeset, _column, _actor), do: changeset

  defp check_create_done(changeset, card, column) do
    board = board(card)

    cond do
      dash?(card.evidence) ->
        Ecto.Changeset.add_error(changeset, :evidence, @dash_message)

      board.verify_work ->
        Ecto.Changeset.add_error(
          changeset,
          :completed,
          "is refused: this board verifies work, so an agent can't create a card already " <>
            "done (in #{column.name} or completed). Create it in another list, then submit it " <>
            "by completing it (complete_card, `slipdock done`) for a different agent or a " <>
            "person to accept"
        )

      board.evidence_required and not evidence?(card) ->
        Ecto.Changeset.add_error(
          changeset,
          :evidence,
          @evidence_message <>
            ", to create a card in #{column.name}. Give it in the create, or create the " <>
            "card in another list and complete it with evidence (complete_card, `slipdock done`)"
        )

      true ->
        changeset
    end
  end

  defp check_create_doing(changeset, card, column, actor) do
    cond do
      not doing?(column) or not board(card).bar_required ->
        changeset

      blank?(card.bar) and gated?(actor) ->
        Ecto.Changeset.add_error(
          changeset,
          :bar,
          "is needed to start work: this board asks for each card's bar before work " <>
            "starts, so write what done means (its `bar`) to create a card in " <>
            "#{column.name}, or create it in another list"
        )

      blank?(card.bar) ->
        changeset

      true ->
        Ecto.Changeset.put_change(changeset, :bar_locked_at, DateTime.utc_now(:second))
    end
  end

  ## Done stays done (#1850) --------------------------------------------------

  @doc """
  The message an agent gets reopening `card`, or nil when it may. On every
  board, an agent can't untick a completed card or move it out of a done
  list into one that isn't: nothing an agent does needs it (a rejection
  comes before Done, a retry only puts back a card left in progress, and a
  recurring card is copied), and a script that does it undoes finished work.
  Reopening is a person's call.
  """
  def reopen_message(%Card{completed: true} = card, actor) do
    if gated?(actor),
      do:
        "card ##{card.id} is done, and an agent can't reopen it (untick it or move it out of " <>
          "the done list): a person reopens finished work. If it needs more, add a card for " <>
          "that and link it"
  end

  def reopen_message(_card, _actor), do: nil

  defp check_reopen(card, attrs, actor) do
    with true <- fetch(attrs, :completed) in [false, "false"],
         message when is_binary(message) <- reopen_message(card, actor) do
      {:error, :completed, "is refused: " <> message}
    else
      _ -> :ok
    end
  end

  @doc """
  The message an agent gets moving a completed `card` out of a done list
  into `to`, which isn't one, or nil when it may.
  """
  def reopen_move_message(%Card{completed: true} = card, %Column{} = to, actor) do
    if gated?(actor) and not Column.done?(to) and Column.done?(Repo.get!(Column, card.column_id)),
      do: reopen_message(card, actor)
  end

  def reopen_move_message(_card, _to, _actor), do: nil

  ## Open subcards (#1758) ----------------------------------------------------

  # How many open subcards a refusal names before it says how many more.
  @named_subcards 10

  @doc """
  The cards still open on `card`'s sub-board, as `{id, title}` in id order:
  not completed, not archived and not submitted for verification (pending,
  or accepted and merging or held for a person, #1952, which is the
  verifier's or the person's to finish). A subcard
  that is complete counts as done whatever its own sub-board holds. An
  archived sub-board, or none, has none.
  """
  def open_subcards(%Card{id: id}) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id == ^id and is_nil(b.archived_at) and c.completed == false and
          is_nil(c.archived_at) and
          coalesce(c.verify_state, "") not in ["pending", "merging", "held"],
      order_by: c.id,
      select: {c.id, c.title}
    )
    |> Repo.all()
  end

  defp check_subcards(card, attrs, actor) do
    with true <- completes?(card, attrs) and gated?(actor),
         message when is_binary(message) <- subcards_message(card) do
      {:error, :completed, "is refused: " <> message}
    else
      _ -> :ok
    end
  end

  defp check_subcards_move(card, to, actor) do
    if Column.done?(to) and not card.completed and gated?(actor), do: subcards_message(card)
  end

  # Why `card` can't be completed by an agent yet, or nil when it can.
  defp subcards_message(%Card{} = card) do
    case open_subcards(card) do
      [] ->
        nil

      open ->
        {named, rest} = Enum.split(open, @named_subcards)
        names = Enum.map_join(named, ", ", fn {id, title} -> "##{id} #{title}" end)
        more = if rest == [], do: "", else: " and #{length(rest)} more"
        verb = if length(open) == 1, do: "is", else: "are"

        "card ##{card.id} has open subcards: #{names}#{more} #{verb} still open. " <>
          "Finish or archive them first, then complete it"
    end
  end

  @doc """
  Whether `card` is an epic (#1917): its sub-board, not archived, holds a
  card that isn't archived. On a board that ships by pull request each
  subcard ships its own pull request, so an epic needs none of its own.
  """
  def epic?(%Card{id: id}) do
    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.parent_card_id == ^id and is_nil(b.archived_at) and is_nil(c.archived_at)
    )
    |> Repo.exists?()
  end

  @doc """
  Whether accepting `card` on a board that ships by pull request has
  nothing to merge (#1917): it is an epic, and it names no pull request, or
  one a subcard of it already merged (an accepted, completed subcard with
  the same `evidence_pr`). Such an epic completes on acceptance, as on a
  push board; an epic naming a pull request of its own still merges it.
  """
  def nothing_to_merge?(%Card{} = card) do
    no_code?(card) or
      (epic?(card) and (blank?(card.evidence_pr) or subcard_merged?(card, card.evidence_pr)))
  end

  @doc """
  Whether `card`'s evidence says it changes no code (#1938): it gives a
  reason in `evidence_no_code` and names no pull request. A sweep, a
  handbook reconcile or any read-and-file card has no branch and no pull
  request, so on a board that ships by pull request it completes without
  one, and accepting it merges nothing.
  """
  def no_code?(%Card{} = card),
    do: not blank?(card.evidence_no_code) and blank?(card.evidence_pr)

  defp subcard_merged?(%Card{id: id}, pr) do
    pr = pr_key(pr)

    from(c in Card,
      join: b in Board,
      on: b.id == c.board_id,
      where:
        b.parent_card_id == ^id and is_nil(c.archived_at) and c.completed == true and
          c.verify_state == "accepted" and not is_nil(c.evidence_pr),
      select: c.evidence_pr
    )
    |> Repo.all()
    |> Enum.any?(&(pr_key(&1) == pr))
  end

  # The same pull request whatever its trailing slash, case or fragment.
  defp pr_key(url),
    do:
      url
      |> trim()
      |> String.split(["#", "?"])
      |> hd()
      |> String.trim_trailing("/")
      |> String.downcase()

  @nothing_to_merge "an epic whose subcards merged their own pull requests: nothing to merge"
  @no_code_accepted "a card that changes no code: nothing to merge"

  ## Evidence -----------------------------------------------------------------

  # A bare `-` (#2091): `--evidence -` from a client that doesn't read
  # stdin. Refused for agents (SPEC-5, MOD-3: people, the assistant and
  # automations are never refused) on any board, on any write that sets it
  # and on a completion of a card that still holds one, so the piped text is
  # never lost behind a dash.
  defp check_dash(%Card{} = card, attrs, actor) do
    if gated?(actor) and dashed?(card, attrs),
      do: {:error, :evidence, @dash_message},
      else: :ok
  end

  defp dashed?(card, attrs) do
    dash?(fetch(attrs, :evidence)) or
      (completes?(card, attrs) and dash?(given(attrs, :evidence, card.evidence)))
  end

  @doc "Whether `evidence` is a bare `-` once trimmed (#2091)."
  def dash?(evidence) when is_binary(evidence), do: String.trim(evidence) == "-"
  def dash?(_evidence), do: false

  # The fields evidence is made of (#1632, #1623): any one of them is some.
  @evidence_fields ~w(evidence evidence_commit evidence_branch evidence_tests evidence_suite evidence_pr evidence_no_code)a

  defp check_evidence(%Card{} = card, attrs, actor) do
    cond do
      not (completes?(card, attrs) and gated?(actor) and board(card).evidence_required) ->
        :ok

      not evidence?(card, attrs) ->
        {:error, :evidence, @evidence_message}

      Board.ships_by_pr?(board(card)) ->
        check_pr(card, attrs)

      true ->
        :ok
    end
  end

  # On a board that ships by pull request: a pull request and the commit it
  # is to merge at (#1976), or a reason the card changes no code (#1938), or
  # an epic, whose subcards ship their own.
  defp check_pr(card, attrs) do
    pr? = present?(given(attrs, :evidence_pr, card.evidence_pr))
    no_code? = present?(given(attrs, :evidence_no_code, card.evidence_no_code))

    cond do
      pr? and no_code? -> {:error, :evidence_no_code, @both_message}
      pr? and missing_commit?(card, attrs) -> {:error, :evidence_commit, @pr_commit_message}
      pr? or no_code? or epic?(card) -> :ok
      true -> {:error, :evidence_pr, @pr_message}
    end
  end

  # A spike's code is never merged (#2349): an agent completing one names
  # no pull request, on any board. People, the assistant and automations
  # are not refused (W-2235).
  defp check_spike_pr(%Card{} = card, attrs, actor) do
    if completes?(card, attrs) and gated?(actor) and
         present?(given(attrs, :evidence_pr, card.evidence_pr)) and
         Slipdock.Profiles.spike?(spiked(card, attrs)),
       do: {:error, :evidence_pr, @spike_pr_message},
       else: :ok
  end

  # The card as the write would leave its profile, for `spike?/1`.
  defp spiked(card, attrs) do
    case fetch(attrs, :profile) do
      profile when is_binary(profile) -> %{card | profile: String.trim(profile)}
      _ -> card
    end
  end

  # A pull request is merged at the card's commit (#1976), so one named
  # without a commit leaves the accepted card nothing to merge at. An epic
  # naming a PR its subcard already merged has nothing to merge (#1917).
  defp missing_commit?(card, attrs) do
    pr = given(attrs, :evidence_pr, card.evidence_pr)

    not present?(given(attrs, :evidence_commit, card.evidence_commit)) and
      not (epic?(card) and subcard_merged?(card, pr))
  end

  @doc "Whether `card` carries any evidence (or would, with `attrs`)."
  def evidence?(card, attrs \\ %{}) do
    Enum.any?(@evidence_fields, fn key -> present?(given(attrs, key, Map.get(card, key))) end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value) or is_map(value), do: value != [] and value != %{}
  defp present?(value), do: not is_nil(value)

  defp no_evidence, do: Map.new(@evidence_fields, &{to_string(&1), nil})

  # Reopened on a board that asks for evidence: what it carried was for the
  # completion that is being undone (and was kept as a comment then).
  defp clear_evidence(%Card{completed: true} = card, attrs) do
    if fetch(attrs, :completed) in [false, "false"] and evidence?(card) and
         board(card).evidence_required,
       do: attrs |> stringify() |> Map.merge(no_evidence()),
       else: attrs
  end

  defp clear_evidence(_card, attrs), do: attrs

  @doc """
  The message an agent gets moving a card into a done list with no evidence
  on a board that asks for it, or nil when it may.
  """
  def check_done_move(%Card{completed: false} = card, %Column{} = to, actor) do
    if Column.done?(to) and gated?(actor) and not evidence?(card) and
         board(card).evidence_required,
       do:
         "this board asks for evidence when an agent completes a card: complete card ##{card.id} " <>
           "with what you checked (`evidence`, and `evidence_commit`) rather than moving it"
  end

  def check_done_move(_card, _to, _actor), do: nil

  @doc """
  After `before` has been saved as `updated`: a card completed (or submitted
  for verification) with evidence on a board that asks for it gets the
  evidence as a comment, by `user` — once: not again when it is accepted.
  """
  def saved(%Card{} = before, %Card{} = updated, user) do
    unverified? = submitted(before, updated, user)

    # Accepted by a person completing it: no job need check it now.
    if before.verify_state == "pending" and updated.verify_state == "accepted",
      do: cancel_verify_jobs(updated, nil)

    # Accepted, or merging on a board that ships by pull request: its
    # rejections have been dealt with (#2119).
    if accepted?(updated) and not accepted?(before),
      do: Slipdock.Findings.Signals.accepted(updated)

    # The epic's last spike answered: planning can resume (#2350).
    Slipdock.Spikes.answered(before, updated)

    # An audit's rework done: the alerts that named it come down (#2691).
    if finished_now?(before, updated), do: clear_audit_alerts(updated)

    evidence_comment(before, updated, user)
    if unverified?, do: accept_unverified(updated, user)

    :ok
  end

  defp accepted?(%Card{verify_state: state}), do: Enum.member?(~w(accepted merging), state)

  defp finished_now?(before, updated),
    do:
      (updated.completed and not before.completed) or
        (accepted?(updated) and not accepted?(before))

  # The evidence as a comment, once, when the card is completed or submitted.
  defp evidence_comment(before, updated, user) do
    finished? =
      (not before.completed and updated.completed and before.verify_state != "pending") or
        (before.verify_state != "pending" and updated.verify_state == "pending")

    if finished? and evidence?(updated) and board(updated).evidence_required,
      do: Slipdock.Boards.add_comment(updated, evidence_text(updated), by: user)
  end

  # A card just gone pending: queued for a verifier, or (a `docs` card,
  # #1953) left for the server to accept once its evidence is on the card,
  # when this answers true.
  defp submitted(%Card{verify_state: "pending"}, _updated, _user), do: false

  defp submitted(_before, %Card{verify_state: "pending"} = updated, user) do
    unverified? = not_verified?(updated)
    if not unverified?, do: queue_verify_job(updated, user)

    # Shipped by push: it no longer holds up the cards that depend on it.
    if released?(updated), do: Slipdock.Boards.unblock_dependents(updated, by: user)
    unverified?
  end

  defp submitted(_before, _updated, _user), do: false

  @doc """
  A card's evidence as Markdown (#1632, #1623): what was checked, then the
  commit and branch, the suite's result and the test files.
  """
  def evidence_text(%Card{} = card) do
    suite = card.evidence_suite

    [
      "**Evidence.**",
      card.evidence,
      card.evidence_commit &&
        "Commit: `#{card.evidence_commit}`" <>
          if(card.evidence_branch, do: " on `#{card.evidence_branch}`", else: ""),
      is_nil(card.evidence_commit) && card.evidence_branch && "Branch: `#{card.evidence_branch}`",
      labelled("Pull request", card.evidence_pr),
      labelled("No code", card.evidence_no_code),
      suite && "Suite: #{suite_text(suite)}",
      card.evidence_tests not in [nil, []] &&
        "Tests:\n" <> Enum.map_join(card.evidence_tests, "\n", &"- `#{&1}`")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n\n")
  end

  defp labelled(_label, nil), do: nil
  defp labelled(label, text), do: "#{label}: #{text}"

  @doc "A suite's result in words: `passed (38 passed, 0 failed)`."
  def suite_text(%{} = suite) do
    counts =
      [{suite["passed"], "passed"}, {suite["failed"], "failed"}]
      |> Enum.reject(fn {n, _} -> is_nil(n) end)
      |> Enum.map_join(", ", fn {n, what} -> "#{n} #{what}" end)

    if counts == "", do: suite["result"], else: "#{suite["result"]} (#{counts})"
  end

  @doc """
  The raise an agent's completion of `card` with `attrs` makes to its
  profile (#2017): `%{profile: raised, from: before, why: reason}`, or nil.
  Only on a board with profiles on, when the completion carries the actual
  change (`changed_lines`, the lines it adds and removes, and
  `changed_files`, the paths it touches), read by
  `Slipdock.Profiles.recheck/4` against the card's profile: the one the
  write sets, else the card's, else the one its paths and tags infer.
  Never lower. A person, a rule or the assistant completing it raises
  nothing.
  """
  def profile_raise(%Card{} = card, attrs, actor) do
    lines = changed_lines(fetch(attrs, :changed_lines))
    files = with :invalid <- changed_files(fetch(attrs, :changed_files)), do: []

    if completes?(card, attrs) and gated?(actor) and (is_integer(lines) or files != []) and
         board(card).profiles do
      {profile, source} = current_profile(card, attrs)

      case Slipdock.Profiles.recheck(profile, source, lines, files) do
        {raised, why} -> %{profile: raised, from: profile, why: why}
        nil -> nil
      end
    end
  end

  @doc "The activity line for a raise from `profile_raise/3`."
  def raise_text(%{profile: raised, from: from, why: why}),
    do: "profile raised: #{from} → #{raised}, #{why}"

  # The profile the change is judged against, and who set it: the one this
  # write sets (by the agent writing), else the card's, else inferred.
  defp current_profile(card, attrs) do
    case fetch(attrs, :profile) do
      profile when is_binary(profile) and profile != "" ->
        {profile |> String.trim() |> String.downcase(), "agent"}

      _ when is_binary(card.profile) ->
        {card.profile, card.profile_source}

      _ ->
        {card |> Repo.preload(:tags) |> Slipdock.Profiles.profile_of(), "inferred"}
    end
  end

  @max_changed_files 5000

  # The change a completion reports (#2017): a whole number of lines, 0 or
  # more, and a list of paths (or one comma-separated string).
  defp check_change(attrs) do
    lines = fetch(attrs, :changed_lines)
    files = fetch(attrs, :changed_files)

    cond do
      changed_lines(lines) == :invalid ->
        {:error, :changed_lines,
         "must be a whole number, 0 or more: the lines the change adds and removes"}

      changed_files(files) == :invalid ->
        {:error, :changed_files,
         "must be a list of the paths the change touches (at most #{@max_changed_files})"}

      true ->
        :ok
    end
  end

  defp changed_lines(n) when is_integer(n) and n >= 0, do: n
  defp changed_lines(none) when none in [:none, nil, ""], do: nil

  defp changed_lines(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n >= 0 -> n
      _ -> :invalid
    end
  end

  defp changed_lines(_), do: :invalid

  defp changed_files(text) when is_binary(text),
    do: text |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> changed_files()

  defp changed_files(paths) when is_list(paths) do
    if length(paths) <= @max_changed_files and Enum.all?(paths, &is_binary/1),
      do: Enum.reject(paths, &(String.trim(&1) == "")),
      else: :invalid
  end

  defp changed_files(none) when none in [:none, nil], do: []
  defp changed_files(_), do: :invalid

  defp completes?(%Card{completed: false}, attrs), do: fetch(attrs, :completed) in [true, "true"]
  defp completes?(_card, _attrs), do: false

  # What `attrs` set `key` to, else what the card already has.
  defp given(attrs, key, current) do
    case fetch(attrs, key) do
      :none -> current
      value -> value
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  ## Who an agent assigned (#1659) ------------------------------------------

  @doc """
  After a write changed `card`'s assignees from `before` to `now`, by
  `actor`: keeps `agent_assignee_ids`, the people an agent put on it. An
  agent's additions join it; whoever is taken off leaves it; a person (or
  the assistant, or a rule) adding someone makes that one theirs. A
  rejection takes off whoever is still on the list (`decide/5`).
  """
  def assigned(%Card{} = card, before, now, actor) when is_list(before) and is_list(now) do
    added = now -- before
    mine = card.agent_assignee_ids || []

    ids =
      if gated?(actor),
        do: Enum.uniq(mine ++ added) -- (before -- now),
        else: mine -- (added ++ (before -- now))

    ids = Enum.filter(ids, &(&1 in now))

    if Enum.sort(ids) != Enum.sort(mine) do
      import Ecto.Query
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [agent_assignee_ids: ids])
    end

    :ok
  end

  def assigned(_card, _before, _now, _actor), do: :ok

  ## Shipping by pull request -------------------------------------------------

  @doc "The branch a card's work goes on when its board ships by pull request (#1655)."
  def pr_branch(%Card{id: id}), do: "card-#{id}"

  @doc """
  What the builder of `card` is told when its board ships by pull request
  (#1655), or nil when it ships by push: never push the default branch,
  push `card-<id>` and open (or update) the pull request, and name it when
  completing. Said in a claimed job's prompt and in the card's JSON, so a
  runner or an older skill needs nothing else to know.

  A spike (`Slipdock.Profiles.spike?/1`, #2351) gets `spike_note/1`
  instead, on any board: its code is never merged.

  A card tagged `security` (see `neutral?/1`, #1794) gets a neutral pull
  request instead: the repository may be public, and a PR describes the
  hole for anyone to read before the fix deploys. Its title is
  `neutral_pr_title/1`, never the card's; its body is only the card id,
  never `--fill` from the commits; and the builder is told to keep the
  commits, title and body to a neutral description of the change.
  """
  def ship_instructions(%Card{} = card) do
    cond do
      Slipdock.Profiles.spike?(card) -> spike_note(card)
      Board.ships_by_pr?(board(card)) -> pr_instructions(card)
      true -> nil
    end
  end

  defp pr_instructions(card) do
    branch = pr_branch(card)
    neutral = neutral?(card)

    create =
      if neutral,
        do:
          ~s(gh pr create --head #{branch} --title "#{neutral_pr_title(card)}" --body "Card ##{card.id}.")
          |> then(&"`#{&1}` (a neutral title, not the card's)"),
        else: "`gh pr create --head #{branch} --title \"#{pr_title(card)}\" --fill`"

    """
    This board ships by pull request: never push the default branch.
    - Work on the branch `#{branch}`: `git fetch origin && git switch #{branch}` if it is on origin (a rejected card's earlier attempt), else `git switch -c #{branch}`. Rebase it on the default branch before pushing.
    - Commit with the card id (##{card.id}) in the message, then `git push -u origin #{branch}`.
    - Open the pull request once: `gh pr view #{branch}` shows one already open, which the push has updated; otherwise #{create}.
    #{if neutral, do: neutral_note() <> "\n", else: ""}- Before pushing, run the tests you added or changed and the project's own pre-push checks, not the whole suite: the pull request's CI runs it. #{pre_push_checks(card)}
    - The build to watch is the pull request's (`gh pr checks #{branch} --watch --fail-fast`, so a failed check stops the watch when it fails). Fix what it finds in this pass. If the pull request has no checks, run the whole suite yourself.
    - Complete the card with its URL and its head commit: `slipdock done #{card.id} --pr <url> --evidence-commit <sha>` (complete_card `pr` and `commit`; the sha is `gh pr view card-#{card.id} --json headRefOid -q .headRefOid`, and a PR without one is refused, on a resubmission too), with the rest of your evidence: CI's result as the suite (`--suite passed`, with its counts if CI shows them) and its run in `--evidence`. Accepting the card merges it; don't merge it yourself.
    #{profiles_note(card)}#{no_code_note(card)}
    #{if epic?(card), do: epic_note(card), else: ""}
    """
    |> String.trim_trailing()
  end

  @doc """
  The ship instructions' line on a board with profiles on (#2017): give the
  change with the completion, so the profile is checked against it. Empty
  (no line) with profiles off.
  """
  def profiles_note(%Card{} = card) do
    if board(card).profiles,
      do:
        "- Give the change with it: `--diff-base origin/<default branch>` counts its changed lines and files from git (complete_card `changed_lines` and `changed_files`), and a change bigger or stricter than the card's profile raises it.\n",
      else: ""
  end

  @doc """
  What the builder of a spike is told (#2351), on any board: a spike
  answers a question by building, and its code is never merged. Build the
  prototype on `card-<id>` and push it, never a pull request or the default
  branch; write the answer page and pin it to the epic; complete with
  `--no-code` naming the page and the branch.
  """
  def spike_note(%Card{id: id} = card) do
    branch = pr_branch(card)

    """
    This card is a spike: it answers its bar's question by building, and its code is never merged.
    - Build the prototype on the branch `#{branch}` and push it (`git push -u origin #{branch}`) so the evidence can point at it. Never push the default branch and never open a pull request; close any you opened.
    - Spend one sitting on it. An answer of *inconclusive*, with what was learned, is a finished spike; a guess is not.
    - Write the answer as a wiki page and pin it to the epic (`slipdock page new <board> "Spike: <the question>" --card <epic id>`): the question, the answer (or *inconclusive*), the evidence (numbers, logs, the branch and commit; not claims), and what the answer changes in the plan. Put a `Findings:` block in the closing comment with it.
    - Complete it with why there is nothing to merge: `slipdock done #{id} --no-code "spike: answer on W-…, prototype on #{branch}" --evidence "<the answer in a line, the evidence, the page>"` (complete_card `no_code`). A pull request named on a spike is refused, and accepting it merges nothing.\
    """
  end

  @doc """
  Where the builder finds the project's pre-push checks (#1878): the
  handbook's Before you push section when the board's handbook has one,
  then the project's own docs, then formatting and a compile that fails on
  warnings.
  """
  def pre_push_checks(%Card{} = card) do
    case card |> board() |> Slipdock.Handbook.before_you_push() do
      %{page: code, path: path} ->
        "Its pre-push checks are in the handbook's Before you push section " <>
          "(`slipdock page section #{code} \"#{path}\"`), often one command that runs what CI checks; " <>
          "if that names none, the ones its `CLAUDE.md` or contributing guide lists; " <>
          "if it lists none, formatting and a compile that fails on warnings."

      nil ->
        "Its pre-push checks are the ones its `CLAUDE.md`, contributing guide or handbook lists, " <>
          "often one command that runs what CI checks; " <>
          "if it lists none, formatting and a compile that fails on warnings."
    end
  end

  @doc """
  What the builder on a pull request board is told about a card that
  changes no code (#1938): no branch, no pull request, never a token one;
  complete it with the reason instead, and accepting it merges nothing.
  """
  def no_code_note(%Card{id: id}) do
    "- If the card changes no code (a sweep, a handbook reconcile, a card that only reads and files), there is no branch and no pull request, and never a token one: " <>
      "complete it with why instead, `slipdock done #{id} --no-code \"<why>\" --evidence \"<what you did>\"` (complete_card `no_code`). " <>
      "Accepting it then completes it with nothing to merge."
  end

  @doc """
  What the builder of an epic on a pull request board is told (#1917):
  its subcards ship their own pull requests, so once they are all accepted
  and merged the epic completes without `--pr`, and accepting it merges
  nothing. A pull request of its own is only for work done on the epic
  itself.
  """
  def epic_note(%Card{id: id}) do
    "- This card is an epic: each subcard ships its own pull request on its own branch. " <>
      "Once every subcard is accepted and merged, complete the epic without `--pr`: " <>
      "`slipdock done #{id} --evidence \"<the subcards' PRs and the last merged build>\" --suite passed`. " <>
      "Accepting it then completes it with nothing to merge. " <>
      "Only work done on the epic itself, after its subcards, goes on `card-#{id}` with a pull request of its own, named with `--pr`."
  end

  defp neutral_note do
    "- This is a security fix, and the pull request, its commits and the branch are public before it deploys. " <>
      "Describe the change neutrally everywhere they show (commit messages, the PR's title and body, code comments): " <>
      "what it does in general terms (\"Tighten access checks in board events\"), never the hole, how to exploit it " <>
      "or a list of the affected endpoints. The detail stays on this card until the fix is deployed; " <>
      "after that, the closing comment may link to it."
  end

  @doc """
  Whether `card`'s pull request is to be neutral (#1794): it is tagged
  `security`. Its tags are loaded if they aren't.
  """
  def neutral?(%Card{} = card) do
    card
    |> Repo.preload(:tags)
    |> Map.fetch!(:tags)
    |> Enum.any?(&(String.downcase(&1.name) == "security"))
  end

  @doc "The pull request title a security card gets (#1794): its id and nothing else."
  def neutral_pr_title(%Card{id: id}), do: "Maintenance (##{id})"

  defp pr_title(%Card{} = card) do
    title = card.title |> String.replace(~s("), "'") |> String.slice(0, 80)
    "#{title} (##{card.id})"
  end

  ## Verification -------------------------------------------------------------

  # What a completion means on a board that verifies work.
  defp verification(attrs, %Card{} = card, actor) do
    cond do
      not completes?(card, attrs) ->
        {attrs, []}

      gated?(actor) and board(card).verify_work ->
        # Submitted: open, pending, flagged for review.
        attrs =
          attrs
          |> stringify()
          |> Map.delete("completed")
          |> Map.put("flags", Enum.uniq(given(attrs, :flags, card.flags) ++ ["review"]))

        {attrs,
         verify_state: "pending",
         verify_submitter: actor_map(actor),
         verify_by: nil,
         verify_note: nil,
         verify_commit: nil,
         verify_at: now()}

      card.verify_state == "pending" and not gated?(actor) ->
        # A person (or a rule) completing a pending card accepts it.
        {attrs |> stringify() |> Map.put("flags", given(attrs, :flags, card.flags) -- ["review"]),
         verify_state: "accepted", verify_by: actor_map(actor), verify_at: now()}

      true ->
        {attrs, []}
    end
  end

  @doc """
  Decides a pending card: `decision` is `"accept"` or `"reject"`, `params`
  carry `"reason"` (required to reject) and `"commit"` (the commit the
  verifier checked at; it must be the evidence's, when both are given).
  `actor` decides, and must not be who submitted it; `user` is who it is
  recorded as.

  Accepting completes the card and moves it to the board's done list.
  Rejecting puts it back at the top of the board's ready list (where there
  is one), with the reason as a comment and on the card (`verify_note`), a
  handoff pointing at it, the assignees an agent put on it taken off (a
  person's stay), its evidence cleared for the next attempt and its
  rejections counted; then the board's feed runs, so it goes next.

  `{:ok, card}`, or `{:error, status, message}` in the API's shapes.
  """
  def decide(%Card{} = card, decision, params, actor, user)
      when decision in ["agree", "disagree"] do
    reason = params |> Map.get("reason") |> trim()
    audit_decision(card, decision, params, reason, in_runner_job(actor, card), user)
  end

  def decide(%Card{verify_state: "held"} = card, decision, params, actor, user)
      when decision in ~w(accept reject) do
    held_decision(card, decision, params |> Map.get("reason") |> trim(), actor, user)
  end

  def decide(%Card{} = card, decision, params, actor, user) do
    actor = in_runner_job(actor, card)
    reason = params |> Map.get("reason") |> trim()
    commit = params |> Map.get("commit") |> trim()

    cond do
      decision == "merged" ->
        merged_by_hand(card, commit, actor, user)

      decision not in ~w(accept reject) ->
        {:error, :unprocessable_entity,
         "decision must be accept, reject or merged (agree or disagree for an audit)"}

      card.verify_state != "pending" ->
        {:error, :conflict, "card ##{card.id} isn't waiting for verification"}

      same_actor?(card.verify_submitter, actor) ->
        {:error, :forbidden,
         "you submitted card ##{card.id}: a different agent, or a person, verifies it"}

      decision == "reject" and reason == "" ->
        {:error, :unprocessable_entity, "a rejection needs its reason"}

      commit != "" and card.evidence_commit not in [nil, ""] and
          not commit_matches?(commit, card.evidence_commit) ->
        {:error, :unprocessable_entity,
         "the evidence is for commit #{card.evidence_commit}: verify the work at that commit"}

      true ->
        with {:ok, checks} <- verdict(card, decision, params, reason, actor),
             {:ok, _} = decided <-
               apply_decision(
                 card,
                 decision,
                 %{reason: reason, commit: commit, checks: checks},
                 actor,
                 user
               ) do
          cancel_verify_jobs(card, actor)
          Slipdock.Findings.Signals.pre_existing(card, checks, actor)
          Slipdock.Findings.Signals.pre_existing_mutants(card, checks, actor)
          decided
        end
    end
  end

  # The decision's verdict in parts (#1778), from `params["checks"]`, or for
  # a rejection given none, the checks its reason cites (`bar 2: …`). A
  # rejection names at least one failing part (a person's, given no parts at
  # all, may stand on its reason); an acceptance carries none but a missed
  # `should` rule. nil when there are no parts to keep.
  defp verdict(card, decision, params, reason, actor) do
    alias Slipdock.Verified.Checks

    with {:ok, given} <- checks_param(params),
         from_reason = given == %{} and decision == "reject",
         checks = if(from_reason, do: Checks.from_reason(reason), else: given),
         {:ok, checks} <- carry_previous(card, checks) do
      checks = Checks.with_severity(checks, handbook_rules(card))
      # A person's rejection, given no parts at all, may stand on its reason.
      must_fail = given != %{} or gated?(actor)

      with :ok <- verdict_holds(decision, checks, must_fail) do
        {:ok, checks |> stored_checks(from_reason) |> judged_at(decision, params, card)}
      end
    end
  end

  # A resubmission's verdict (#1944): what the last verdict passed and this
  # one didn't judge is carried, marked with the commit it passed at.
  defp carry_previous(card, checks) do
    previous = previous_verdict(card)

    case Slipdock.Verified.Checks.carry(
           checks,
           previous && previous.checks,
           previous && previous.sha
         ) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # The commit the verdict judged: the one the verifier named, else the
  # evidence's. The next verdict carries from it.
  defp judged_at(nil, _decision, _params, _card), do: nil

  defp judged_at(checks, decision, params, card) do
    case blank_to_nil(trim(Map.get(params, "commit"))) || blank_to_nil(trim(card.evidence_commit)) do
      nil -> checks
      sha -> Map.merge(checks, %{"judged_at" => sha, "decision" => decision})
    end
  end

  @doc """
  The verdict a pending card's submission follows (#1944): the last
  decision's parts and the commit they judged, `%{checks, sha, reason,
  rejections, accepted}`, when the card was decided before (a rejection, or
  an acceptance whose merge failed) and that verdict named its commit. nil
  for a first submission, or a verdict kept without its commit.
  """
  def previous_verdict(%Card{verify_checks: %{"judged_at" => sha} = checks} = card)
      when is_binary(sha) and sha != "" do
    accepted = checks["decision"] == "accept"

    %{
      checks: checks,
      sha: sha,
      accepted: accepted,
      reason: if(accepted, do: nil, else: card |> rejection_reasons() |> List.last()),
      rejections: card.verify_rejections || 0
    }
  end

  def previous_verdict(_card), do: nil

  defp verdict_holds("reject", checks, true) do
    if Slipdock.Verified.Checks.failing(checks) == [],
      do:
        {:error, :unprocessable_entity,
         "a rejection names what fails: give a failing check (`--check bar:2=fail:why`, " <>
           "`rule:UX-4=broken`, `ask=misses`, `handbook_line=disputed`, " <>
           "`mutant:survived=lib/foo.ex:42:<mutation>`), or start the reason " <>
           "with the one it fails (`bar 2: …`, `the ask: …`, `UX-4: …`, `Handbook line: …`)" <>
           pre_existing_note(checks)},
      else: :ok
  end

  defp verdict_holds("accept", checks, _must_fail) do
    case Slipdock.Verified.Checks.blocking(checks) do
      [] ->
        :ok

      blocking ->
        {:error, :unprocessable_entity,
         "an acceptance can't carry a failing check: " <>
           Enum.join(blocking, ", ") <>
           " (a broken `must` rule, a bar item, the ask, the suite, the Handbook line, an important " <>
           "defect or a surviving mutant is a rejection)"}
    end
  end

  defp verdict_holds(_decision, _checks, _must_fail), do: :ok

  # A rejection naming only pre-existing rule hits (#1945) is told why.
  defp pre_existing_note(checks) do
    if Slipdock.Verified.Checks.pre_existing(checks) == [] and
         Slipdock.Verified.Checks.pre_existing_mutants(checks) == [],
       do: "",
       else:
         ". A rule broken, or a mutant surviving, only in code the change didn't touch " <>
           "(`pre-existing`) is never a rejection: accept, and it is kept as a finding"
  end

  # nil when there are no parts; parts read from the reason are marked, as
  # the comment already says them.
  defp stored_checks(checks, _from_reason) when checks == %{}, do: nil
  defp stored_checks(checks, true), do: Map.put(checks, "from_reason", true)
  defp stored_checks(checks, false), do: checks

  defp checks_param(params) do
    case Slipdock.Verified.Checks.parse(Map.get(params, "checks")) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # The handbook's rules for the card's tree, for the severity of each rule
  # a verdict names; none without a handbook.
  defp handbook_rules(card) do
    case card |> board() |> Slipdock.Handbook.find() do
      nil -> []
      handbook -> Slipdock.Handbook.Rules.rules(handbook)
    end
  end

  # A decision made in a runner job on this card (#1666) is the runner's:
  # the CLI or MCP token is the same one the builder and interactive
  # sessions use, so its label can't say who decided. The job must be on
  # this card and have a runner, so a header naming some other job credits
  # nothing.
  defp in_runner_job(actor, %Card{id: card_id}) do
    a = actor_map(actor) || %{}

    with id when is_integer(id) <- a["job_id"],
         %Slipdock.Runners.Job{card_id: ^card_id, runner_id: rid} when is_integer(rid) <-
           Repo.get(Slipdock.Runners.Job, id),
         %Slipdock.Runners.Runner{name: name} <- Repo.get(Slipdock.Runners.Runner, rid) do
      Slipdock.Actor.runner(a["user_id"], id, name)
    else
      _ -> actor
    end
  end

  defp apply_decision(
         card,
         "accept",
         %{reason: note, commit: commit, checks: checks},
         actor,
         user
       ) do
    cond do
      not Board.ships_by_pr?(board(card)) ->
        accept_and_complete(card, note, commit, checks, actor, user)

      no_code?(card) ->
        # Nothing was committed, so there is nothing to merge (#1938).
        accept_and_complete(card, note, commit, checks, actor, user, @no_code_accepted)

      nothing_to_merge?(card) ->
        # An epic whose subcards merged their own pull requests (#1917).
        accept_and_complete(card, note, commit, checks, actor, user, @nothing_to_merge)

      true ->
        accept_or_hold(card, note, commit, checks, actor, user)
    end
  end

  defp apply_decision(
         card,
         "reject",
         %{reason: reason, commit: commit, checks: checks},
         actor,
         user
       ) do
    changes = [
      verify_checks: checks,
      verify_state: "rejected",
      verify_by: actor_map(actor),
      verify_note: reason,
      verify_commit: blank_to_nil(commit),
      verify_at: now(),
      verify_rejections: (card.verify_rejections || 0) + 1
    ]

    count = (card.verify_rejections || 0) + 1
    limit = rejection_limit(card)
    # Over the limit (#1779), a person decides: the evidence stays for an
    # acceptance as is, and a wait holds the card out of the feed.
    over = limit > 0 and count > limit
    attrs = if over, do: %{}, else: no_evidence()

    with {:ok, card} <-
           Slipdock.Boards.update_card(
             card,
             Map.put(attrs, "flags", rejected_flags(card.flags, count)),
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      by = who(actor, user)
      # The rejected work's log, and the verifier's, keep the failure time (#1872).
      Slipdock.Runners.TranscriptRetention.card_failed(card)
      comment(card, "**Rejected** by #{by}.", with_parts(reason, checks), user)
      Slipdock.Findings.Signals.rejected(card, reason, checks, actor)
      Circling.after_rejection(card, count, rejection_comments(card), user)
      if over, do: ask_a_person(card, count, limit, actor, user)
      send_back(card, "Rework: rejected by #{by}, reason under Verification", actor, user)
    end
    |> api_error()
  end

  # A rejection takes the `review` flag off, except from a card going round
  # in circles (#2047): from the second on, it stays until it is accepted.
  defp rejected_flags(flags, count) do
    if count >= Circling.threshold(),
      do: Enum.uniq(flags ++ ["review"]),
      else: flags -- ["review"]
  end

  ## Repeated rejections (#1779) ----------------------------------------------

  @limit_purpose "verify_limit"
  # The human tier's wait (#1952), below.
  @held_purpose "before_merge"
  @merge_choice "Merge"
  @send_back_choice "Send back"
  @rework_choice "Rework as rejected"
  @accept_choice "Accept as is"

  @doc """
  How many rejections a card on `card`'s tree may have before the next goes
  to a person (#1779): its root board's `verify_rejection_limit`. 0 is no
  limit.
  """
  def rejection_limit(%Card{} = card) do
    board = board(card)
    root = if board.root_id, do: Repo.get(Board, board.root_id) || board, else: board
    root.verify_rejection_limit || 0
  end

  # The rejection over the limit: the reasons so far as a comment, then a
  # wait on the board's owner to rework the card as rejected or accept it.
  defp ask_a_person(card, count, limit, actor, user) do
    rejections = rejection_comments(card)

    reasons =
      rejections
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{reason, failed}, n} ->
        "#{n}. #{reason}" <>
          if(failed == [], do: "", else: " (failed: #{Enum.join(failed, ", ")})")
      end)

    comment(
      card,
      "**Rejected #{count} times**, past the board's limit of #{limit}: a person decides now.",
      "The reasons so far:\n\n" <> reasons <> "\n\n" <> approach_line(rejections),
      user
    )

    # A release question (#1949): on the first person the tree routes
    # `release` to, else on the owner (`Slipdock.WaitRoutes`).
    case Slipdock.Boards.open_wait(card, actor, %{
           needs: limit_question(card, count, limit, rejections),
           choices: [@rework_choice, @accept_choice],
           question: "release",
           purpose: @limit_purpose
         }) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        comment(
          card,
          "**No wait opened** for a person to decide: #{inspect_error(why)}",
          nil,
          user
        )
    end
  end

  defp inspect_error(why) when is_binary(why), do: why
  defp inspect_error(why), do: inspect(why)

  # Each rejection's reason, oldest first, from the cards' own comments.
  defp rejection_reasons(card), do: card |> rejection_comments() |> Enum.map(&elem(&1, 0))

  # Each rejection, oldest first, as `{reason, failing parts}`: the parts
  # from its comment's `Checks:` block, else the ones its reason cites.
  defp rejection_comments(%Card{id: id}) do
    from(c in Slipdock.Boards.Comment,
      where: c.card_id == ^id and like(c.body, "**Rejected** by%"),
      order_by: [asc: c.id],
      select: c.body
    )
    |> Repo.all()
    |> Enum.map(fn body ->
      [reason | checks] =
        body
        |> String.split("\n\n", parts: 2)
        |> Enum.at(1, "(no reason given)")
        |> String.split("\n\nChecks:", parts: 2)

      failed =
        case checks do
          [lines] ->
            failing_labels(lines)

          [] ->
            reason |> Slipdock.Verified.Checks.from_reason() |> Slipdock.Verified.Checks.failing()
        end

      {reason |> String.replace(~r/\s+/, " ") |> String.slice(0, 400), failed}
    end)
  end

  # The failing parts of a decision comment's `Checks:` lines
  # (`- bar 2: fail — why`), by label.
  defp failing_labels(lines) do
    for line <- String.split(lines, "\n"),
        [_, label, result] <- [Regex.run(~r/^\s*-\s+(.+?):\s+(.+?)(?:\s+—\s.*)?\s*$/u, line)],
        Slipdock.Verified.Checks.failing_result?(result),
        do: label |> String.replace(~r/ (must|should)$/, "")
  end

  # Past the rejection limit (#1945): the round cap's question. The parts
  # that failed each time, and that the approach, not the fix, may be wrong.
  defp approach_line(rejections) do
    again =
      rejections
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    lead =
      if again == [],
        do: "Each round failed on something else.",
        else: "#{Enum.join(again, ", ")} failed more than once."

    lead <>
      " The approach may be wrong, not the fix: before another round of fixes, " <>
      "decide whether the card needs a different approach, a reworded bar, or accepting as is."
  end

  @limit_needs_cap 990
  defp limit_question(card, count, limit, rejections) do
    rounds =
      rejections
      |> Enum.with_index(1)
      |> Enum.map_join("; ", fn {{_, failed}, n} ->
        "#{n}. " <> if(failed == [], do: "(no part named)", else: Enum.join(failed, ", "))
      end)

    head = "Card ##{card.id} was rejected #{count} times (the board allows #{limit}). "

    tail =
      " The approach may be wrong, not the fix: rework it as rejected (rewording the bar or " <>
        "the card first if the approach should change), or accept it as is? The reasons are " <>
        "in the comments; you can edit the bar before you answer."

    room = @limit_needs_cap - String.length(head) - String.length(tail) - 30

    rounds =
      if String.length(rounds) > room, do: String.slice(rounds, 0, room) <> "…", else: rounds

    head <> "Failed each time: " <> rounds <> "." <> tail
  end

  @doc """
  A wait closing (`Slipdock.Boards.answer_wait/3`): a rejection-limit wait
  (#1779) answered *Accept as is* accepts the card for whoever answered (on
  a pull request board, queueing the merge); any other answer, or a skip,
  sends it back for rework as rejected, its evidence cleared. Other waits
  are left alone.
  """
  def wait_closed(%Slipdock.Boards.Wait{purpose: @limit_purpose} = wait, actor) do
    card = Repo.get!(Card, wait.card_id)
    user = wait.closed_by_id && Repo.get(Slipdock.Accounts.User, wait.closed_by_id)

    if card.verify_state == "rejected" do
      if wait.choice == 2,
        do: accept_as_is(card, actor, user),
        else: rework_as_rejected(card, actor, user)
    end

    :ok
  end

  def wait_closed(%Slipdock.Boards.Wait{purpose: @held_purpose} = wait, actor),
    do: held_wait_closed(wait, actor)

  def wait_closed(_wait, _actor), do: :ok

  defp accept_as_is(card, actor, user) do
    note = "Accepted as is by #{who(actor, user)} after #{card.verify_rejections} rejections."

    apply_decision(
      card,
      "accept",
      %{reason: note, commit: card.evidence_commit || "", checks: nil},
      actor,
      user
    )
  end

  defp rework_as_rejected(card, actor, user) do
    {:ok, _} = Slipdock.Boards.update_card(card, no_evidence(), actor: actor, by: user)
    Slipdock.Automations.feed_board(card.board_id)
  end

  defp accept_and_complete(card, note, commit, checks, actor, user, why \\ nil) do
    changes = [
      verify_checks: checks,
      verify_state: "accepted",
      verify_by: actor_map(actor),
      verify_note: blank_to_nil(note),
      verify_commit: blank_to_nil(commit),
      verify_at: now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(
             card,
             %{"completed" => true, "flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      line = "**Accepted** by #{who(actor, user)}" <> if(why, do: "; #{why}.", else: ".")
      comment(card, line, with_parts(note, checks), user)
      done = card |> board() |> Repo.preload(:columns) |> Map.get(:columns) |> done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.move_card(card.id, done.id, nil, actor: actor)

      card = Repo.get!(Card, card.id)
      maybe_audit(card)
      {:ok, card}
    end
    |> api_error()
  end

  # Back to the top of the ready list for rework (#1659), after a rejection
  # or a failed merge (#1657): the handoff points at the reason, the
  # builder's own assignment comes off and the board's feed runs.
  defp send_back(card, next_step, actor, user) do
    # The reason is on the comment and the verification block (and in a
    # claimed job's prompt and get_card): the handoff only points there.
    Slipdock.Boards.leave_handoff(card, user, %{next_step: next_step, via: handoff_via(actor)})

    # The builder's own assignment comes off (a person's stays), so a rule
    # that sends only unassigned cards sends it again.
    card = unassign_agents(Repo.get!(Card, card.id), actor, user)

    # Back to the top of the ready list, to be taken up again.
    columns = card |> board() |> Repo.preload(:columns) |> Map.get(:columns)

    case Slipdock.Flow.ready_list(columns) do
      %Column{id: id} = ready when id != card.column_id ->
        Slipdock.Boards.move_card_to_index(card, ready, :top, actor: actor)

      _ ->
        :ok
    end

    # A rejection is new information: the card isn't cooling, so the
    # board's feed can send it next.
    Slipdock.Automations.feed_board(card.board_id)

    {:ok, Repo.get!(Card, card.id)}
  end

  ## The human tier (#1952) -----------------------------------------------------

  @doc "The purpose of the wait a held card's acceptance opens (#1952)."
  def held_purpose, do: @held_purpose

  @doc "The `purpose` of the wait a card over its rejection limit opens."
  def limit_purpose, do: @limit_purpose

  @doc """
  Whether an agent's acceptance of `card` waits for a person before its
  pull request merges (#1952): an agent decided, and the card's human tier
  (`Slipdock.Profiles.tier/1`) is `before_merge`. A person's acceptance is
  a person's look already.
  """
  def hold_for_a_person?(%Card{} = card, actor),
    do: (gated?(actor) or server?(actor)) and Slipdock.Profiles.tier(card) == "before_merge"

  ## The verifier's spend (#1953) ----------------------------------------------

  @unverified_profiles ~w(docs)
  @server_agent "the server"

  @doc """
  Whether a card just submitted for verification goes unverified (#1953):
  its board has profiles on and its profile (set, else inferred) is one of
  `unverified_profiles/0`. No verify job is queued; the server accepts it
  itself (`accept_unverified/2`). The bar is still required and locked.
  """
  def not_verified?(%Card{} = card),
    do:
      board(card).profiles == true and
        Enum.member?(@unverified_profiles, Slipdock.Profiles.profile_of(card))

  @doc "The profiles whose cards no verify job checks: `docs`."
  def unverified_profiles, do: @unverified_profiles

  @doc """
  The actor the server accepts an unverified card as (#1953): not a person,
  so a `before_merge` tier still holds it, and not an agent, so no audit
  samples it.
  """
  def server_actor, do: %{Slipdock.Actor.automation() | agent: @server_agent}

  defp server?(actor),
    do: match?(%{"kind" => "automation", "agent" => @server_agent}, actor_map(actor))

  # The server's acceptance of a card no verifier checks: the suite is CI's
  # result as the evidence gives it, and a failing one sends it back.
  defp accept_unverified(%Card{} = card, user) do
    card = Repo.get!(Card, card.id)
    profile = Slipdock.Profiles.profile_of(card)
    suite = suite_part(card.evidence_suite)
    checks = Map.merge(%{"not_verified" => profile}, suite)

    {decision, reason} =
      if Slipdock.Verified.Checks.failing(suite) == [],
        do: {"accept", "profile #{profile}: not verified (no verify job runs for it)"},
        else:
          {"reject",
           "the suite: #{suite["suite"]["failed"]} failed. A #{profile} card is accepted " <>
             "unverified only on a passing suite: fix it and complete it again"}

    with {:error, _, message} <-
           apply_decision(
             card,
             decision,
             %{reason: reason, commit: card.evidence_commit || "", checks: checks},
             server_actor(),
             user
           )
           |> unverified_result() do
      comment(
        card,
        "**Not accepted** (profile #{profile}, not verified): #{message}. A person accepts it " <>
          "with `slipdock verify #{card.id} accept`.",
        nil,
        user
      )
    end
  end

  defp unverified_result({:ok, _}), do: :ok
  defp unverified_result({:error, %Ecto.Changeset{} = cs}), do: {:error, 422, inspect(cs.errors)}
  defp unverified_result({:error, status, message}), do: {:error, status, message}
  defp unverified_result(other), do: {:error, 500, inspect(other)}

  # The evidence's suite (`{result, passed, failed}`) as a verdict's part.
  defp suite_part(%{} = suite) do
    passed = suite["passed"] || suite[:passed]
    failed = suite["failed"] || suite[:failed]
    result = to_string(suite["result"] || suite[:result])

    cond do
      is_integer(passed) and is_integer(failed) ->
        %{"suite" => %{"passed" => passed, "failed" => failed}}

      result == "failed" ->
        %{"suite" => %{"passed" => 0, "failed" => 1}}

      true ->
        %{}
    end
  end

  defp suite_part(_suite), do: %{}

  # Accepted on a board that ships by pull request: merging, or held for a
  # person first when its tier says so.
  defp accept_or_hold(card, note, commit, checks, actor, user) do
    if hold_for_a_person?(card, actor),
      do: hold(card, note, commit, checks, actor, user),
      else: accept_to_merge(card, note, commit, checks, actor, user)
  end

  # Accepted, held (#1952): no merge job yet, the `review` flag kept (it
  # behaves as a card awaiting verification), and a wait routed `release`
  # asking a person to merge it or send it back.
  defp hold(card, note, commit, checks, actor, user) do
    changes = [
      verify_checks: checks,
      verify_state: "held",
      verify_by: actor_map(actor),
      verify_note: blank_to_nil(note),
      verify_commit: blank_to_nil(commit),
      verify_at: now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, %{}, actor: actor, by: user, verify_changes: changes) do
      profile = Slipdock.Profiles.profile_of(card)

      comment(
        card,
        "**Accepted** by #{who(actor, user)}; held for a person before merging: " <>
          "its profile is `#{profile}`, whose human tier is `before_merge`.",
        with_parts(note, checks),
        user
      )

      ask_to_merge(card, profile, actor, user)
      {:ok, Repo.get!(Card, card.id)}
    end
    |> api_error()
  end

  defp ask_to_merge(card, profile, actor, user) do
    needs =
      "Card ##{card.id} (profile #{profile}) was accepted by #{who(actor, user)}. Its human " <>
        "tier is before_merge, so a person decides before " <>
        "#{card.evidence_pr || "its pull request"} merges: merge it, or send it back " <>
        "(say why: the reason goes back to the builder)?"

    case Slipdock.Boards.open_wait(card, actor, %{
           needs: String.slice(needs, 0, 990),
           choices: [@merge_choice, @send_back_choice],
           question: "release",
           purpose: @held_purpose
         }) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        comment(
          card,
          "**No wait opened** for a person to decide: #{inspect_error(why)}. A person merges " <>
            "it with `slipdock verify #{card.id} accept`, or sends it back with `reject`.",
          nil,
          user
        )
    end
  end

  @doc """
  Whether `actor` may answer or skip `wait` (#1952): a held card's wait is
  a person's to answer, never an agent's. `:ok` or `{:error, message}`.
  """
  def may_close_wait(%Slipdock.Boards.Wait{purpose: @held_purpose, card_id: id}, actor) do
    if gated?(actor),
      do:
        {:error,
         "a person decides whether card ##{id} merges (its human tier is before_merge): " <>
           "an agent can't answer this wait"},
      else: :ok
  end

  def may_close_wait(_wait, _actor), do: :ok

  # A held card's wait answered (#1952): Merge queues the merge; Send back,
  # any other answer or a skip sends it back rejected, the answer the reason.
  defp held_wait_closed(wait, actor) do
    card = Repo.get!(Card, wait.card_id)
    user = wait.closed_by_id && Repo.get(Slipdock.Accounts.User, wait.closed_by_id)

    if card.verify_state == "held" and not card.completed do
      if wait.choice == 1,
        do: approve_merge(card, actor, user),
        else: send_back_held(card, wait.answer, actor, user)
    end

    :ok
  end

  # A person's decision on a held card with `slipdock verify`, REST, MCP or
  # the panel: accept merges, reject sends it back. Its open wait, if any,
  # is withdrawn, as the decision answers it.
  defp held_decision(card, decision, reason, actor, user) do
    cond do
      gated?(actor) ->
        {:error, :forbidden,
         "card ##{card.id} is held for a person: its human tier is before_merge, " <>
           "so a person merges it or sends it back"}

      decision == "reject" and reason == "" ->
        {:error, :unprocessable_entity, "sending it back needs its reason"}

      true ->
        withdraw_held_wait(card, actor)
        card = Repo.get!(Card, card.id)

        if decision == "accept",
          do: approve_merge(card, actor, user),
          else: send_back_held(card, reason, actor, user)
    end
  end

  defp withdraw_held_wait(card, actor) do
    case Slipdock.Boards.current_wait(card) do
      %{purpose: @held_purpose} ->
        Slipdock.Boards.withdraw_wait(card, actor,
          note: "Decided on the card, so the wait is closed."
        )

      _ ->
        :ok
    end
  end

  # Merge: the card is merging and its merge job queued, as an acceptance
  # without the tier does.
  defp approve_merge(card, actor, user) do
    with {:ok, card} <-
           Slipdock.Boards.update_card(card, %{"flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: [verify_state: "merging"]
           ) do
      comment(
        card,
        "**Merge approved** by #{who(actor, user)}; merging " <>
          "#{card.evidence_pr || "its pull request"}.",
        nil,
        user
      )

      queue_merge(card, user)
      {:ok, Repo.get!(Card, card.id)}
    end
    |> api_error()
  end

  # Send back: rejected, the person's reason the failing part (the ask, as
  # the person judged it), and back to the ready list as any rejection.
  defp send_back_held(card, reason, actor, user) do
    reason =
      case blank_to_nil(reason) do
        nil -> "sent back before merging by #{who(actor, user)}, with no reason given"
        why -> why
      end

    {:ok, checks} = Slipdock.Verified.Checks.parse(["ask=misses:" <> one_line(reason)])

    apply_decision(
      card,
      "reject",
      %{reason: "Sent back before merging: " <> reason, commit: "", checks: checks},
      actor,
      user
    )
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 500)

  ## Merging (#1657) ------------------------------------------------------------

  @merge_kind "merge"

  @doc "The job kind that merges an accepted card's pull request (#1656, #1657)."
  def merge_kind, do: @merge_kind

  # Accepted on a board that ships by pull request: the card waits, merging,
  # while a runner merges its pull request; the merge finishing completes it.
  defp accept_to_merge(card, note, commit, checks, actor, user) do
    changes = [
      verify_checks: checks,
      verify_state: "merging",
      verify_by: actor_map(actor),
      verify_note: blank_to_nil(note),
      verify_commit: blank_to_nil(commit),
      verify_at: now()
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, %{"flags" => card.flags -- ["review"]},
             actor: actor,
             by: user,
             verify_changes: changes
           ) do
      comment(
        card,
        "**Accepted** by #{who(actor, user)}; merging #{card.evidence_pr || "its pull request"}.",
        with_parts(note, checks),
        user
      )

      queue_merge(card, user, decider: decider_runner(actor))
      {:ok, Repo.get!(Card, card.id)}
    end
    |> api_error()
  end

  @doc """
  Queues the merge job for a card being merged (#1657), with no setting, to
  the pool `merge_pool/2` picks (`opts` go to it). With none, nothing is
  queued and the card says what to do. `{:ok, job}` or `:none`.
  """
  def queue_merge(%Card{} = card, user \\ nil, opts \\ []) do
    case merge_pool(card, opts) do
      nil ->
        Slipdock.Boards.add_comment(card, no_merger_text(card), by: user)
        :none

      pool ->
        case Slipdock.Runners.queue(card, %{
               pool: pool,
               kind: @merge_kind,
               prompt: merge_prompt(card),
               exclude_runner_id: opts[:exclude]
             }) do
          {:ok, job} ->
            {:ok, job}

          {:error, reason} ->
            Slipdock.Boards.add_comment(
              card,
              "**Merge job not queued** for pool `#{pool}`: #{reason}. " <>
                merge_by_hand_text(card),
              by: user
            )

            :none
        end
    end
  end

  @doc """
  The pool a card's merge job goes to (see `queue_merge/3`), or nil. Of the
  runners on the tree that take merge jobs, the first that applies (#1754):

    * one idle now (`Slipdock.Runners.idle?/1`), the builder's pool first:
      the merge goes at once, rather than waiting for a pass to end;
    * the runner that decided the card (`decider:`), about to finish its
      verify job;
    * the pool of the runner that built the card, else the most recently
      seen pool.

  `exclude:` leaves out a runner that couldn't merge here.
  """
  def merge_pool(%Card{} = card, opts \\ []) do
    import Ecto.Query
    alias Slipdock.Runners.Runner

    root = Board.root_id(board(card))

    capable =
      from(r in Runner,
        where: r.board_id == ^root and fragment("'merge' = ANY(?)", r.kinds),
        order_by: [desc_nulls_last: r.last_seen_at, asc: r.id]
      )
      |> Repo.all()
      |> Enum.reject(&(&1.id == opts[:exclude]))

    builder_pool =
      case builder_runner_id(card) do
        id when is_integer(id) -> Repo.one(from(r in Runner, where: r.id == ^id, select: r.pool))
        _ -> nil
      end

    pools = Enum.map(capable, & &1.pool)
    idle = for r <- capable, Slipdock.Runners.idle?(r), do: r.pool
    decider = Enum.find(capable, &(&1.id == opts[:decider]))

    cond do
      builder_pool && builder_pool in idle -> builder_pool
      idle != [] -> hd(idle)
      decider -> decider.pool
      builder_pool && builder_pool in pools -> builder_pool
      true -> List.first(pools)
    end
  end

  # The runner whose job made a decision, if one did (#1666): it is about
  # to finish that job, so it can take the merge next (#1754).
  defp decider_runner(actor) do
    import Ecto.Query

    case actor_map(actor) do
      %{"job_id" => id} when is_integer(id) ->
        Repo.one(from(j in Slipdock.Runners.Job, where: j.id == ^id, select: j.runner_id))

      _ ->
        nil
    end
  end

  @doc """
  Where a card being merged stands (#1657): `:queued` or `:running` while a
  merge job is open on it, nil when it isn't merging. With none open, its
  last merge job since the acceptance says why (#2646): `:already_merged`
  when that job found the pull request merged at another head (#2637),
  `:waiting` when its runner couldn't merge here and no other runner took
  it on (#1754), and `:none` when nothing will merge it (no runner can).
  """
  def merge_status(%Card{verify_state: "merging"} = card) do
    import Ecto.Query

    case Repo.one(
           from(j in Slipdock.Runners.Job,
             where:
               j.card_id == ^card.id and j.kind == @merge_kind and
                 j.status in ^Slipdock.Runners.Job.open_statuses(),
             order_by: [desc: j.id],
             limit: 1,
             select: j.status
           )
         ) do
      nil -> last_merge_outcome(card)
      "queued" -> :queued
      _ -> :running
    end
  end

  def merge_status(_card), do: nil

  # Why a merging card has no merge job open (#2646): its last merge job
  # since the acceptance, read the way merge_finished/2 read it.
  defp last_merge_outcome(card) do
    import Ecto.Query

    query =
      from(j in Slipdock.Runners.Job,
        where: j.card_id == ^card.id and j.kind == @merge_kind,
        order_by: [desc: j.id],
        limit: 1
      )

    query =
      if card.verify_at, do: where(query, [j], j.inserted_at >= ^card.verify_at), else: query

    job = Repo.one(query)

    cond do
      is_nil(job) -> :none
      already_merged?(job) -> :already_merged
      runner_refused?(job) -> :waiting
      true -> :none
    end
  end

  defp merge_prompt(card) do
    "Merge the pull request of card ##{card.id}: #{card.evidence_pr} at the accepted commit " <>
      "#{card.verify_commit || card.evidence_commit}. The runner's built-in merge kind does this."
  end

  defp no_merger_text(card) do
    "**No runner can merge this.** None of this board's runners takes merge jobs: a " <>
      "machine's runner says it does on each claim unless its machine turns the built-in " <>
      "merge off (`no_merge` in the machine's own file). " <>
      merge_by_hand_text(card)
  end

  defp merge_by_hand_text(card) do
    "Or merge #{card.evidence_pr || "the pull request"} yourself and press **Merged it myself** " <>
      "on the card (`slipdock verify #{card.id} merged`)."
  end

  @doc """
  A merge job has ended (#1657), called by `Slipdock.Runners` for kind
  merge. Done: the card completes, with the merge commit as `merge_sha`,
  and moves to the done list (a pull request the runner found already
  merged at the accepted commit too, #2637). A runner that couldn't merge
  here (not the pull request's repository, no git or gh, gh signed out)
  hands it on to another runner (#1754): the card's work isn't at fault.
  One the runner found already merged at another head (or, from an older
  runner, merged at a head it didn't say) stays merging for a person, with
  a comment, and isn't a rejection (#2637). Anything else: it
  goes back to the top of the ready list as rejected, the merge's reason as
  the rejection's, so the builder rebases and submits it again. A card no
  longer merging is left alone.
  """
  def merge_finished(%Slipdock.Runners.Job{kind: @merge_kind} = job, runner_name) do
    case Repo.get(Card, job.card_id) do
      %Card{verify_state: "merging", completed: false} = card ->
        actor = Slipdock.Actor.runner(nil, job.id, runner_name)

        cond do
          job.status == "done" ->
            complete_merged(card, job.merged_sha, actor, nil, merged_line(job, runner_name))

          runner_refused?(job) ->
            hand_on(card, job, runner_name)

          already_merged?(job) ->
            merged_elsewhere(card, job, runner_name)

          true ->
            merge_failed(card, job, actor)
        end

      _ ->
        :ok
    end
  end

  def merge_finished(_job, _runner_name), do: :ok

  # The runner's words for a pull request it found already merged at the
  # accepted commit (#2637): the merge the job wanted, so the card completes.
  defp merged_line(job, runner_name) do
    if String.contains?(merge_reason(job), "was already merged at the accepted commit"),
      do:
        "**Merged** by runner #{runner_name}: the pull request was already merged at the " <>
          "accepted commit",
      else: "**Merged** by runner #{runner_name}"
  end

  # A merge that failed because the pull request was already merged (#2637):
  # at another head (the daemon's words), or at a head the runner didn't say
  # (older runners: `is MERGED, not open`).
  defp already_merged?(%{status: "failed"} = job) do
    said = merge_reason(job)

    String.starts_with?(said, "merge: ") and
      (String.contains?(said, "was already merged at head") or
         String.contains?(said, "is MERGED, not open"))
  end

  defp already_merged?(_job), do: false

  # Already merged, but not at a head the runner could match to the
  # accepted commit: no rebase or resubmission changes a merged pull
  # request, so the card isn't sent back or counted as rejected (in quality
  # or circling). It stays merging, and the comment says which head was
  # merged, for a person to look at and mark merged by hand.
  defp merged_elsewhere(card, job, runner_name) do
    said = merge_reason(job)
    Slipdock.Findings.Signals.merge_failed(card, job, said)

    Slipdock.Boards.add_comment(
      card,
      "**Merge failed: already merged.** Runner #{runner_name} found " <>
        "#{card.evidence_pr || "the pull request"} merged already, but not at a head it " <>
        "could match to the accepted commit `#{card.verify_commit || card.evidence_commit}`. " <>
        "Nothing was merged, and it doesn't count as a rejection. Check what was merged; if " <>
        "it is the accepted work, press **Merged it myself** on the card " <>
        "(`slipdock verify #{card.id} merged`).\n\n#{said}"
    )

    :ok
  end

  # What a runner's built-in merge says, before touching anything, when the
  # runner itself can't merge (exit 2): the card isn't at fault, so another
  # runner may merge it. (The first wording is the retired shell runners'
  # as well as the daemon's.)
  @runner_refusals [
    "but this runner's repository is",
    "has no origin remote",
    "git is not installed",
    "gh (GitHub CLI) is not installed",
    "gh is not signed in"
  ]

  # How many runners an acceptance's merge is handed to before the card
  # waits for a person.
  @merge_hand_ons 2

  defp runner_refused?(%{status: "failed"} = job) do
    said = merge_reason(job)

    String.starts_with?(said, "merge: ") and
      Enum.any?(@runner_refusals, &String.contains?(said, &1))
  end

  defp runner_refused?(_job), do: false

  # A runner that can't merge here hands the merge on, leaving that runner
  # out (#1754). Past @merge_hand_ons, or with no other runner, the card
  # stays merging with nothing queued and says why.
  defp hand_on(card, job, runner_name) do
    import Ecto.Query

    said = merge_reason(job)

    refused =
      from(j in Slipdock.Runners.Job,
        where:
          j.card_id == ^card.id and j.kind == @merge_kind and j.status == "failed" and
            j.inserted_at >= ^card.verify_at
      )
      |> Repo.all()
      |> Enum.count(&runner_refused?/1)

    pool = refused <= @merge_hand_ons && merge_pool(card, exclude: job.runner_id)
    queued = pool && queue_merge(card, nil, exclude: job.runner_id)

    case queued do
      {:ok, _job} ->
        Slipdock.Boards.add_comment(
          card,
          "**Merge handed on.** Runner #{runner_name} can't merge here, so pool `#{pool}` " <>
            "has it now.\n\n#{said}"
        )

      _ ->
        Slipdock.Boards.add_comment(
          card,
          "**Merge waiting.** Runner #{runner_name} can't merge here, and no other runner " <>
            "has taken it on. Fix the runner, or: " <> merge_by_hand_text(card) <> "\n\n#{said}"
        )
    end

    :ok
  end

  defp merge_failed(card, job, actor) do
    said = merge_reason(job)
    reason = "Merge failed (job ##{job.id}, #{job.status}): " <> said

    changes = [
      verify_state: "rejected",
      verify_note: reason,
      verify_at: now(),
      verify_rejections: (card.verify_rejections || 0) + 1
    ]

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, no_evidence(),
             actor: actor,
             verify_changes: changes
           ) do
      Slipdock.Runners.TranscriptRetention.card_failed(card)
      comment(card, merge_failed_line(card, said), reason, nil)
      Slipdock.Findings.Signals.merge_failed(card, job, said)

      send_back(card, "Rework: the merge failed, reason under Verification", actor, nil)
    end
  end

  # What to do about a failed merge (#1666): a rebase only helps when the
  # branch conflicts with the default branch or its head moved; anything
  # else (gh signed out, the wrong repository, a closed pull request, a
  # failing check) is fixed where the reason says.
  defp merge_failed_line(card, said) do
    if rebase_fixes?(said),
      do:
        "**Merge failed.** It conflicts or its head moved: rebase `#{pr_branch(card)}` " <>
          "on the default branch and submit it again.",
      else:
        "**Merge failed.** The merge job's reason is below, and a rebase won't fix it: " <>
          "fix what it says, then submit the card again."
  end

  @doc """
  Whether a failed merge's reason (the merge job's own words) is one a
  rebase fixes (#1666): a conflict, or a head that moved after acceptance.
  """
  def rebase_fixes?(said) when is_binary(said) do
    Regex.match?(
      ~r/conflict|not mergeable|cannot be cleanly created|head branch was modified|it moved after|not the accepted commit|is not up to date|behind the base/i,
      said
    )
  end

  def rebase_fixes?(_), do: false

  # The runner's own words: its last `merge:` line, else the output's last line.
  defp merge_reason(job) do
    lines = (job.output || job.log_tail || "") |> String.split(~r/\R/, trim: true)

    (Enum.find(Enum.reverse(lines), &String.starts_with?(&1, "merge:")) || List.last(lines) ||
       "the merge job ended #{job.status}")
    |> String.slice(0, 1000)
  end

  # A person saying they merged it themselves (#1657): only on a card being
  # merged, and only a person.
  defp merged_by_hand(card, commit, actor, user) do
    cond do
      card.verify_state != "merging" ->
        {:error, :conflict, "card ##{card.id} isn't waiting for its merge"}

      gated?(actor) ->
        {:error, :forbidden, "only a person marks a card merged by hand"}

      commit != "" and not Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, commit) ->
        {:error, :unprocessable_entity, "the merge commit must be a commit id"}

      true ->
        cancel_merge_jobs(card)

        complete_merged(
          card,
          blank_to_nil(commit),
          actor,
          user,
          "**Merged by hand** by #{who(actor, user)}"
        )
    end
  end

  defp complete_merged(card, sha, actor, user, line) do
    sha = sha && String.downcase(sha)

    with {:ok, card} <-
           Slipdock.Boards.update_card(card, %{"completed" => true},
             actor: actor,
             by: user,
             verify_changes: [verify_state: "accepted", merge_sha: sha]
           ) do
      comment(card, line <> if(sha, do: " as `#{sha}`.", else: "."), nil, user)
      done = card |> board() |> Repo.preload(:columns) |> Map.get(:columns) |> done_list()

      if done && done.id != card.column_id,
        do: Slipdock.Boards.move_card(card.id, done.id, nil, actor: actor)

      # Merged: an audit now can't hold anything up (#1780).
      card = Repo.get!(Card, card.id)
      maybe_audit(card)
      {:ok, card}
    end
    |> api_error()
  end

  defp cancel_merge_jobs(%Card{id: card_id}) do
    import Ecto.Query

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @merge_kind and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end

  defp unassign_agents(%Card{agent_assignee_ids: [_ | _] = ids} = card, actor, user) do
    on = Slipdock.Boards.assignee_ids(card)

    case Enum.filter(ids, &(&1 in on)) do
      [] ->
        card

      gone ->
        case Slipdock.Boards.update_card(card, %{"remove_assignee_ids" => gone},
               actor: actor,
               by: user
             ) do
          {:ok, card} -> card
          _ -> card
        end
    end
  end

  defp unassign_agents(card, _actor, _user), do: card

  @doc """
  The reason a rejected card was sent back with, and who rejected it, for
  the agent taking it up again (#1659): nil unless `card` is rejected.
  """
  def rejection(%Card{verify_state: "rejected", verify_note: note} = card)
      when is_binary(note) and note != "" do
    %{
      reason: note,
      by: who(card.verify_by),
      at: card.verify_at,
      rejections: card.verify_rejections || 0
    }
  end

  def rejection(_card), do: nil

  ## Audits (#1780) -------------------------------------------------------------

  @doc """
  How often `card`'s tree audits accepted work: its root board's
  `verify_audit`, 1 in N (0: never).
  """
  def audit_every(%Card{} = card) do
    board = board(card)
    root = if board.root_id, do: Repo.get(Board, board.root_id) || board, else: board
    root.verify_audit || 0
  end

  @doc """
  Whether card `card_id` is in the sample for 1 in `n`: a hash of its id,
  so about one card in `n` is, and the same card always answers the same.
  """
  def audit_sampled?(card_id, n) when is_integer(n) and n > 0,
    do: :erlang.phash2({:verify_audit, card_id}, n) == 0

  def audit_sampled?(_card_id, _n), do: false

  # A card an agent accepted (not a person), on a board with audits and a
  # verify pool, in the sample: queued for the verify pool as an audit,
  # never to the runner that built it or the one that verified it.
  defp maybe_audit(%Card{} = card) do
    board = board(card)
    n = audit_every(card)

    if board.verify_work and present?(board.verify_pool) and agent_decided?(card) and
         audit_sampled?(card.id, n) do
      builder = builder_runner_id(card)
      verifier = decider_runner(card.verify_by)

      Slipdock.Runners.queue(card, %{
        pool: board.verify_pool,
        kind: verify_kind(),
        audit: true,
        prompt: audit_prompt(card, board),
        exclude_runner_id: builder,
        exclude_runner_ids: Enum.uniq(Enum.reject([builder, verifier], &is_nil/1))
      })
    end

    :ok
  end

  defp agent_decided?(%Card{verify_by: %{"kind" => "agent", "via" => via}})
       when via != "assistant",
       do: true

  defp agent_decided?(_card), do: false

  @doc """
  What an audit job's agent is told (#1780): the verify prompt's checks, with
  every rule judged (`should` too), the original verdict shown, and a
  decision that only says whether it agrees.
  """
  def audit_prompt(%Card{} = card, %Board{} = board) do
    url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
    handbook = Slipdock.Handbook.find(board)
    judging = judge_steps(card, board, handbook, audit: true)
    decide = length(judging) + 3

    """
    Audit card ##{card.id} “#{card.title}” on #{board.name}: #{url}

    Another agent did the work, and a verifier accepted it. You are checking the checker: judge the work afresh, as the verifier should have, then say whether you agree with its verdict. You change nothing: not the code, not the card. Your decision is a comment, and the acceptance stands either way; a disagreement files a rework card from your reason and failing parts (or comments on the one still open), and raises an alert for the board's owner. So make the reason's first line say what is wrong: it is the rework card's title.

    The verdict you are auditing: accepted by #{who(card.verify_by)}#{if card.verify_at, do: " at #{card.verify_at}", else: ""}.
    #{original_verdict(card)}

    #{card_block(card, board, judging)}
    #{decide}. Say once whether you agree, and report it as a step first (`deciding: agree` or `deciding: disagree`):
       - `slipdock verify #{card.id} agree --reason "what you checked" --check ask=ok --check bar:1=ok …`
       - `slipdock verify #{card.id} disagree --reason "where the verdict is wrong, specifically" --check bar:2=fail:"why" …`
    Give your own verdict in parts, one `--check` each (MCP `verify_card` `checks`): `ask=ok|misses`, `bar:<n>=ok|fail`, `suite=<passed>:<failed>`#{if handbook, do: ", `rule:<id>=ok|broken|n/a|pre-existing:<file>:<line>`, `handbook_line=ok|disputed`", else: ""}#{if defect_review?(card, board), do: ", `defect:important|nit|pre-existing=<file>:<line>`", else: ""}#{if mutation_review?(card, board), do: ", `mutant:killed|survived|pre-existing=<file>:<line>:<mutation>`, `mutants=n/a:<why>`", else: ""}. Disagree when any part fails that the verdict passed (a missed `should` rule included), or when it failed a part that holds.
    """
  end

  defp original_verdict(%Card{} = card) do
    note = if blank?(card.verify_note), do: "(no reason given)", else: card.verify_note

    parts =
      card.verify_checks
      |> Slipdock.Verified.Checks.lines()
      |> Enum.map_join("\n", fn
        {label, result, nil} -> "- #{label}: #{result}"
        {label, result, why} -> "- #{label}: #{result} — #{why}"
      end)

    if parts == "",
      do: "Its reason: #{note}\n(It gave no parts.)",
      else: "Its reason: #{note}\nIts parts:\n#{parts}"
  end

  # An audit's say (#1780): a comment, and for a disagreement an alert for
  # the board's owner. Nothing on the card changes. It comes from an audit
  # job on the card, or a person; never from whoever accepted it.
  defp audit_decision(card, decision, params, reason, actor, user) do
    with :ok <- may_audit(card, actor),
         {:ok, checks} <- checks_param(params) do
      checks =
        checks |> Slipdock.Verified.Checks.with_severity(handbook_rules(card)) |> empty_nil()

      cond do
        decision == "disagree" and reason == "" ->
          {:error, :unprocessable_entity, "a disagreement needs its reason"}

        checks && Slipdock.Verified.Checks.carried_asks(checks) != [] ->
          # An audit judges every part afresh (#1944): nothing is carried.
          {:error, :unprocessable_entity,
           "an audit judges every part: give each a result of its own, not `carried`"}

        true ->
          record_audit(card, decision, reason, checks, actor, user)
      end
    end
  end

  defp empty_nil(checks) when checks == %{}, do: nil
  defp empty_nil(checks), do: checks

  defp may_audit(card, actor) do
    cond do
      card.verify_state != "accepted" ->
        {:error, :conflict,
         "card ##{card.id} hasn't been accepted: only accepted work is audited"}

      same_actor?(card.verify_by, actor) ->
        {:error, :forbidden, "you accepted card ##{card.id}: a different agent audits it"}

      gated?(actor) and not in_audit_job?(card, actor) ->
        {:error, :forbidden,
         "an agent audits card ##{card.id} only from its audit job (a person may at any time)"}

      true ->
        :ok
    end
  end

  defp in_audit_job?(%Card{id: card_id}, actor) do
    case actor_map(actor) do
      %{"job_id" => id} when is_integer(id) ->
        match?(
          %Slipdock.Runners.Job{card_id: ^card_id, audit: true},
          Repo.get(Slipdock.Runners.Job, id)
        )

      _ ->
        false
    end
  end

  # An audit alert's title, and what its body says of the rework (#2691).
  @audit_alert_lead "An audit disagrees with the acceptance of #"
  @clears_line " This alert clears itself once the rework is accepted or completed."

  defp record_audit(card, decision, reason, checks, actor, user) do
    by = who(actor, user)
    agrees = decision == "agree"

    line =
      if agrees,
        do: "**Audit: agrees** with the acceptance, by #{by}.",
        else: "**Audit: disagrees** with the acceptance, by #{by}."

    said = comment(card, line, with_parts(blank_to_nil(reason), checks), user)

    unless agrees do
      # The rework is filed with the disagreement (#2632), and the finding
      # and the alert name it.
      rework = file_rework(card, reason, checks, said, by, user)
      Slipdock.Findings.Signals.audit_disagreed(card, reason, actor, rework, checks)
      root = card |> board() |> Slipdock.Handbook.root()

      title = "#{@audit_alert_lead}#{card.id}"

      body =
        "#{by} audited “#{card.title}”, accepted by #{who(card.verify_by)}: " <>
          String.slice(reason, 0, 500) <> rework_line(rework)

      Slipdock.Automations.raise_alert(%{
        "board_id" => root.id,
        "card_id" => card.id,
        "severity" => "warning",
        "title" => title,
        "body" => body
      })

      # The people the tree routes release questions to hear of it (#1949).
      Slipdock.WaitRoutes.tell(card, "release", title, body)
    end

    {:ok, Repo.get!(Card, card.id)}
  end

  ## An audit's rework (#2632) --------------------------------------------------

  @rework_lead "An audit disagreed with the acceptance of #"

  @doc """
  The open rework card an audit filed for `card` (#2632): open, not
  archived, caused by `card`, and filed by an audit (its description starts
  with what `file_rework/6` writes). Nil when there is none.
  """
  def open_rework(%Card{id: id}) do
    lead = "#{@rework_lead}#{id} %"

    Repo.one(
      from c in Card,
        where:
          c.caused_by_id == ^id and is_nil(c.archived_at) and c.completed == false and
            like(c.description, ^lead),
        order_by: [desc: c.id],
        limit: 1
    )
  end

  @doc """
  Whether a disagreement's parts (#2632) make its rework urgent: a mutant
  that survived, or a `must` rule broken (a rule the handbook doesn't know
  counts as one).
  """
  def urgent_disagreement?(%{} = checks) do
    Enum.any?(Slipdock.Verified.Checks.mutants(checks), &(&1["result"] == "survived")) or
      Enum.any?(
        checks["rules"] || [],
        &(&1["result"] == "broken" and Enum.member?(["must", nil], &1["severity"]))
      )
  end

  def urgent_disagreement?(_checks), do: false

  @doc "A rework card's title (#2632): the audit's reason, after the card it reworks."
  def rework_title(%Card{id: id}, reason) do
    lead = "Audit of ##{id}: "

    first =
      reason
      |> to_string()
      |> String.split("\n", trim: true)
      |> List.first("")
      |> String.trim()

    room = 72 - String.length(lead)

    if String.length(first) > room,
      do: lead <> String.slice(first, 0, room - 1) <> "…",
      else: lead <> first
  end

  # A disagreement files the rework itself (#2632): one card on the accepted
  # card's board, caused by it (an incident, #1946), or a comment on the one
  # still open from an earlier disagreement. Nothing here may stop the audit
  # being recorded: a card that can't be made is logged, and the alert says
  # nothing of a rework.
  defp file_rework(card, reason, checks, said, by, user) do
    link = said_link(card, said)
    failed = rework_failed(checks)

    case open_rework(card) do
      %Card{} = rework ->
        body =
          "**Audit: disagrees again** with the acceptance of ##{card.id}, by #{by}: #{link}\n\n" <>
            reason <> failed

        Slipdock.Boards.add_comment(rework, body, by: user)
        {:commented, rework}

      nil ->
        new_rework(card, reason, checks, link, failed, by)
    end
  rescue
    e ->
      require Logger
      Logger.warning("audit rework not filed for ##{card.id}: #{Exception.message(e)}")
      nil
  end

  defp new_rework(card, reason, checks, link, failed, by) do
    board = card |> board() |> Repo.preload(:columns)
    columns = Enum.sort_by(board.columns, & &1.position)
    column = Slipdock.Flow.ready_list(columns) || List.first(columns)

    description =
      "#{@rework_lead}#{card.id} “#{card.title}” (accepted by #{who(card.verify_by)}): " <>
        "#{by} found it short after the merge. The audit: #{link}\n\n" <>
        "Its reason: #{reason}" <>
        failed <>
        "\n\nThe accepted card is done and stays done: the fix lands on this card. " <>
        "It names that card as its cause, so it counts as an incident (#1946)."

    attrs = %{
      "title" => rework_title(card, reason),
      "description" => description,
      "paths" => card.paths || [],
      "caused_by_id" => card.id,
      "priority" => if(urgent_disagreement?(checks), do: "high", else: "medium")
    }

    case Slipdock.Boards.create_card(column, attrs, actor: Slipdock.Actor.automation()) do
      {:ok, rework} ->
        {:filed, rework}

      {:error, error} ->
        require Logger
        Logger.warning("audit rework not filed for ##{card.id}: #{inspect(error)}")
        nil
    end
  end

  defp said_link(card, said) do
    url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{card.board_id}/cards/#{card.id}"

    case said do
      {:ok, %{id: id}} -> "#{url}#comment-#{id}"
      _ -> url
    end
  end

  defp rework_failed(checks) do
    case Slipdock.Verified.Checks.failing(checks || %{}) do
      [] ->
        ""

      parts ->
        "\n\nWhat failed:\n\n" <> Enum.map_join(parts, "\n", &"- #{&1}") <> parts_md(checks)
    end
  end

  defp parts_md(checks) do
    case Slipdock.Verified.Checks.markdown(checks) do
      "" -> ""
      md -> "\n\nThe audit's parts:\n\n" <> md
    end
  end

  defp rework_line({:filed, rework}),
    do: "\nRework filed: ##{rework.id} “#{rework.title}”." <> @clears_line

  defp rework_line({:commented, rework}),
    do: "\nRework already open: ##{rework.id} “#{rework.title}” (commented)." <> @clears_line

  defp rework_line(nil), do: ""

  @doc """
  Takes down the audit alerts that name `rework` (#2691), once it is
  accepted or completed: the alert each disagreement raised about the card
  it reworks, whether it filed the rework or commented on it (`Rework
  filed: #R` / `Rework already open: #R` in its body). An alert for another
  rework of the same card, one whose rework couldn't be filed, a rule's
  alert, and any card that isn't an audit's rework are left alone. One the owner dismissed
  already goes too, unseen. Returns how many went.
  """
  def clear_audit_alerts(%Card{id: id, caused_by_id: cause}) when is_integer(cause) do
    title = "#{@audit_alert_lead}#{cause}"
    filed = "%\nRework filed: ##{id} “%"
    open = "%\nRework already open: ##{id} “%"

    ids =
      Repo.all(
        from a in Slipdock.Automations.Alert,
          where: a.card_id == ^cause and a.title == ^title,
          where: is_nil(a.rule_id) and is_nil(a.user_id),
          where: like(a.body, ^filed) or like(a.body, ^open),
          select: a.id
      )

    Enum.each(ids, &Slipdock.Automations.delete_alert/1)
    length(ids)
  end

  def clear_audit_alerts(%Card{}), do: 0

  ## Verify jobs ---------------------------------------------------------------

  @verify_kind "verify"

  @doc "The job kind a pending card is queued as (#1634)."
  def verify_kind, do: @verify_kind

  @doc """
  The job kinds that finish a card's work rather than add to it: verifying
  and merging. Lanes and the WIP limit hold work jobs only (#1807): these
  edit nobody's files and put no more work in progress.
  """
  def finishing_kinds, do: [@verify_kind, @merge_kind]

  @doc """
  Queues a verify job again for a card still pending verification that has
  none open (the health monitor's `verify_missing`): to its board's verify
  pool, never to the runner that built it. `{:ok, job}` or `{:error, reason}`.
  """
  def requeue_verify(%Card{verify_state: "pending"} = card) do
    board = board(card)

    if board.verify_work and board.verify_pool do
      Slipdock.Runners.queue(card, %{
        pool: board.verify_pool,
        kind: @verify_kind,
        prompt: verify_prompt(card, board),
        exclude_runner_id: builder_runner_id(card)
      })
    else
      {:error, "the board has no verify pool"}
    end
  end

  def requeue_verify(%Card{}), do: {:error, "the card isn't pending verification"}

  defp queue_verify_job(%Card{} = card, user) do
    board = board(card)

    if board.verify_work and board.verify_pool do
      builder = builder_runner_id(card)

      case Slipdock.Runners.queue(card, %{
             pool: board.verify_pool,
             kind: @verify_kind,
             prompt: verify_prompt(card, board),
             exclude_runner_id: builder
           }) do
        {:ok, job} ->
          say_if_no_one_can_take(card, job, board, builder, user)

        {:error, reason} ->
          Slipdock.Boards.add_comment(
            card,
            "**Verify job not queued** for pool `#{board.verify_pool}`: #{reason}. " <>
              "It waits for someone to verify it by hand.",
            by: user
          )
      end
    end
  end

  # The runner that built the card (#1625): the one running the job the
  # submission came from, else the last one to take a job on the card.
  defp builder_runner_id(%Card{} = card) do
    import Ecto.Query
    alias Slipdock.Runners.Job

    from_job =
      case (card.verify_submitter || %{})["job_id"] do
        id when is_integer(id) ->
          Repo.one(from(j in Job, where: j.id == ^id, select: j.runner_id))

        _ ->
          nil
      end

    from_job ||
      Repo.one(
        from(j in Job,
          where: j.card_id == ^card.id and j.kind != @verify_kind and not is_nil(j.runner_id),
          order_by: [desc: j.id],
          limit: 1,
          select: j.runner_id
        )
      )
  end

  # A verify job no runner in its pool may take waits; the card says why.
  defp say_if_no_one_can_take(card, job, board, builder, user) do
    import Ecto.Query

    runners =
      Repo.all(
        from(r in Slipdock.Runners.Runner,
          where: r.board_id == ^Board.root_id(board) and r.pool == ^board.verify_pool,
          select: r.id
        )
      )

    why =
      cond do
        runners == [] ->
          "no runner is in pool `#{board.verify_pool}` yet"

        builder && runners == [builder] ->
          "the only runner in pool `#{board.verify_pool}` built this card, and a card's " <>
            "builder doesn't verify it"

        true ->
          nil
      end

    if why do
      Slipdock.Boards.add_comment(
        card,
        "**Verify job ##{job.id} waits:** #{why}. Add a runner to the pool, or verify it by hand.",
        by: user
      )
    end

    :ok
  end

  @doc """
  What a verify job's agent is told (#1634): the card, what it asks, its bar
  and evidence, and how to decide. Rendered when the job is queued.

  The verifier judges, in order (#1777): the ask (does the bar cover what
  the card asks for?), the bar, and on a board with a handbook the rules for
  the diff's paths and the closing `Handbook:` line. A rejection cites the
  check it fails: a bar item, the ask, a rule id or the Handbook line.
  """
  def verify_prompt(%Card{} = card, %Board{} = board) do
    url = "#{Slipdock.Automations.Runner.base_url()}/boards/#{board.id}/cards/#{card.id}"
    commit = card.evidence_commit
    at = if commit, do: " --evidence-commit #{commit}", else: ""
    handbook = Slipdock.Handbook.find(board)
    judging = judge_steps(card, board, handbook)
    decide = length(judging) + 3

    """
    Verify card ##{card.id} “#{card.title}” on #{board.name} before it counts as done: #{url}

    Another agent did the work and submitted it. You are the second agent: don't change the code or the card beyond your decision. The builder's evidence says where to look, not what to believe: check each claim in it, never carry one on its word. A test it names is read and run, a mutant it says was killed is broken again or sampled, a docs place it says it updated is opened.
    #{resubmission_block(card)}#{audit_misses_block(card)}
    #{card_block(card, board, judging)}
    #{decide}. Decide once, and report the decision as a step first (`deciding: accept` or `deciding: reject`):
       - `slipdock verify #{card.id} accept#{at} --reason "what you checked, each check in turn" --check ask=ok --check bar:1=ok …`
       - `slipdock verify #{card.id} reject#{at} --reason "<the check it fails>: what falls short, specifically" --check bar:2=fail:"why" …`
    Give the verdict in parts, one `--check` each (MCP `verify_card` `checks`): `ask=ok|misses`, `bar:<n>=ok|fail`, `suite=<passed>:<failed>`#{if handbook, do: ", `rule:<id>=ok|broken|n/a|pre-existing:<file>:<line>`, `handbook_line=ok|disputed`", else: ""}#{if defect_review?(card, board), do: ", `defect:important|nit|pre-existing=<file>:<line>`", else: ""}#{if mutation_review?(card, board), do: ", `mutant:killed|survived|pre-existing=<file>:<line>:<mutation>`, `mutants=n/a:<why>`", else: ""}, each with `:<why>` after it if it needs one. A rejection names at least one failing part; an acceptance can't carry one, but for a missed `should` rule.
    A rejection cites what it fails: #{cite_list(handbook)}. It goes back to whoever takes the card next, so say exactly what to fix.
    """
  end

  ## What audits caught recently (#2695) ------------------------------------

  @misses_limit 5
  @misses_days 30
  @miss_line_max 300

  # When a disagreement happened: the finding's insert, or the audit job a
  # repeat counted in when that is newer (`count_repeat` keeps the newer
  # job). Never `updated_at`, which triage moves.
  defmacrop miss_at(f, j) do
    quote do
      type(
        fragment(
          "GREATEST(?, COALESCE(?, ?))",
          unquote(f).inserted_at,
          unquote(j).inserted_at,
          unquote(f).inserted_at
        ),
        :utc_datetime
      )
    end
  end

  @doc """
  The tree's recent audit misses (#2695): the last `limit` audit
  disagreements (`source: audit` findings on `card`'s root board) of the
  last `days` days, newest first, each `%{card_id, title, failed, at}`. The
  title is the rework card's (an older one's, or with none, what
  `rework_title/2` makes of the reason); `failed` the parts it failed, or
  nil when they weren't kept. A rework since accepted keeps its miss here:
  the miss is the lesson, not the open work.

  The window and the order go by when the disagreement happened (`at`),
  never by `updated_at`, which triage moves: when the finding was recorded,
  or the newer audit job a repeat on the same card counted in. A dismissed
  or promoted miss still counts; a merged one doesn't, as the finding it was
  merged into carries its lesson.
  """
  def recent_audit_misses(%Card{} = card, limit \\ @misses_limit, days \\ @misses_days) do
    root = card |> board() |> Board.root_id()
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.all(
      from f in Slipdock.Findings.Finding,
        left_join: j in Slipdock.Runners.Job,
        on: j.id == f.job_id,
        where: f.board_id == ^root and f.source == "audit" and f.status != "merged",
        select: {f, miss_at(f, j)},
        where: miss_at(f, j) >= ^since,
        order_by: [desc: miss_at(f, j), desc: f.id],
        limit: ^limit
    )
    |> Enum.map(&audit_miss/1)
  end

  defp audit_miss({finding, at}) do
    %{failed: failed, rework_id: rework_id} = Slipdock.Findings.Signals.audit_failed(finding)
    rework = rework_id && Repo.get(Card, rework_id)

    %{
      card_id: finding.card_id,
      title: miss_title(finding, rework),
      failed: failed || (rework && rework_failed_parts(rework.description)),
      at: at
    }
  end

  defp miss_title(_finding, %Card{title: title}), do: title

  defp miss_title(finding, nil) do
    reason =
      finding.text
      |> to_string()
      |> String.replace_prefix("An audit disagrees with the acceptance: ", "")

    rework_title(%Card{id: finding.card_id}, reason)
  end

  # A rework's description lists what failed (`rework_failed/1`): an older
  # finding's parts, read from there.
  defp rework_failed_parts(description) do
    case Regex.run(~r/\n\nWhat failed:\n\n((?:- [^\n]*\n?)+)/, to_string(description)) do
      [_, list] ->
        list
        |> String.split("\n", trim: true)
        |> Enum.map_join("; ", &String.trim_leading(&1, "- "))

      nil ->
        nil
    end
  end

  # The verify prompt's block of recent misses: only on a tree with audits
  # on and something they caught; never in the audit prompt, which judges
  # afresh. "" otherwise, so the prompt is as it was.
  defp audit_misses_block(%Card{} = card) do
    with true <- audit_every(card) > 0,
         [_ | _] = misses <- recent_audit_misses(card) do
      lines = Enum.map_join(misses, "\n", &miss_line/1)

      """

      What audits on this board caught recently: acceptances that a second verifier, re-judging the work after it was accepted, found short. Verifiers here keep missing the same things, so check these first on this card, then judge it as below.
      #{lines}
      """
    else
      _ -> ""
    end
  end

  defp miss_line(miss) do
    failed = if miss.failed, do: " — failed: #{miss.failed}", else: ""

    line =
      "- “#{miss.title}” (##{miss.card_id}, #{Date.to_iso8601(DateTime.to_date(miss.at))})#{failed}"

    if String.length(line) > @miss_line_max,
      do: String.slice(line, 0, @miss_line_max - 1) <> "…",
      else: line
  end

  # A resubmission (#1944): the last verdict, the commit it judged, and how
  # to judge only what failed and what changed since. "" for a first
  # verification, so its prompt is as it was.
  defp resubmission_block(%Card{} = card) do
    case previous_verdict(card) do
      nil -> ""
      previous -> resubmission_text(card, previous)
    end
  end

  defp resubmission_text(card, previous) do
    alias Slipdock.Verified.Checks
    sha = previous.sha
    now = card.evidence_commit || "<commit>"
    passed = Checks.passed_parts(previous.checks)

    parts =
      case Checks.lines(previous.checks) do
        [] ->
          "(it gave no parts)"

        lines ->
          Enum.map_join(lines, "\n", fn
            {label, result, nil} -> "- #{label}: #{result}"
            {label, result, why} -> "- #{label}: #{result} — #{why}"
          end)
      end

    """

    This card was judged before, at commit #{sha}, and sent back#{if previous.accepted, do: " after its merge failed (it had been accepted)", else: " (rejected #{previous.rejections}×)"}. Judge what changed, not the whole card again.
    #{if previous.accepted, do: "Why it came back: the card's last **Merge failed** comment.", else: "The last verdict's reason: #{previous.reason || "(see the card's last **Rejected** comment)"}"}
    Its parts:
    #{parts}

    How to judge this round:
    - List what the commits since touched: `git diff --name-only #{sha} #{now}` (on a rebased branch, `git fetch origin #{sha}` first; if that commit can't be found, judge every part).
    - Judge every part that failed, and any part whose files, or what it is about, the commits since touch. Run the suite or check CI as below, whatever changed.
    - Carry the rest: a part that passed at #{Checks.short(sha)} and that nothing since touches stands. Don't judge it again; give it as `--check bar:1=carried` (or leave it out) and it is recorded as carried from #{Checks.short(sha)}.#{carry_list(passed)}
    - Never raise again a part that passed or that the new commits fixed. Flag a class of problem once: under one part, with every instance of it you find (file and line each), never one now and the next in another round.
    - If you reject, name what changed since the last rejection, and say why the fix falls short, so the next round converges.
    """
  end

  defp carry_list([]), do: " (The last verdict passed no part, so there is nothing to carry.)"

  defp carry_list(passed),
    do:
      " Passed then: " <>
        Enum.map_join(passed, ", ", &Slipdock.Verified.Checks.carried_label/1) <> "."

  # What the card asks, its bar and evidence, and the steps to its checks:
  # the same for a verify job and an audit.
  defp card_block(card, board, judging) do
    commit = card.evidence_commit

    """
    What the card asks (its description):
    #{if blank?(card.description), do: "(no description: the title is the ask)", else: ask_text(card.description)}

    The bar (what done means):
    #{if blank?(card.bar), do: "(none written: check it against the card's description)", else: card.bar}

    The evidence it gave:
    #{if evidence?(card), do: card |> evidence_text() |> String.replace_prefix("**Evidence.**\n\n", ""), else: "(none)"}
    Commit: #{commit || "(none given)"}

    Say where you are at each step, so the job shows it while you work: `slipdock job-progress --step "…"` (the job is the one in $SLIPDOCK_JOB_ID; or MCP `job_progress` with `step`). Give a step, never a note or `--message`: a note becomes a comment on the card, and the card stays quiet until you decide.

    1. Read the card and its comments: `slipdock card #{card.id}`.
    #{check_step(card, board)}
    #{judging |> Enum.with_index(3) |> Enum.map_join("\n", fn {text, n} -> "#{n}. #{text}" end)}\
    """
  end

  # The checks after the checkout, in order: the ask and the bar always; the
  # rules and the Handbook line only on a board with a handbook.
  defp judge_steps(card, board, handbook, opts \\ []) do
    base = [
      "The ask. Does the bar cover everything the description (and any request in the comments) asks for? A bar that leaves part of the ask out is a rejection (`the ask: the bar misses …`), even when the work meets the bar. On a bug, the ask is the reported symptom, so the check is would the reporter now see it fixed, not does the work meet the bar: a card or evidence that says the reported symptom or its cause was never seen (\"I couldn't tell what…\", a cause made up in the test, a repro built until something failed) is a rejection (`the ask: the reported symptom was never seen`), however good the tests. Step: `judging the ask`",
      "The bar. Each item, against the change and the tests it names. A part not met is a rejection naming the item (`bar 2: …`). #{moot_bar_sentence()} Step: `judging against the bar`"
    ]

    steps =
      if handbook,
        do: [hd(base), bar_with_proposals(handbook) | handbook_steps(card, board, handbook, opts)],
        else: base

    steps ++ defect_steps(card, board) ++ mutation_steps(card, board, opts)
  end

  @defect_profiles ~w(schema security)

  @doc """
  Whether a verifier of `card` also reviews its diff for defects (#1953):
  profiles are on for `board` and the card's profile (set, else inferred)
  is `schema` or `security`.
  """
  def defect_review?(%Card{} = card, %Board{} = board),
    do:
      board.profiles == true and
        Enum.member?(@defect_profiles, Slipdock.Profiles.profile_of(card))

  @doc "The profiles whose verifier reviews the diff for defects."
  def defect_profiles, do: @defect_profiles

  defp defect_steps(card, board) do
    if defect_review?(card, board),
      do: [defect_review_step(Slipdock.Profiles.profile_of(card))],
      else: []
  end

  @doc "The defect-review step of a `schema` or `security` card's verify prompt (#1953)."
  def defect_review_step(profile) do
    """
    The defect review. This card's profile is `#{profile}`, so the change gets a pass for defects as well as the checks above. Read the diff for bugs, not style: wrong results, data lost or exposed, a migration that can't run or can't be undone, a missing check on who may do what, a race. On a fix, find the root cause and say whether the change reaches it. Give each finding the file and line it is at, read in the clean tree, never a guess from a name. Tag each one:
       - Important: a defect this change brings in. It is a rejection, with the finding as its failing part: `--check defect:important=lib/foo.ex:42:"what goes wrong"`.
       - Nit: worth saying, not worth sending it back. Reported only: `--check defect:nit=lib/foo.ex:7:"why"`.
       - Pre-existing: a defect in lines the diff didn't change. Reported only: `--check defect:pre-existing=lib/bar.ex:90:"why"`.
       No findings is a normal answer: say so in the reason. Step: `reviewing for defects`\
    """
  end

  @mutation_profiles ~w(fix feature schema security)

  @doc """
  Whether a verifier of `card` also mutates the change (#2354): profiles are
  on for `board`, the card's profile (set, else inferred) is `fix`,
  `feature`, `schema` or `security`, and the completion changes code (never
  a `--no-code` one). `docs` and `spike` cards get no mutation step.
  """
  def mutation_review?(%Card{} = card, %Board{} = board),
    do:
      board.profiles == true and not no_code?(card) and
        Enum.member?(@mutation_profiles, Slipdock.Profiles.profile_of(card))

  @doc "The profiles whose verifier mutates the change."
  def mutation_profiles, do: @mutation_profiles

  defp mutation_steps(card, board, opts) do
    if mutation_review?(card, board),
      do: [mutation_step(card, opts)],
      else: []
  end

  @doc """
  The mutation step of a verify prompt (#2354): break the change's most
  consequential lines one at a time, run only the card's tests, restore, and
  give each mutant as a part. On a `fix` card one mutation undoes the fix.
  """
  def mutation_step(%Card{} = card, opts \\ []) do
    profile = Slipdock.Profiles.profile_of(card)

    tests =
      if Enum.member?([nil, []], card.evidence_tests),
        do:
          "the tests the evidence names (it gave no `--tests`: say so, and use the test files the diff adds or changes)",
        else: "the card's tests (`#{Enum.join(List.wrap(card.evidence_tests), " ")}`)"

    """
    The mutation step: would the tests catch a break? This card's profile is `#{profile}`. In the clean worktree, pick 3 to 5 of the most consequential lines the diff added or changed: a condition, a guard, an error branch, a returned value. On top of those, break once each guard or branch the diff adds (a new condition, clause, pattern match or early return), naming each with its line: a survivor there is a rejection like any other. Break each one in turn (flip `>` to `>=`, drop the branch, return the wrong thing), run only #{tests}, never the whole suite, then restore the line before the next (`git checkout -- <file>`) and leave the tree as you found it.#{fix_mutation(profile)} On a board that ships by pull request run these tests yourself all the same: CI ran the suite, not the mutations. Give each mutant as a part, its file and line read in the clean tree:
       - Killed: a test failed. `--check mutant:killed=lib/foo.ex:42:"> to >="`.
       - Survived: no test failed, on a line the diff added or changed. It is a rejection, its reason naming the mutation and the test to write: `--check mutant:survived=lib/foo.ex:42:"drop the nil guard":"a test that passes nil"`.
       - Pre-existing: a survivor on a line the diff didn't change. Reported only, and kept as a finding: `--check mutant:pre-existing=lib/bar.ex:90:"return []"`.
       - Nothing in the diff worth mutating (only text, config or a rename): `--check mutants=n/a:"why"`, and say why in the reason.
    #{builder_mutants_note(card, opts)}#{mutation_resubmission(card, opts)}   Step: `mutating the change`\
    """
  end

  @doc """
  The mutants a builder names in its evidence (#2635): the `mutant:...=`
  lines of `card.evidence` (a leading `- ` or `* ` bullet allowed), parsed
  as a verifier's parts are. A line that doesn't parse is left out, so a
  builder's typo never breaks the verify prompt.
  """
  def builder_mutants(%Card{evidence: evidence}) when is_binary(evidence) do
    evidence
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^[-*]\s+/, "") |> String.trim("`")))
    |> Enum.filter(&String.starts_with?(&1, "mutant:"))
    |> Enum.flat_map(fn line ->
      case Slipdock.Verified.Checks.parse([line]) do
        {:ok, %{"mutants" => [mutant]}} -> [mutant]
        _ -> []
      end
    end)
  end

  def builder_mutants(_card), do: []

  # The builder runs the mutation review before submitting (#2635) and names
  # what it broke. The list is a map (#2696): a killed one is carried only
  # when re-run or plainly covered by a named test; an audit carries none.
  defp builder_mutants_note(card, opts) do
    case builder_mutants(card) do
      [] ->
        "   The builder named no mutants in its evidence (`mutant:killed=<file>:<line>:<mutation>` lines): choose all of yours freely, and say in the reason that it named none.\n"

      mutants ->
        listed = Enum.map_join(mutants, "\n", &"     - `#{mutant_line(&1)}`")

        "   The builder ran this review before submitting and names the mutants it tried:\n#{listed}\n   That list is a map, not a verdict. #{carry_builder_mutants(opts)} Spend your 3 to 5 on other lines. One it says survived must have a test now or a stated reason in the evidence; break it again.\n"
    end
  end

  defp carry_builder_mutants(opts) do
    if Keyword.get(opts, :audit, false),
      do:
        "An audit carries nothing: break again each one it says was killed, or give your own result for its line.",
      else:
        "One it says was killed is carried only when you broke it again yourself (give your result) or a test the builder names plainly covers that line (`--check mutant:carried=<file>:<line>`, and say which test); otherwise break it again."
  end

  defp mutant_line(%{"result" => result, "file" => file, "line" => line} = mutant) do
    note = if mutant["note"], do: ":#{mutant["note"]}", else: ""
    "mutant:#{result}=#{file}:#{line}:#{mutant["mutation"]}#{note}"
  end

  # A resubmission (#1944) re-runs only what could have changed: the
  # mutants that survived, and any on lines the commits since touch.
  defp mutation_resubmission(card, opts) do
    if not Keyword.get(opts, :audit, false) and previous_verdict(card) != nil,
      do:
        "   On this resubmission, break again every mutant that survived last time and any on a line the commits since touch, giving its place afresh; a killed one elsewhere stands: give it as `--check mutant:carried=lib/foo.ex:42` (or leave it out).\n",
      else: ""
  end

  defp fix_mutation("fix"),
    do:
      " This is a fix, so one mutation undoes the fix itself (put the old line back): the regression test must kill it, and a survivor there means the fix has no test."

  defp fix_mutation(_), do: ""

  # On a board with a handbook a rule is a person's call, so a bar item that
  # asks for a rule change is met by an open proposal, never a direct edit
  # (#1882).
  defp bar_with_proposals(handbook) do
    code = handbook.board.code || to_string(handbook.board.id)

    """
    The bar. Each item, against the change and the tests it names. A part not met is a rejection naming the item (`bar 2: …`).
       #{rule_proposal_sentence()} List them with `slipdock garden #{code} --check proposal --json` and judge the proposal's content, not the live Rules list: name its id in the accept reason (`bar 3: met by proposal #5`).
       #{moot_bar_sentence()}
       #{rule_rejection_sentence()} Step: `judging against the bar`\
    """
  end

  @doc """
  What a verifier does with a bar item a later decision or rule made moot
  (#2096): the builder reads it the obvious way and says so on the card,
  rather than waiting on a person, and the verifier judges that reading.
  Noted, it is accepted on its merits; read another way without a note, it
  is a rejection.
  """
  def moot_bar_sentence do
    "A bar item made moot by a later decision or rule (locked before it, and cited) is met by its obvious reading when the card or the evidence says so: what was read, why, and the decision or rule cited (`W-…`, `#…`). Judge that reading, and accept it if the citation holds. An item read another way without such a note is a rejection (`bar 2: read differently from its words, and not noted on the card`)."
  end

  @doc """
  What a builder is told to do with the bar at pickup, before building
  (#1883): read each part against the guide and, when one needs a person,
  ask rather than meet it some other way and leave the conflict to the
  verifier. Said in a claimed job's prompt after the bar; the guide and the
  loop and work skills say the same.
  """
  def bar_pickup_check,
    do:
      "Before building, check each part of the bar against the guide: if one can't be met as written because it needs a person (a handbook rule added, reworded or dropped, a merge, a deploy to prod, applying a proposal), stop and ask. Open a wait (`slipdock wait <card> …`, update_card `wait`) naming the part and what you could do instead, so a person rewords the bar or confirms the alternative. Don't build to your own reading of it and leave the conflict to the verifier."

  @doc "What the verify and audit prompts say meets a bar item asking for a rule change (#1882)."
  def rule_proposal_sentence,
    do:
      "A bar item that adds, rewords or drops a handbook rule is met by a matching open rule proposal: a garden proposal with an `edit_section` step on that page's `## Rules` that says what the bar asks, since a rule is a person's call and an agent files a proposal rather than editing it."

  @doc "What the verify and audit prompts say a rejection never asks for (#1882)."
  def rule_rejection_sentence,
    do:
      "A rejection never asks the builder to edit `## Rules` directly: when the proposal is missing or says the wrong thing, ask for it to be filed or corrected."

  defp handbook_steps(card, board, handbook, opts) do
    code = handbook.board.code || to_string(handbook.board.id)
    sha = card.evidence_commit || "<commit>"

    base =
      if Board.ships_by_pr?(board) and not blank?(card.evidence_pr),
        do: "origin/$(gh pr view #{card.evidence_pr} --json baseRefName -q .baseRefName)",
        else: "origin/<default branch>"

    [
      """
      The rules. In the clean tree, list the rules for the paths the change touches:
         `git diff --name-only $(git merge-base #{base} #{sha}) #{sha} | slipdock handbook #{code} --paths-from -`
         #{rules_judging(opts[:audit])} Step: `judging the rules`\
      """
    ] ++
      docs_places_steps(card, handbook, base, sha, opts) ++
      [
        """
        The Handbook line. Find the `Handbook:` line, in the evidence or the builder's closing comment, and hold it against the diff with the docs gate: user-visible behaviour updates the Specification; structure or boundaries, Architecture or the Data model; a choice between alternatives, a new page in `Handbook/Decisions`; something reusable, Shared modules or Components; a UI pattern, UX & UI; how to test, build or deploy, Testing & tooling or Operations. No line, a line saying `no change` on a diff that needed one, or a line naming pages the work didn't edit (`slipdock page history <page>`), is a rejection (`Handbook line: …`). Step: `judging the Handbook line`\
        """
      ]
  end

  ## The docs places (#2694) ---------------------------------------------------

  @docs_rule "SPEC-10"

  # The seven places a reader looks for what Slipdock does (SPEC-10), each
  # with the files to grep.
  @docs_places [
    {"the README", "README.md"},
    {"the manual", "docs/manual.md docs/manual/"},
    {"the app's in-app help (`HelpLive.Guides`)", "lib/slipdock_web/live/help_live/guides.ex"},
    {"the agents' and runners' in-app help (`HelpLive.Agents`, `HelpLive.Flow`, and the CLI reference's `cli/help.txt`)",
     "lib/slipdock_web/live/help_live/agents.ex lib/slipdock_web/live/help_live/flow.ex cli/help.txt"},
    {"the agents page", "docs/agents.md"},
    {"the API guide", "lib/slipdock_web/api_guide.ex"},
    {"the skills", "priv/skills/"}
  ]

  @doc "The rule whose places the docs-places step enumerates (#2694)."
  def docs_places_rule, do: @docs_rule

  @doc "The seven docs places (#2694): `{name, the files to grep}` each."
  def docs_places, do: @docs_places

  @doc """
  Whether `card` falls in the docs-places rule's scope (#2694), on `handbook`
  (as `Slipdock.Handbook.find/1` gives it): `:in` when its lane paths meet
  the scope of the handbook's `SPEC-10`, `:out` when they don't or the
  handbook has no such rule (or there is no handbook), and `:unknown` when
  the card has no paths, so the step is given for the diff to decide.
  """
  def docs_places_scope(_card, nil), do: :out

  def docs_places_scope(%Card{} = card, handbook) do
    rule = Enum.find(Slipdock.Handbook.Rules.rules(handbook), &(&1.id == @docs_rule))

    cond do
      rule == nil -> :out
      Enum.member?([nil, []], card.paths) -> :unknown
      Enum.any?(Slipdock.Handbook.rules_for(handbook, card.paths), &(&1.id == @docs_rule)) -> :in
      true -> :out
    end
  end

  defp docs_places_steps(card, handbook, base, sha, opts) do
    case docs_places_scope(card, handbook) do
      :out -> []
      scope -> [docs_places_step(base, sha, scope, opts)]
    end
  end

  @doc """
  The docs-places step of a verify or audit prompt (#2694), for a card in
  SPEC-10's scope: enumerate the places, don't judge them. The names the
  change introduces or alters, from the diff, grepped across each of the
  seven places, and each place reported as updated, deferred to a card
  whose bar names it, n/a with why, or missing. `scope` is `:in`, or
  `:unknown` for a card with no paths (the diff's rules decide).
  """
  def docs_places_step(base, sha, scope \\ :in, opts \\ []) do
    lead =
      if scope == :unknown,
        do:
          "If the rules above list #{@docs_rule} (the card declared no paths, so its diff decides), check its places by enumerating them, not by judging them.",
        else:
          "This card's paths fall in #{@docs_rule}'s scope, so check its places by enumerating them, not by judging them."

    broken =
      if opts[:audit],
        do: "One `missing` is a disagreement",
        else: "One `missing` is a rejection"

    """
    The docs places (#{@docs_rule}). #{lead}
       - The names: read the diff (`git diff $(git merge-base #{base} #{sha}) #{sha}`) and list every name the change introduces or alters that a reader would look up: commands, flags and switches, MCP tool names and their fields, API paths and fields, settings, page and section names.
       - The places, seven:
    #{docs_places_lines()}
       - For each name, grep each place at the commit (`rg -n '<name>' <files>`), and give each place one result:
         - `updated`: the change edits it and it says the new or altered name.
         - `deferred to #N`: the builder left it to card #N, and #N's bar names this place (`slipdock card N`). A deferral to a card whose bar doesn't name the place doesn't count: it is `missing`.
         - `n/a`, with why: a reader wouldn't look for this name here (an internal helper, a page that doesn't cover it).
         - `missing`: none of these.
       - Give the seven results in the reason, one per place with the names checked (`Docs places: README updated; the manual updated; the skills deferred to #123; the API guide n/a (no API change); …`). #{broken}: `--check rule:#{@docs_rule}=broken:<place's file>:<the name it lacks>`, one line per place and name, every one in this round. All seven accounted for is `--check rule:#{@docs_rule}=ok`. Step: `checking the docs places`\
    """
  end

  defp docs_places_lines do
    @docs_places
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{name, files}, n} ->
      "     #{n}. #{name}: `#{files}`"
    end)
  end

  @doc """
  What a builder is told about the docs places (#2694), in a claimed job's
  prompt for a card in SPEC-10's scope: the same enumeration the verifier
  runs, and a place left out goes on the deferral card's bar by name, or the
  deferral doesn't count.
  """
  def docs_places_builder do
    "The docs places (#{@docs_rule}): this card's paths fall in its scope, so the verifier enumerates them rather than judging them, and so do you before submitting. List every name the change introduces or alters (commands, flags, MCP tool names, API fields, settings, page and section names), grep each across the seven places, and give each place as updated, deferred to #N, n/a with why, or missing. The places:\n" <>
      docs_places_lines() <>
      "\nA place your lane can't reach is deferred to a card you file: list each left-out place on that card's bar, by name with the names it must cover (`--bar \"1. docs/agents.md says --foo …\"`), and name the card in your evidence. A deferral to a card whose bar doesn't list the place doesn't count, and the verifier rejects it as missing."
  end

  defp rules_judging(true),
    do:
      "Judge every rule it lists, `should` rules as well as `must`: a rule whose check is a test is kept when that test passes; a `judgement` rule, by reading the change. Name each one you find broken by its id (`ARCH-3: …`). " <>
        every_instance_sentence() <> " " <> pre_existing_sentence()

  defp rules_judging(_),
    do:
      "Judge every `must` rule it lists: a rule whose check is a test is kept when that test passes; a `judgement` rule, by reading the change. A broken `must` is a rejection citing its id (`ARCH-3: …`). List any `should` rule missed in the accept reason, each as a finding in a `Findings:` block there (`- rule: ARCH-6 missed: <how>`), so the board keeps it. " <>
        every_instance_sentence() <> " " <> pre_existing_sentence()

  @doc """
  What the verify and audit prompts say once a rule is found broken (#2046):
  look for every other instance of the same break and name them all in one
  rejection, each with its file and line, since every round of rejection
  and rework costs the card the same whatever the fix's size.
  """
  def every_instance_sentence,
    do:
      "Once you find a rule broken, look for every other instance of the same break the card could reasonably have missed (the same list, the same string, the same door) and name them all in this one rejection, never the first and leave the rest for the next round: each round costs the card a rework and a verify whatever the fix's size. " <>
        "For example, a page list copied across docs (the README, a skill, a help page) that the card updated in one place: `rg` the list's words across the repo, and give each stale copy as its own line under the one rule, file and line each: " <>
        "`--check rule:SPEC-10=broken:README.md:40:lacks Playbook --check rule:SPEC-10=broken:priv/skills/slipdock-docs/SKILL.md:12:the same list`. " <>
        "Say in the reason that you did (`Every instance: searched <where> for <what>; found these N.`)."

  @doc """
  What the verify and audit prompts say about a rule broken only in code
  the change didn't touch (#1945): report it as `pre-existing`, never
  reject for it.
  """
  def pre_existing_sentence,
    do:
      "A rule broken only in lines the diff didn't change is not the builder's: give it as `--check rule:<id>=pre-existing:<file>:<line>` (where it is broken), never as `broken` and never as a reason to reject. It is kept as a `rule` finding on the card, and an acceptance may carry it. A hit that is in lines the diff added or changed is `broken` as usual."

  defp cite_list(nil), do: "the bar item (`bar 2: …`) or the ask (`the ask: …`)"

  defp cite_list(_handbook),
    do:
      "a bar item (`bar 2: …`), the ask (`the ask: …`), a rule id (`ARCH-3: …`) or the Handbook line (`Handbook line: …`)"

  # The ask as the prompt shows it: the description, cut short if long.
  @ask_cap 4000
  defp ask_text(text) do
    text = String.trim(text)

    if String.length(text) > @ask_cap,
      do: String.slice(text, 0, @ask_cap) <> "\n… (cut short: read the rest on the card)",
      else: text
  end

  # Step 2 of the verify prompt. On a pull request board the PR's CI has run
  # the suite at the submitted commit, so the verifier reads the change and
  # checks CI rather than running the suite again (#1808).
  defp check_step(%Card{} = card, board) do
    if Slipdock.Profiles.spike?(card),
      do: spike_check_step(card),
      else: shipped_check_step(card, board)
  end

  defp shipped_check_step(%Card{evidence_commit: commit} = card, board) do
    tree =
      if commit,
        do:
          "Check out #{commit} in a clean tree (`git worktree add /tmp/verify-#{card.id} #{commit}`), so nothing uncommitted counts",
        else: "Find the work in the project's repository, in a clean tree"

    pr = card.evidence_pr

    cond do
      Board.ships_by_pr?(board) and not blank?(pr) -> pr_check_step(tree, commit, pr)
      Board.ships_by_pr?(board) and no_code?(card) -> no_code_check_step(card)
      Board.ships_by_pr?(board) and epic?(card) -> epic_check_step(tree)
      true -> suite_check_step(tree, commit)
    end
  end

  # A spike (#2351): it answers a question by building, and its code is
  # never merged, so the verifier judges the answer and its evidence, not a
  # pull request, and runs no suite unless the bar asks for one.
  defp spike_check_step(%Card{} = card) do
    branch = if blank?(card.evidence_branch), do: pr_branch(card), else: card.evidence_branch

    """
    2. This card is a spike: it answers its bar's question by building, and its code is never merged (#{if blank?(card.evidence_no_code), do: "no reason given", else: "\"#{card.evidence_no_code}\""}). There is no pull request to check and nothing merges, so don't run the suite unless the bar asks for one. Read the answer page (pinned to the epic, or named in the evidence) and the prototype on `#{branch}`, and judge:
       - The ask: the answer addresses the question the bar asks.
       - The evidence is real: numbers, logs, a branch and commit you can look at, not claims. An answer claimed without evidence is a rejection.
       - The page says what the answer changes in the plan.
       - *Inconclusive*, with what was learned, passes. Reject only for not really trying, or for an answer without evidence; never for the answer being "no".
       Steps to report:
       - `spike: <the answer in a few words, or inconclusive>`
       - `evidence: <what you looked at>`\
    """
  end

  # An epic on a pull request board with no pull request of its own (#1917):
  # each subcard's was checked and merged, so its CI ran the suite.
  defp epic_check_step(tree) do
    """
    2. This card is an epic with no pull request of its own: each subcard shipped and merged its own, and their CI ran the suite. #{tree}, and don't run the suite.
       - Every subcard is accepted and merged (`slipdock card <id>` lists them; a subcard still open or merging is a rejection naming it).
       - The default branch's latest build passed (`gh run list --branch <default branch> --limit 1`); a failed one is a rejection naming it.
       Steps to report:
       - `subcards: <n> merged`
       - `CI: default branch passed at <sha>` (or `CI failed: <check>`)\
    """
  end

  # A card on a pull request board whose evidence says it changes no code
  # (#1938): there is nothing to check out or test, so the verifier judges
  # the claim itself, and what the card left on the board instead.
  defp no_code_check_step(%Card{} = card) do
    """
    2. The builder says this card changes no code: "#{card.evidence_no_code}". There is no pull request, commit or suite to check, so don't check one out or run the suite.
       - Judge the claim against the ask: a card whose description asks for a change to code, tests or the repository's docs can't be finished without code, and is a rejection (`the ask: changes no code, but the card asks for …`).
       - Check what it did instead, where the evidence says: the cards it filed, the pages or sections it edited (`slipdock page history <page>`), the comments it left.
       Steps to report:
       - `no code: <the reason, in a few words>`
       - `checked: <what you looked at instead>`\
    """
  end

  defp pr_check_step(tree, commit, pr) do
    head = commit || "the commit you check"

    """
    2. #{tree}, and read the change itself (its diff from the default branch) and the tests it names. Don't run the suite: the pull request's CI runs it at this commit.
       - `gh pr view #{pr} --json headRefOid,statusCheckRollup`: the head must be #{head}. If the pull request has moved on since it was submitted, reject it to be submitted again at its head.
       - Every check must have passed. While any is still running, wait (`gh pr checks #{pr} --watch`). A failed check is a rejection: name it.
       - If the pull request has no checks at all, run the suite in the clean tree instead.
       Steps to report:
       - `checked out #{commit || "<commit>"}`
       - `CI: <n> checks passed at #{commit || "<commit>"}` (or `waiting for CI`, `CI failed: <check>`)\
    """
  end

  defp suite_check_step(tree, commit) do
    """
    2. #{tree}, run the suite there, and read the change itself and the tests it names. Steps to report:
       - `checked out #{commit || "<commit>"}`
       - `tests running: <which>`
       - `tests passed: <n>, failed: <n>` (or `tests failed: …`)\
    """
  end

  # Whoever decides first decides: the other verify jobs on the card stop
  # (an audit, queued by an acceptance, isn't one of them: #1780).
  defp cancel_verify_jobs(%Card{id: card_id}, actor) do
    import Ecto.Query
    mine = actor_map(actor)["job_id"]

    from(j in Slipdock.Runners.Job,
      where:
        j.card_id == ^card_id and j.kind == @verify_kind and not j.audit and
          j.status in ^Slipdock.Runners.Job.open_statuses()
    )
    |> Repo.all()
    |> Enum.reject(&(&1.id == mine))
    |> Enum.each(&Slipdock.Runners.cancel_job/1)
  end

  defp api_error({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}
  defp api_error(other), do: other

  # The decision's comment keeps its verdict in parts (#1778), so a later
  # decision replacing `verify_checks` loses nothing.
  defp with_parts(note, nil), do: note
  defp with_parts(note, %{"from_reason" => true}), do: note

  defp with_parts(note, checks) do
    parts = Slipdock.Verified.Checks.markdown(checks)

    [note, "Checks:\n\n" <> parts]
    |> Enum.reject(&Enum.member?([nil, ""], &1))
    |> Enum.join("\n\n")
  end

  defp comment(card, line, note, user) do
    body = if note in [nil, ""], do: line, else: "#{line}\n\n#{note}"
    Slipdock.Boards.add_comment(card, body, by: user)
  end

  defp done_list(columns) do
    columns |> Enum.sort_by(& &1.position) |> Enum.find(&Column.done?/1)
  end

  @doc """
  Whether two actors (`Slipdock.Actor` maps, as stored or as built) are the
  same one: the same kind, person, token label and runner job. Two runner
  jobs, two tokens, or a person and an agent are different.
  """
  def same_actor?(nil, _actor), do: false

  def same_actor?(a, b) do
    a = actor_map(a)
    b = actor_map(b)
    Map.take(a, ~w(kind user_id agent job_id)) == Map.take(b, ~w(kind user_id agent job_id))
  end

  defp actor_map(nil), do: nil

  defp actor_map(actor) do
    Map.new(~w(kind via user_id agent job_id), fn key ->
      {key, Map.get(actor, key, Map.get(actor, String.to_existing_atom(key)))}
    end)
  end

  @doc """
  Who an actor stored on a card (`verify_by`, `verify_submitter`) was, in
  words: an agent by its token's label, a person by their name.
  """
  def who(nil), do: "somebody"

  def who(actor) do
    case actor_map(actor) do
      %{"kind" => kind} when kind in ["agent", "automation"] ->
        who(actor, nil)

      %{"user_id" => id} when is_integer(id) ->
        Slipdock.Accounts.User.display_name(Repo.get(Slipdock.Accounts.User, id))

      _ ->
        "somebody"
    end
  end

  @doc """
  The person behind an actor stored on a card, when it was a person whose
  account still exists: nil for an agent, a deleted account or nobody. The
  card panel uses it to show their email and offer a note or an assignment.
  """
  def person(nil), do: nil

  def person(actor) do
    case actor_map(actor) do
      %{"kind" => "agent"} -> nil
      %{"user_id" => id} when is_integer(id) -> Repo.get(Slipdock.Accounts.User, id)
      _ -> nil
    end
  end

  defp who(actor, user), do: actor |> actor_map() |> named(user)

  # The server's own acceptance (#1953) names itself.
  defp named(%{"kind" => "automation", "agent" => agent}, _user) when is_binary(agent), do: agent

  defp named(a, user) do
    cond do
      a["via"] == "runner" and a["agent"] -> "runner #{a["agent"]}"
      a["kind"] == "agent" and a["agent"] -> "agent “#{a["agent"]}”"
      a["kind"] == "agent" -> "an agent"
      user -> Slipdock.Accounts.User.display_name(user)
      true -> "somebody"
    end
  end

  defp handoff_via(actor) do
    case actor_map(actor)["via"] do
      "web" -> "ui"
      via when via in ~w(api mcp cli runner) -> via
      _ -> "api"
    end
  end

  defp commit_matches?(a, b) do
    a = String.downcase(a)
    b = String.downcase(b)
    String.starts_with?(a, b) or String.starts_with?(b, a)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp now, do: DateTime.utc_now(:second)

  ## Helpers ------------------------------------------------------------------

  defp doing?(%Column{category: "doing"}), do: true
  defp doing?(_), do: false

  defp board(%Card{board: %Board{} = board}), do: board
  defp board(%Card{board_id: id}), do: Repo.get!(Board, id)

  # A key from string- or atom-keyed attrs; :none when it isn't there.
  defp fetch(attrs, key) do
    cond do
      Map.has_key?(attrs, to_string(key)) -> attrs[to_string(key)]
      Map.has_key?(attrs, key) -> attrs[key]
      true -> :none
    end
  end

  defp trim(nil), do: ""
  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(other), do: to_string(other)

  defp blank?(text), do: trim(text) == ""
end
