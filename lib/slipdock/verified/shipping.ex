defmodule Slipdock.Verified.Shipping do
  @moduledoc """
  How a card's work ships, by push or by pull request: whether a pending
  card has released its lane, the branch its work goes on, and what its
  builder is told about shipping it.
  """

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Epics, Util}

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
    do: not Board.ships_by_pr?(board || Util.board(card))

  def released?(_card, _board), do: false

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
      Board.ships_by_pr?(Util.board(card)) -> pr_instructions(card)
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
    #{if Epics.epic?(card), do: epic_note(card), else: ""}
    """
    |> String.trim_trailing()
  end

  @doc """
  The ship instructions' line on a board with profiles on (#2017): give the
  change with the completion, so the profile is checked against it. Empty
  (no line) with profiles off.
  """
  def profiles_note(%Card{} = card) do
    if Util.board(card).profiles,
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
    case card |> Util.board() |> Slipdock.Handbook.before_you_push() do
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
end
