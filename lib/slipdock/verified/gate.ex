defmodule Slipdock.Verified.Gate do
  @moduledoc """
  The checks on a write to a card: what an agent may not change, complete,
  move, create or reopen, with the message each refusal gives, and what a
  completion becomes on a board that verifies work.
  """

  import Ecto.Query, only: [from: 2]

  require Slipdock.Flow.DoingList, as: DoingList

  alias Slipdock.Boards.{Board, Card, CardMove, Column}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Actors, Epics, Evidence, Util}

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

  # What a card's description or bar that is a bare `-` is refused with (#2686).
  @text_dash_flags %{description: "--desc", bar: "--bar"}

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
         :ok <- check_text_dash(attrs, actor),
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
    new = Util.fetch(attrs, :bar)

    cond do
      new == :none or not Actors.gated?(actor) ->
        :ok

      Util.trim(new) == Util.trim(card.bar) ->
        :ok

      not Util.board(card).bar_required ->
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
    new = if Util.blank?(new), do: nil, else: String.downcase(Util.trim(new))

    if Actors.gated?(actor) and new != card.profile and profile_locked?(card),
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
    with new when new != :none <- Util.fetch(attrs, :profile),
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
    Util.board(card).profiles == true and
      (Enum.member?(["person", "inferred"], card.profile_source) or started?(card))
  end

  defp started?(%Card{} = card) do
    card.completed == true or not is_nil(card.bar_locked_at) or
      not is_nil(card.verify_state) or
      Util.doing?(Repo.get(Column, card.column_id)) or
      entered_doing?(card)
  end

  # Whether the move ledger has the card entering a doing list (created in
  # one, moved or restored into one). The ledger snapshots the list's
  # category, so a list renamed or recategorised since still counts.
  defp entered_doing?(%Card{id: id}) do
    Repo.exists?(
      from m in CardMove,
        where:
          m.card_id == ^id and DoingList.doing?(m.to_category, m.to_column_name) and
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
    message =
      reopen_move_message(card, to, actor) || bar_move_message(card, to, actor) ||
        check_subcards_move(card, to, actor) || check_done_move(card, to, actor) ||
        submit_move_message(card, to, actor)

    if message, do: {:error, message}, else: :ok
  end

  # The message an agent gets starting work on a card with no bar, on a
  # board that asks for one, or nil when it may.
  defp bar_move_message(card, to, actor) do
    if Util.doing?(to) and Util.blank?(card.bar) and Actors.gated?(actor) and
         Util.board(card).bar_required,
       do:
         "this board asks for each card's bar before work starts: write what done means " <>
           "for card ##{card.id} (its `bar`), then move it"
  end

  # The message an agent gets completing a card by a move on a board that
  # verifies work, or nil when it may.
  defp submit_move_message(card, to, actor) do
    if Column.done?(to) and not card.completed and Actors.gated?(actor) and
         Util.board(card).verify_work,
       do:
         "this board verifies work: submit card ##{card.id} by completing it (complete_card, " <>
           "`slipdock done`), and a different agent or a person accepts it into the done list"
  end

  @doc """
  After `card` has moved into `to`: the bar locks when work starts, if it is
  written and the board asks for one.
  """
  def moved(%Card{bar_locked_at: nil} = card, %Column{} = to) do
    if Util.doing?(to) and not Util.blank?(card.bar) and Util.board(card).bar_required do
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

    cond do
      field = Actors.gated?(actor) && text_dash(card) ->
        Ecto.Changeset.add_error(changeset, field, text_dash_message(field))

      (Column.done?(column) or card.completed) and Actors.gated?(actor) ->
        check_create_done(changeset, card, column)

      true ->
        check_create_doing(changeset, card, column, actor)
    end
  end

  def check_create(%Ecto.Changeset{} = changeset, _column, _actor), do: changeset

  defp check_create_done(changeset, card, column) do
    board = Util.board(card)

    cond do
      Evidence.dash?(card.evidence) ->
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

      board.evidence_required and not Evidence.evidence?(card) ->
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
      not Util.doing?(column) or not Util.board(card).bar_required ->
        changeset

      Util.blank?(card.bar) and Actors.gated?(actor) ->
        Ecto.Changeset.add_error(
          changeset,
          :bar,
          "is needed to start work: this board asks for each card's bar before work " <>
            "starts, so write what done means (its `bar`) to create a card in " <>
            "#{column.name}, or create it in another list"
        )

      Util.blank?(card.bar) ->
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
    if Actors.gated?(actor),
      do:
        "card ##{card.id} is done, and an agent can't reopen it (untick it or move it out of " <>
          "the done list): a person reopens finished work. If it needs more, add a card for " <>
          "that and link it"
  end

  def reopen_message(_card, _actor), do: nil

  defp check_reopen(card, attrs, actor) do
    with true <- Enum.member?([false, "false"], Util.fetch(attrs, :completed)),
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
    if Actors.gated?(actor) and not Column.done?(to) and
         Column.done?(Repo.get!(Column, card.column_id)),
       do: reopen_message(card, actor)
  end

  def reopen_move_message(_card, _to, _actor), do: nil

  defp check_subcards(card, attrs, actor) do
    with true <- Util.completes?(card, attrs) and Actors.gated?(actor),
         message when is_binary(message) <- Epics.subcards_message(card) do
      {:error, :completed, "is refused: " <> message}
    else
      _ -> :ok
    end
  end

  defp check_subcards_move(card, to, actor) do
    if Column.done?(to) and not card.completed and Actors.gated?(actor),
      do: Epics.subcards_message(card)
  end

  ## Evidence -----------------------------------------------------------------

  # A bare `-` (#2091): `--evidence -` from a client that doesn't read
  # stdin. Refused for agents (SPEC-5, MOD-3: people, the assistant and
  # automations are never refused) on any board, on any write that sets it
  # and on a completion of a card that still holds one, so the piped text is
  # never lost behind a dash.
  defp check_dash(%Card{} = card, attrs, actor) do
    if Actors.gated?(actor) and dashed?(card, attrs),
      do: {:error, :evidence, @dash_message},
      else: :ok
  end

  defp dashed?(card, attrs) do
    Evidence.dash?(Util.fetch(attrs, :evidence)) or
      (Util.completes?(card, attrs) and
         Evidence.dash?(Util.given(attrs, :evidence, card.evidence)))
  end

  # A bare `-` as a card's description or bar (#2686): `--desc -` or
  # `--bar -` from a client that doesn't read stdin (a slipdock CLI from
  # before #2678), which would leave the card with a dash for a body.
  # Refused for agents, as the evidence is above, on a create and on any
  # write that sets one; a card already holding one is left alone.
  defp check_text_dash(attrs, actor) do
    field = Actors.gated?(actor) && text_dash(&Util.fetch(attrs, &1))

    if field, do: {:error, field, text_dash_message(field)}, else: :ok
  end

  # The first of the description and the bar that is a bare dash, or nil.
  defp text_dash(%Card{} = card), do: text_dash(&Map.get(card, &1))

  defp text_dash(value) when is_function(value, 1),
    do: Enum.find([:description, :bar], &Evidence.dash?(value.(&1)))

  defp text_dash_message(field) do
    flag = @text_dash_flags[field]

    "was a bare '-', which is no #{field}: a client that doesn't read stdin sends the " <>
      "dash itself, so the text that was piped in never arrived. Pass the text itself " <>
      "(#{flag} \"…\", `#{field}` over the API and MCP) or pipe it with #{flag} - from a " <>
      "CLI that reads stdin (the slipdock CLI since #2678: reinstall an older one)"
  end

  defp check_evidence(%Card{} = card, attrs, actor) do
    cond do
      not (Util.completes?(card, attrs) and Actors.gated?(actor) and
               Util.board(card).evidence_required) ->
        :ok

      not Evidence.evidence?(card, attrs) ->
        {:error, :evidence, @evidence_message}

      Board.ships_by_pr?(Util.board(card)) ->
        check_pr(card, attrs)

      true ->
        :ok
    end
  end

  # On a board that ships by pull request: a pull request and the commit it
  # is to merge at (#1976), or a reason the card changes no code (#1938), or
  # an epic, whose subcards ship their own.
  defp check_pr(card, attrs) do
    pr? = Util.present?(Util.given(attrs, :evidence_pr, card.evidence_pr))
    no_code? = Util.present?(Util.given(attrs, :evidence_no_code, card.evidence_no_code))

    cond do
      pr? and no_code? -> {:error, :evidence_no_code, @both_message}
      pr? and missing_commit?(card, attrs) -> {:error, :evidence_commit, @pr_commit_message}
      pr? or no_code? or Epics.epic?(card) -> :ok
      true -> {:error, :evidence_pr, @pr_message}
    end
  end

  # A spike's code is never merged (#2349): an agent completing one names
  # no pull request, on any board. People, the assistant and automations
  # are not refused (W-2235).
  defp check_spike_pr(%Card{} = card, attrs, actor) do
    if Util.completes?(card, attrs) and Actors.gated?(actor) and
         Util.present?(Util.given(attrs, :evidence_pr, card.evidence_pr)) and
         Slipdock.Profiles.spike?(spiked(card, attrs)),
       do: {:error, :evidence_pr, @spike_pr_message},
       else: :ok
  end

  # The card as the write would leave its profile, for `spike?/1`.
  defp spiked(card, attrs) do
    case Util.fetch(attrs, :profile) do
      profile when is_binary(profile) -> %{card | profile: String.trim(profile)}
      _ -> card
    end
  end

  # A pull request is merged at the card's commit (#1976), so one named
  # without a commit leaves the accepted card nothing to merge at. An epic
  # naming a PR its subcard already merged has nothing to merge (#1917).
  defp missing_commit?(card, attrs) do
    pr = Util.given(attrs, :evidence_pr, card.evidence_pr)

    not Util.present?(Util.given(attrs, :evidence_commit, card.evidence_commit)) and
      not (Epics.epic?(card) and Epics.subcard_merged?(card, pr))
  end

  # Reopened on a board that asks for evidence: what it carried was for the
  # completion that is being undone (and was kept as a comment then).
  defp clear_evidence(%Card{completed: true} = card, attrs) do
    if Enum.member?([false, "false"], Util.fetch(attrs, :completed)) and Evidence.evidence?(card) and
         Util.board(card).evidence_required,
       do: attrs |> Util.stringify() |> Map.merge(Evidence.no_evidence()),
       else: attrs
  end

  defp clear_evidence(_card, attrs), do: attrs

  @doc """
  The message an agent gets moving a card into a done list with no evidence
  on a board that asks for it, or nil when it may.
  """
  def check_done_move(%Card{completed: false} = card, %Column{} = to, actor) do
    if Column.done?(to) and Actors.gated?(actor) and not Evidence.evidence?(card) and
         Util.board(card).evidence_required,
       do:
         "this board asks for evidence when an agent completes a card: complete card ##{card.id} " <>
           "with what you checked (`evidence`, and `evidence_commit`) rather than moving it"
  end

  def check_done_move(_card, _to, _actor), do: nil

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
    lines = changed_lines(Util.fetch(attrs, :changed_lines))
    files = with :invalid <- changed_files(Util.fetch(attrs, :changed_files)), do: []

    if Util.completes?(card, attrs) and Actors.gated?(actor) and
         (is_integer(lines) or files != []) and
         Util.board(card).profiles do
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
    case Util.fetch(attrs, :profile) do
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
    lines = Util.fetch(attrs, :changed_lines)
    files = Util.fetch(attrs, :changed_files)

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
      if Actors.gated?(actor),
        do: Enum.uniq(mine ++ added) -- (before -- now),
        else: mine -- (added ++ (before -- now))

    ids = Enum.filter(ids, &Enum.member?(now, &1))

    if Enum.sort(ids) != Enum.sort(mine) do
      import Ecto.Query
      Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [agent_assignee_ids: ids])
    end

    :ok
  end

  def assigned(_card, _before, _now, _actor), do: :ok

  ## Verification -------------------------------------------------------------

  # What a completion means on a board that verifies work.
  defp verification(attrs, %Card{} = card, actor) do
    cond do
      not Util.completes?(card, attrs) ->
        {attrs, []}

      Actors.gated?(actor) and Util.board(card).verify_work ->
        # Submitted: open, pending, flagged for review.
        attrs =
          attrs
          |> Util.stringify()
          |> Map.delete("completed")
          |> Map.put("flags", Enum.uniq(Util.given(attrs, :flags, card.flags) ++ ["review"]))

        {attrs,
         verify_state: "pending",
         verify_submitter: Actors.actor_map(actor),
         verify_by: nil,
         verify_note: nil,
         verify_commit: nil,
         verify_at: Util.now()}

      card.verify_state == "pending" and not Actors.gated?(actor) ->
        # A person (or a rule) completing a pending card accepts it.
        {attrs
         |> Util.stringify()
         |> Map.put("flags", Util.given(attrs, :flags, card.flags) -- ["review"]),
         verify_state: "accepted", verify_by: Actors.actor_map(actor), verify_at: Util.now()}

      true ->
        {attrs, []}
    end
  end
end
