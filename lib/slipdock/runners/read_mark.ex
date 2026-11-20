defmodule Slipdock.Runners.ReadMark do
  @moduledoc """
  What a runner job's own reads are held to while it runs (#3520).

  A job's agent reads more text than its prompt, over the CLI and MCP,
  sending its job's id (`x-slipdock-job`, from `$SLIPDOCK_JOB_ID`). A read
  of a card made under a job the reader's runner holds:

  - returns the job's own card as it was at claim: its title, description
    and bar as the claim saw them (`claim_text`), and none of the comments
    written after the claim, with `as_at_claim` saying when that was;
  - marks the job (`marked_at`, `mark_reason`) when the text it returns has
    an author less trusted than the job's tier at claim (`prompt_tier`,
    `Slipdock.Runners.TrustTier`): the card's title, description and bar
    (not counted again for the job's own card, whose text at claim made the
    tier) and its comments. A comment with no author is the server's own.

  A mark stays for the rest of the run. The machine's `PreToolUse` hook asks
  for it with the job's hook key, given to the daemon at claim (`on_claim/1`
  and `GET /api/runner/jobs/:id/mark`), and refuses the shell, the network
  and pushing from then on. A job that reads only text as trusted as its
  tier is never marked.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Repo
  alias Slipdock.Runners.{Job, Quarantine, Runner, TrustTier}

  @key_prefix "sdh_"
  @text_fields ~w(title description bar)

  @doc """
  Called as `job` is claimed: keeps its tier, its card's text and the hash
  of a new hook key, clears any earlier run's mark, and answers
  `{tier, key}` for the claim's headers.
  """
  @spec on_claim(Job.t()) :: {String.t(), String.t()}
  def on_claim(%Job{} = job) do
    tier = TrustTier.of(job)
    key = @key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    Repo.update_all(from(j in Job, where: j.id == ^job.id),
      set: [
        prompt_tier: tier,
        claim_text: claim_text(job),
        hook_key_hash: hash(key),
        marked_at: nil,
        mark_reason: nil
      ]
    )

    {tier, key}
  end

  defp claim_text(%Job{card_id: nil}), do: nil

  defp claim_text(%Job{card_id: id}) do
    case Repo.get(Card, id) do
      nil -> nil
      card -> %{"title" => card.title, "description" => card.description, "bar" => card.bar}
    end
  end

  defp hash(key), do: :crypto.hash(:sha256, key)

  @doc """
  The job `id` names, when `key` is its hook key: `{:ok, job}`, else
  `{:error, :unauthorized}` (no such job, no key, or another).
  """
  @spec authenticate(term, term) :: {:ok, Job.t()} | {:error, :unauthorized}
  def authenticate(id, key) do
    with true <- is_binary(key) and String.starts_with?(key, @key_prefix),
         {id, ""} <- Integer.parse(to_string(id)),
         %Job{hook_key_hash: stored} = job when is_binary(stored) <- Repo.get(Job, id),
         true <- Plug.Crypto.secure_compare(hash(key), stored) do
      {:ok, job}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  The open job `job_id` that `user`'s runner holds, which a read sending it
  is made under, or nil: no id, no such job, one that has ended, or one on
  another person's runner.
  """
  @spec reading_job(term, User.t() | nil) :: Job.t() | nil
  def reading_job(job_id, %User{id: user_id}) when is_integer(job_id) do
    with %Job{status: status, runner_id: runner_id} = job
         when status in ["claimed", "running"] and is_integer(runner_id) <-
           Repo.get(Job, job_id),
         %Runner{} = runner <- Repo.get(Runner, runner_id) |> Repo.preload(:machine),
         true <- Enum.member?(runner_people(runner), user_id) do
      job
    else
      _ -> nil
    end
  end

  def reading_job(_job_id, _user), do: nil

  defp runner_people(%Runner{} = runner) do
    machine_user = if runner.machine, do: runner.machine.user_id
    Enum.reject([runner.created_by_id, machine_user], &is_nil/1)
  end

  @doc """
  `read_card/2` under the job a read names (`job_id`, from
  `x-slipdock-job`), when it is one `user`'s runner holds.
  """
  @spec read_card_as(Card.t(), term, User.t() | nil) :: {Card.t(), DateTime.t() | nil}
  def read_card_as(%Card{} = card, job_id, user),
    do: read_card(card, reading_job(job_id, user))

  @doc """
  The job a read of `card` naming `job_id` is made under, when that read
  gives the job's quarantined read rather than the card (#3535): the job's
  own card, on a job whose card text the claim quoted through
  `Slipdock.Runners.Quarantine` (`card_read_quarantined?/1`). Else nil, and
  the read goes through `read_card_as/3`. Such a read returns none of the
  card's text, so it marks nothing.
  """
  @spec quarantined_job(Card.t(), term, User.t() | nil) :: Job.t() | nil
  def quarantined_job(%Card{id: card_id}, job_id, user) do
    case reading_job(job_id, user) do
      %Job{card_id: ^card_id} = job ->
        if Quarantine.card_read_quarantined?(job), do: job

      _ ->
        nil
    end
  end

  @doc "Puts `as_at_claim` on a card's JSON when the read was held to a claim."
  @spec put_as_at_claim(map, DateTime.t() | nil) :: map
  def put_as_at_claim(map, nil), do: map
  def put_as_at_claim(map, at), do: Map.put(map, :as_at_claim, at)

  @doc """
  `card` (its comments loaded) as a read made under `job` returns it, and
  when that read is held to the claim (nil when it isn't). Marks `job`
  when the text returned has a less-trusted author. Without a job, the card
  as it is.
  """
  @spec read_card(Card.t(), Job.t() | nil) :: {Card.t(), DateTime.t() | nil}
  def read_card(%Card{} = card, nil), do: {card, nil}

  def read_card(%Card{} = card, %Job{} = job) do
    own? = card.id == job.card_id
    card = if own?, do: at_claim(card, job), else: card

    text_ids =
      if own? and is_map(job.claim_text), do: [], else: TrustTier.text_authors(card)

    mark_if_less_trusted(job, card, text_ids ++ comment_authors(card))
    {card, if(own?, do: job.claimed_at)}
  end

  defp at_claim(card, %Job{claimed_at: claimed_at} = job) do
    card
    |> put_claim_text(job.claim_text)
    |> then(fn card ->
      if Ecto.assoc_loaded?(card.comments) and claimed_at do
        %{card | comments: Enum.reject(card.comments, &after?(&1.inserted_at, claimed_at))}
      else
        card
      end
    end)
  end

  defp after?(%DateTime{} = at, claimed_at), do: DateTime.compare(at, claimed_at) == :gt
  defp after?(_at, _claimed_at), do: false

  defp put_claim_text(card, %{} = text) do
    Enum.reduce(@text_fields, card, fn field, card ->
      if Map.has_key?(text, field),
        do: Map.put(card, String.to_existing_atom(field), text[field]),
        else: card
    end)
  end

  defp put_claim_text(card, _text), do: card

  defp comment_authors(%Card{comments: comments}) when is_list(comments),
    do: Enum.flat_map(comments, &comment_author/1)

  defp comment_authors(_card), do: []

  # A comment the server wrote has no author: its own text. One sent on a
  # permitted sender's behalf opens "*Sent by ": someone with no account.
  defp comment_author(%Comment{body: "*Sent by " <> _}), do: [0]
  defp comment_author(%Comment{user_id: id}) when is_integer(id), do: [id]
  defp comment_author(_comment), do: []

  defp mark_if_less_trusted(_job, _card, []), do: :ok

  defp mark_if_less_trusted(%Job{} = job, card, ids) do
    tier = job.prompt_tier || TrustTier.of(job)
    least = TrustTier.least_of(ids, job)

    if TrustTier.less_trusted?(least, tier) do
      mark(job, "read card ##{card.id}, with text by #{least} (the job is #{tier})")
    else
      :ok
    end
  end

  @doc "Marks `job`, keeping the first mark's time and reason."
  @spec mark(Job.t(), String.t()) :: :ok
  def mark(%Job{id: id}, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(j in Job, where: j.id == ^id and is_nil(j.marked_at)),
      set: [marked_at: now, mark_reason: String.slice(reason, 0, 250)]
    )

    :ok
  end

  @doc "`{:marked, reason}` or `:clear`, as the job stands now."
  @spec state(Job.t()) :: {:marked, String.t()} | :clear
  def state(%Job{id: id}) do
    case Repo.one(from(j in Job, where: j.id == ^id, select: {j.marked_at, j.mark_reason})) do
      {%DateTime{}, reason} -> {:marked, reason || "marked"}
      _ -> :clear
    end
  end
end
