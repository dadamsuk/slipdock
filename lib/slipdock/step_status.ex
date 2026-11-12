defmodule Slipdock.StepStatus do
  @moduledoc """
  The step an agent-worked card is at, posted by the server as a status
  update (#2022), so the card's status says where it stands without an
  agent having to remember to say so.

  Each step is an **On track** update with a short body and no user (the
  byline says *Slipdock*), written where the transition already happens:

    * a build job claimed (`Slipdock.Runners.claim/2`) — `Writing code`, or
      `Reworking after verify failed` on a card a verifier sent back;
    * a verify job claimed — `Verifying`;
    * a wait opened (`Slipdock.Boards.Waits.open_wait/3`) — `Waiting for human`,
      or `Waiting for human (rejection limit)` / `Waiting for human (held
      before merge)` for the server's own waits;
    * submitted for verification (`Slipdock.Boards.Cards.update_card/3`, beside
      `Slipdock.Verified.saved/3`) — `Verifying` when the board queues a
      verify job, `Waiting for human to accept` when it has no verify pool;
    * rejected — `Verify failed; queued for rework`;
    * accepted and held for a person — `Waiting for human (held before
      merge)`;
    * accepted on a pull-request board — `Accepted; merging`; the merge
      completing it — `Merged`; any other completion — `Done`; reopened —
      `Reopened`;
    * a deploy that succeeded names it (`Slipdock.Deployments`) —
      `Shipped to <environment>`.

  The verification steps and a claim are agent steps by nature. A wait, a
  completion, a reopening and a deploy are steps only on a card an agent is
  working (`worked?/2`: an agent did it, or the card already has a server
  step or a runner job), so a person's own plain card never gains an *On
  track* it didn't state.

  The same body twice in a row is posted once. These are routine, so they
  go in quietly (`Slipdock.Boards.StatusUpdates.add_status_update/4` with `quiet: true`):
  no activity line, so nothing a watcher follows hears of them. A person's
  own status update still does.
  """

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, StatusUpdate, Wait}
  alias Slipdock.Repo

  @writing "Writing code"
  @rework "Reworking after verify failed"
  @verifying "Verifying"
  @to_accept "Waiting for human to accept"
  @waiting "Waiting for human"
  @limit "Waiting for human (rejection limit)"
  @held "Waiting for human (held before merge)"
  @rejected "Verify failed; queued for rework"
  @merging "Accepted; merging"
  @merged "Merged"
  @done "Done"
  @reopened "Reopened"

  @doc "Every step text the server posts, but the shipped ones (`shipped_text/1`)."
  def texts,
    do: [
      @writing,
      @rework,
      @verifying,
      @to_accept,
      @waiting,
      @limit,
      @held,
      @rejected,
      @merging,
      @merged,
      @done,
      @reopened
    ]

  @doc "The step a deploy to `environment` posts."
  def shipped_text(environment), do: "Shipped to #{environment}"

  ## Events ------------------------------------------------------------------

  @doc """
  A runner took `job` for its card: `Writing code` (or the rework), or
  `Verifying` for a verify job. A merge job says nothing: the acceptance
  already said `Accepted; merging`. Nothing on a finished card (an audit).
  """
  def claimed(%{card_id: card_id, kind: kind}) when is_integer(card_id) do
    case Repo.get(Card, card_id) do
      %Card{completed: false} = card -> post(card, claimed_text(card, kind))
      _ -> :ok
    end
  end

  def claimed(_job), do: :ok

  defp claimed_text(card, kind) do
    cond do
      kind == Slipdock.Verified.verify_kind() -> @verifying
      kind == Slipdock.Verified.merge_kind() -> nil
      card.verify_state == "rejected" -> @rework
      true -> @writing
    end
  end

  @doc "A wait opened on `card`: waiting for a person, and why when the server opened it."
  def wait_opened(%Card{} = card, %Wait{purpose: purpose, kind: kind}) do
    cond do
      purpose == Slipdock.Verified.limit_purpose() -> post(card, @limit)
      purpose == Slipdock.Verified.held_purpose() -> post(card, @held)
      worked?(card, %{kind: kind}) -> post(card, @waiting)
      true -> :ok
    end
  end

  def wait_opened(_card, _wait), do: :ok

  @doc """
  `before` was saved as `card` (`Slipdock.Boards.Cards.update_card/3`): a change
  of verification state, a completion or a reopening is a step.
  """
  def saved(%Card{} = before, %Card{} = card, actor \\ nil) do
    case saved_text(before, card) do
      {:if_worked, text} -> if worked?(card, actor), do: post(card, text), else: :ok
      text -> post(card, text)
    end
  end

  # A completion or reopening outside verification: a step only on a card
  # an agent is working.
  defp saved_text(%{verify_state: same} = before, %{verify_state: same} = card) do
    cond do
      card.completed and not before.completed -> {:if_worked, @done}
      before.completed and not card.completed -> {:if_worked, @reopened}
      true -> nil
    end
  end

  defp saved_text(_before, %{verify_state: "pending"} = card) do
    cond do
      # A docs card (#1953) is accepted by the server straight after.
      Slipdock.Verified.not_verified?(card) -> nil
      verify_pool?(card) -> @verifying
      true -> @to_accept
    end
  end

  defp saved_text(_before, %{verify_state: "rejected"}), do: @rejected
  defp saved_text(_before, %{verify_state: "held"}), do: @held
  defp saved_text(_before, %{verify_state: "merging"}), do: @merging

  defp saved_text(%{verify_state: "merging"}, %{verify_state: "accepted", completed: true}),
    do: @merged

  defp saved_text(_before, %{verify_state: "accepted", completed: true}), do: @done

  defp saved_text(before, card) do
    if before.completed and not card.completed, do: {:if_worked, @reopened}
  end

  defp verify_pool?(%Card{board_id: id}) do
    case Repo.get(Board, id) do
      %Board{verify_work: true, verify_pool: pool} when is_binary(pool) and pool != "" -> true
      _ -> false
    end
  end

  @doc """
  A deploy succeeded: each card it names gets `Shipped to <environment>`.
  A rollback, or a deploy backfilled from old runs, posts nothing.
  """
  def shipped(%{status: "succeeded", rollback: false, card_ids: ids, environment: env} = d)
      when is_list(ids) and ids != [] do
    if Map.get(d, :source) != "backfill" do
      from(c in Card, where: c.id in ^ids)
      |> Repo.all()
      |> Enum.filter(&worked?(&1, nil))
      |> Enum.each(&post(&1, shipped_text(env)))
    end

    :ok
  end

  def shipped(_deployment), do: :ok

  @doc """
  Whether `card` is one an agent is working: `actor` is an agent (or the
  server's own automation), or the card already has a step the server
  posted, or a runner job was sent for it.
  """
  def worked?(%Card{id: id}, actor) do
    agent?(actor) or
      Repo.exists?(from u in StatusUpdate, where: u.card_id == ^id and is_nil(u.user_id)) or
      Repo.exists?(from j in Slipdock.Runners.Job, where: j.card_id == ^id)
  end

  defp agent?(%{kind: kind}) when kind in ["agent", "automation"], do: true
  defp agent?(_actor), do: false

  ## Posting -----------------------------------------------------------------

  @doc false
  # The step as an On track update with no user, unless it is the body the
  # card's latest update already has.
  def post(_card, nil), do: :ok

  def post(%Card{} = card, text) when is_binary(text) do
    if latest_body(card.id) == text do
      :ok
    else
      case Boards.StatusUpdates.add_status_update(
             card,
             nil,
             %{"health" => "on_track", "body" => text},
             quiet: true
           ) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  defp latest_body(card_id) do
    Repo.one(
      from u in StatusUpdate,
        where: u.card_id == ^card_id,
        order_by: [desc: u.inserted_at, desc: u.id],
        limit: 1,
        select: u.body
    )
  end
end
