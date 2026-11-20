defmodule Slipdock.Runners.TrustTier do
  @moduledoc """
  How far a job's prompt can be trusted (#3516): the least-trusted author
  of the text in it, as one of three tiers, sent with the job at claim.

  - `owner`: the owner of the card's board tree wrote all of it, or it is
    the server's own text;
  - `member`: someone else who may write or comment on the card;
  - `anyone`: anyone else, such as a permitted email sender, a person whose
    access has since gone, or an author the server can't name.

  The authors counted are the people who wrote the card's title,
  description and bar (`Card.text_by`, kept by `track/4`), the rule that
  queued the job, and, for a job that isn't a verify, whoever rejected the
  card, opened or answered its wait, and left its handoff.

  The server only reports the tier. The machine decides what each tier may
  do, in its ceiling's `tiers` (W-1945 §The runner daemon).
  """

  import Ecto.Query

  alias Slipdock.{Access, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.{Board, Card, CardMove}
  alias Slipdock.Runners.Job

  @tiers ~w(owner member anyone)

  # The text fields whose author counts.
  @text_fields [:title, :description, :bar]

  @doc "The tiers, most trusted first."
  def tiers, do: @tiers

  @doc """
  Records the writer on a card changeset that sets its title, description
  or bar: `card` is the card before the change (nil for a new one),
  `writer` the actor making it. `outside: true` (a mail sent on a permitted
  sender's behalf) records someone with no account here.
  """
  @spec track(Ecto.Changeset.t(), Card.t() | nil, map | nil, keyword) :: Ecto.Changeset.t()
  def track(%Ecto.Changeset{} = changeset, card, writer, opts \\ []) do
    if Enum.any?(@text_fields, &Map.has_key?(changeset.changes, &1)) do
      base = earlier(card)

      case writer_id(writer, opts) do
        nil when is_nil(card) -> Ecto.Changeset.put_change(changeset, :text_by, base)
        nil -> changeset
        id -> Ecto.Changeset.put_change(changeset, :text_by, Enum.uniq(base ++ [id]))
      end
    else
      changeset
    end
  end

  defp writer_id(writer, opts) do
    cond do
      opts[:outside_author] -> 0
      match?(%{user_id: id} when is_integer(id), writer) -> writer.user_id
      true -> nil
    end
  end

  @doc """
  The ids of the people who wrote `card`'s title, description and bar (0
  for someone with no account here).
  """
  @spec text_authors(Card.t()) :: [integer]
  def text_authors(%Card{} = card), do: earlier(card)

  @doc """
  The least-trusted tier among `ids`, as authors on `job`'s card: the
  owner of its board tree is `owner`, someone who may write or comment on
  the card `member`, anyone else (and 0) `anyone`. No ids is `owner`.
  """
  @spec least_of([integer], Job.t()) :: String.t()
  def least_of(ids, %Job{} = job) do
    card = (job.card_id && Repo.get(Card, job.card_id)) || []
    owner_id = owner_id(card, job)

    ids
    |> Enum.uniq()
    |> Enum.map(&tier_of(&1, owner_id, card))
    |> Enum.max_by(&rank/1, fn -> "owner" end)
  end

  @doc "Whether tier `a` is less trusted than tier `b` (an unknown word is `anyone`)."
  @spec less_trusted?(String.t(), String.t() | nil) :: boolean
  def less_trusted?(a, b), do: rank(a) > rank(b)

  defp earlier(nil), do: []
  defp earlier(%Card{text_by: ids}) when is_list(ids), do: ids
  defp earlier(%Card{id: id}), do: creators(id)

  # A card from before `text_by` was kept: whoever created it, and someone
  # with no account here when a permitted sender's mail made it.
  defp creators(card_id) do
    from(m in CardMove,
      where: m.card_id == ^card_id and m.kind == "created",
      select: {m.user_id, m.via}
    )
    |> Repo.all()
    |> Enum.flat_map(fn
      {nil, _via} -> []
      {id, "email"} -> if sent_on_behalf?(card_id), do: [id, 0], else: [id]
      {id, _via} -> [id]
    end)
  end

  defp sent_on_behalf?(card_id) do
    case Repo.one(from(c in Card, where: c.id == ^card_id, select: c.description)) do
      text when is_binary(text) -> String.starts_with?(text, "*Sent by ")
      _ -> false
    end
  end

  @doc """
  The tier of `job`'s prompt: `"owner"`, `"member"` or `"anyone"`.
  """
  @spec of(Job.t()) :: String.t()
  def of(%Job{kind: kind}) when kind in ["merge", "overseer", "probe"], do: "owner"
  def of(%Job{card_id: nil} = job), do: least([], job)

  def of(%Job{} = job) do
    case Repo.get(Card, job.card_id) do
      nil -> "anyone"
      %Card{} = card -> least(card, job)
    end
  end

  defp least(card, job) do
    owner_id = owner_id(card, job)

    (card_authors(card, job) ++ rule_author(job))
    |> Enum.uniq()
    |> Enum.map(&tier_of(&1, owner_id, card))
    |> Enum.max_by(&rank/1, fn -> "owner" end)
  end

  defp owner_id(%Card{board_id: board_id}, _job), do: board_owner(board_id)

  defp owner_id(_card, %Job{board_id: board_id}) when is_integer(board_id),
    do: board_owner(board_id)

  defp owner_id(_card, _job), do: nil

  defp board_owner(board_id) do
    case Repo.get(Board, board_id) do
      nil -> nil
      board -> Board.root_owner_id(board)
    end
  end

  defp card_authors([], _job), do: []

  defp card_authors(%Card{} = card, %Job{kind: "verify"}), do: earlier(card)

  defp card_authors(%Card{} = card, %Job{} = job) do
    context = Slipdock.Runners.claim_context(job)

    earlier(card) ++
      rejecter(card) ++
      ids([
        context.wait && context.wait.opened_by_id,
        context.wait && context.wait.closed_by_id,
        context.handoff && context.handoff.user_id
      ])
  end

  defp rejecter(%Card{verify_state: "rejected", verify_by: %{"user_id" => id}})
       when is_integer(id),
       do: [id]

  defp rejecter(_card), do: []

  defp rule_author(%Job{rule_id: nil}), do: []

  defp rule_author(%Job{rule_id: id}) do
    ids([Repo.one(from(r in Rule, where: r.id == ^id, select: r.created_by_id))])
  end

  defp ids(list), do: Enum.filter(list, &is_integer/1)

  defp tier_of(0, _owner_id, _card), do: "anyone"
  defp tier_of(id, id, _card), do: "owner"

  defp tier_of(id, _owner_id, %Card{} = card) do
    case Repo.get(User, id) do
      nil ->
        "anyone"

      user ->
        if Enum.member?([:owner, :write, :comment], Access.card_permission(user, card)),
          do: "member",
          else: "anyone"
    end
  end

  defp tier_of(_id, _owner_id, _card), do: "anyone"

  defp rank(tier), do: Enum.find_index(@tiers, &(&1 == tier)) || length(@tiers) - 1
end
