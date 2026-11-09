defmodule Slipdock.Verified.Circling do
  @moduledoc """
  A card going round in circles (#2047): rejected a second time, or
  rejected again for a rule id an earlier rejection named. The rejection
  that shows it (`Slipdock.Verified.decide/5`) keeps the card flagged
  `review` (a rejection otherwise takes the flag off) until it is
  accepted, posts a *Going round in circles* comment with the rounds and
  the parts each failed, and tells the root board's owner: a warning
  alert on the root board, and an email to the owner and to the people
  the tree routes `release` questions to (`Slipdock.WaitRoutes`).

  The card is still sent for rework as any rejected card is; the flag is
  what puts it at the top of the owner's *Waiting on you*
  (`Slipdock.Work.waiting_on_me/2`, reason `circling`). It fires on the
  event, not on the gardener's schedule. A failed merge counts towards
  the two (it adds to `verify_rejections`; one that found the pull request
  already merged doesn't, #2637), but only a verifier's rejection fires it.
  """

  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo

  # A handbook rule's id, as a failing part is labelled (`UX-4`, `ARCH-12`).
  @rule_id ~r/^[A-Z][A-Z0-9]*-\d+$/

  @doc "How many rejections make a card circling: the second, whatever it failed."
  def threshold, do: 2

  @doc """
  Whether `card` is circling now: rejected `threshold/0` times or more,
  still flagged `review`, and not yet accepted (rejected, or resubmitted
  and pending). A person taking the flag off says they have seen it.
  """
  def circling?(%Card{} = card) do
    (card.verify_rejections || 0) >= threshold() and Enum.member?(card.flags, "review") and
      Enum.member?(~w(rejected pending), card.verify_state) and not card.completed and
      is_nil(card.archived_at)
  end

  @doc """
  The rule ids the newest of `rounds` (each rejection oldest first, as
  `{reason, failing parts}`) failed on that an earlier one failed on too.
  """
  def repeated_rules(rounds) do
    case Enum.reverse(rounds) do
      [{_, latest} | earlier] ->
        before = earlier |> Enum.flat_map(&rule_ids(elem(&1, 1))) |> MapSet.new()
        latest |> rule_ids() |> Enum.filter(&MapSet.member?(before, &1)) |> Enum.uniq()

      [] ->
        []
    end
  end

  @doc "The handbook rule ids among failing part labels."
  def rule_ids(labels), do: Enum.filter(labels, &Regex.match?(@rule_id, &1))

  @doc """
  Whether the `count`th rejection, with `rounds` every rejection so far
  (this one last), shows the card circling: the second, or one repeating a
  rule id.
  """
  def fires?(count, rounds), do: count == threshold() or repeated_rules(rounds) != []

  @doc """
  After a verifier's rejection, the `count`th: when it `fires?/2`, the
  comment, the alert and the emails. Returns `:fired` or `:quiet`.
  """
  def after_rejection(%Card{} = card, count, rounds, user) do
    if fires?(count, rounds) do
      tell(card, count, rounds, user)
      :fired
    else
      :quiet
    end
  end

  defp tell(card, count, rounds, user) do
    repeated = repeated_rules(rounds)
    Slipdock.Boards.add_comment(card, comment_body(count, rounds, repeated), by: user)

    root = root(card)

    title =
      String.slice("Card ##{card.id} is going round in circles: #{count} rejections", 0, 200)

    body = alert_body(card, count, rounds, repeated)

    Slipdock.Automations.raise_alert(%{
      "board_id" => root.id,
      "card_id" => card.id,
      "severity" => "warning",
      "title" => title,
      "body" => body
    })

    email(card, root, title, body)
  end

  @doc "The *Going round in circles* comment's body."
  def comment_body(count, rounds, repeated) do
    "**Going round in circles:** rejected #{count} times, in #{count} rounds of verification." <>
      "\n\n" <>
      rounds_list(rounds) <>
      "\n\n" <>
      repeat_line(repeated) <>
      " Flagged `review` until it is accepted, and the board's owner has been told. " <>
      "Before another round of fixes, decide whether the card needs a different approach " <>
      "or a reworded bar."
  end

  defp rounds_list(rounds) do
    rounds
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{_, failed}, n} -> "#{n}. #{parts(failed)}" end)
  end

  defp parts([]), do: "(no part named)"
  defp parts(failed), do: Enum.join(failed, ", ")

  defp repeat_line([]), do: "No rule was failed twice."
  defp repeat_line([id]), do: "#{id} was failed again."
  defp repeat_line(ids), do: "#{Enum.join(ids, ", ")} were failed again."

  defp alert_body(card, count, rounds, repeated) do
    rules = rounds |> Enum.flat_map(&rule_ids(elem(&1, 1))) |> Enum.uniq()

    String.slice(
      "“#{card.title}” has been rejected #{count} times. Rules failed: " <>
        if(rules == [], do: "none", else: Enum.join(rules, ", ")) <>
        ". " <>
        repeat_line(repeated) <>
        " Each round: " <> String.replace(rounds_list(rounds), "\n", "; "),
      0,
      1000
    )
  end

  # The root board's owner, and the people `release` is routed to.
  defp email(card, root, subject, body) do
    owner = root.owner_id && Repo.get(Slipdock.Accounts.User, root.owner_id)

    emails =
      ([owner] ++ Slipdock.WaitRoutes.users_for(card, "release"))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.email)
      |> Enum.uniq()

    if emails != [] do
      Slipdock.Deferred.defer(fn ->
        Slipdock.Automations.Notifier.deliver(emails, subject, body, card: card)
      end)
    end

    :ok
  end

  defp root(%Card{board_id: id}) do
    board = Repo.get!(Board, id)
    if board.root_id, do: Repo.get(Board, board.root_id) || board, else: board
  end
end
