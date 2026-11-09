defmodule Slipdock.CardAuthors do
  @moduledoc """
  Who created a card and who changed it last, and when (#2028).

  `for_card/1` gives

      %{created_by: who | nil, created_at: DateTime,
        updated_by: who | nil, updated_at: DateTime}

  where `who` is `%{kind: "person" | "agent" | "runner" | "automation",
  name: String.t(), user_id: integer | nil}` (plus `job_id` for a runner).
  `nil` means nobody is recorded, and the time is shown alone: it is never
  guessed.

    * **Created by** comes from the card's `created` row in the movement
      ledger (`Slipdock.Boards.CardMove`), which records the actor. A
      `backfilled` row, or a card with no row at all (older than the
      ledger), has no actor. A runner job's agent is named for its runner
      loop (`"Dev server loop"`, from `Job.runner_name`); an agent otherwise
      by its token label; an automation by its rule's name, which the
      ledger doesn't keep, so it is read from the card's first activity row.
      Every door stamps the row with its actor, the web's with the person
      behind the page (#2094); a row written with no actor (the web's
      creates, before #2094) takes its actor from that first activity row
      too, which is stamped.
    * **Last changed** is the later of the card's newest activity row (every
      change logs one, stamped with its actor since #1735: fields, moves,
      comments, checklist, attachments, flags) and the card's own
      `updated_at`. The row's actor counts when the row is that late, or
      within `@slack` seconds of `updated_at` (the row and the card are
      written in the same breath); a card changed later than its newest row
      shows the time alone. A card never changed since it was made is last
      changed by whoever made it.
  """

  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Activity, Card, CardMove}
  alias Slipdock.Repo
  alias Slipdock.Runners.Job

  # How far apart a change's activity row and the card's `updated_at` can
  # be and still be the same change, in seconds.
  @slack 2

  @doc "Who created `card` and who changed it last, and when (see the moduledoc)."
  def for_card(%Card{} = card) do
    move = created_move(card.id)
    created_by = if move, do: creator(move, card.id)
    created_at = card.inserted_at
    {updated_by, updated_at} = last_change(card, latest_activity(card.id), created_by)

    %{
      created_by: created_by,
      created_at: created_at,
      updated_by: updated_by,
      updated_at: updated_at
    }
  end

  @doc """
  The `who` as it reads after "by": its name. A runner reads as its loop
  ("Dev server loop"), a rule by its name.
  """
  def name(%{name: name}), do: name
  def name(_), do: nil

  ## Created by --------------------------------------------------------------

  defp created_move(card_id) do
    Repo.one(
      from(m in CardMove,
        where: m.card_id == ^card_id and m.kind == "created",
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: 1
      )
    )
  end

  defp creator(%CardMove{backfilled: true}, _card_id), do: nil

  defp creator(%CardMove{actor_kind: "human", user_id: id}, _card_id) when is_integer(id) do
    case Repo.get(User, id) do
      nil -> nil
      user -> %{kind: "person", name: User.display_name(user), user_id: id}
    end
  end

  defp creator(%CardMove{actor_kind: "agent", job_id: job_id} = move, _card_id)
       when is_integer(job_id) do
    case runner_name(job_id) do
      nil -> agent(move)
      runner -> %{kind: "runner", name: loop_name(runner), user_id: move.user_id, job_id: job_id}
    end
  end

  defp creator(%CardMove{actor_kind: "agent"} = move, _card_id), do: agent(move)

  defp creator(%CardMove{actor_kind: "automation"}, card_id) do
    %{kind: "automation", name: rule_name(card_id) || "An automation rule", user_id: nil}
  end

  # A ledger row written with no actor (the web's creates wrote these
  # until #2094 stamped them with the process's actor) is filled in from the
  # card's first activity row, which every door stamps with the process's
  # actor: a record, not a guess. An unstamped row is nobody.
  defp creator(%CardMove{actor_kind: nil}, card_id), do: card_id |> first_activity() |> actor()

  defp creator(_move, _card_id), do: nil

  defp agent(move),
    do: %{kind: "agent", name: present(move.agent) || agent_name(move.via), user_id: move.user_id}

  defp agent_name("assistant"), do: "Assistant"
  defp agent_name(_), do: "An agent"

  defp runner_name(job_id) do
    Repo.one(from(j in Job, where: j.id == ^job_id, select: j.runner_name)) |> present()
  end

  @doc "A runner's loop as a card names it: \"Dev server loop\"."
  def loop_name(runner), do: runner <> " loop"

  # The rule that made the card is on its first activity row; the ledger
  # keeps only that it was an automation.
  defp rule_name(card_id) do
    case first_activity(card_id) do
      %Activity{actor_kind: "automation", actor_name: name} -> present(name)
      _ -> nil
    end
  end

  defp first_activity(card_id) do
    Repo.one(
      from(a in Activity,
        where: a.card_id == ^card_id,
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: 1
      )
    )
  end

  ## Last changed ------------------------------------------------------------

  defp latest_activity(card_id) do
    Repo.one(
      from(a in Activity,
        where: a.card_id == ^card_id,
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: 1
      )
    )
  end

  # No activity: the card's own time, and its maker if it was never touched.
  defp last_change(card, nil, created_by) do
    updated = card.updated_at || card.inserted_at

    if same_time?(updated, card.inserted_at),
      do: {created_by, updated},
      else: {nil, updated}
  end

  defp last_change(card, %Activity{} = row, _created_by) do
    updated = card.updated_at || card.inserted_at
    at = row.inserted_at

    cond do
      DateTime.compare(at, updated) != :lt -> {actor(row), at}
      same_time?(at, updated) -> {actor(row), updated}
      true -> {nil, updated}
    end
  end

  defp same_time?(a, b), do: abs(DateTime.diff(a, b, :second)) <= @slack

  defp actor(%Activity{actor_kind: kind, actor_name: name, user_id: id})
       when kind in ~w(person email) do
    if n = present(name), do: %{kind: "person", name: n, user_id: id}
  end

  defp actor(%Activity{actor_kind: "agent", actor_name: name, user_id: id}),
    do: %{kind: "agent", name: present(name) || "An agent", user_id: id}

  defp actor(%Activity{actor_kind: "automation", actor_name: name}),
    do: %{kind: "automation", name: present(name) || "An automation rule", user_id: nil}

  defp actor(_row), do: nil

  defp present(s) when is_binary(s) and s != "", do: s
  defp present(_), do: nil
end
