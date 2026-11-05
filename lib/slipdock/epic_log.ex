defmodule Slipdock.EpicLog do
  @moduledoc """
  An epic's comments tell where its work stands (#1881).

  When something happens to a subcard, the server posts one terse line on
  its epic (the nearest top-level ancestor, however deep the subcard sits):
  what happened, to which subcard, and how the epic stands (`2/3 done`):

    * **Started** — the subcard moved into a doing list, by whom (and which
      job);
    * **Submitted** — for verification, with its pull request;
    * **Rejected** — the first line of the reason (a failed merge too);
    * **Accepted** / **Merged** — the pull request and short commit; a merge
      within 60 seconds of the acceptance rewrites that line as one
      **Accepted and merged** line;
    * **Done** — completed on a board that doesn't verify;
    * **Build failed** — a comment on the subcard reporting a red build;
    * **Waiting on a person** / **Answered** — a wait opened and closed;
    * **Shipped** — a deploy the board recorded names it.

  The epic's own submit, rejection, acceptance and merge post the same
  lines on the epic. A card on no epic, or a top-level card with no
  subcards, posts nothing.

  The lines are the server's (no author, `kind: "epic_log"`). One that comes
  within 10 seconds of the epic's last comment, when that comment is one
  of these, joins it instead of making another, so a busy epic reads as a
  few comments rather than dozens.

  The epic's % complete follows its subcards (done ÷ all, rounded down) on
  every change, unless a person has set it by hand (`percent_by_hand`);
  clearing it hands it back.
  """

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, Column, Comment}
  alias Slipdock.Repo

  @kind "epic_log"
  # Lines this close to the epic's last one join it.
  @join_seconds 10
  # An acceptance and its merge this close are one line.
  @merge_seconds 60

  @doc "The `kind` of the comments this module writes."
  def kind, do: @kind

  @doc "How many seconds apart two lines may be and still share a comment."
  def join_seconds, do: @join_seconds

  @doc "How close a merge must follow its acceptance to share its line."
  def merge_seconds, do: @merge_seconds

  ## Events ------------------------------------------------------------------

  @doc "A card moved between lists: into a doing list is **Started**."
  def moved(%Card{} = card, %Column{} = from, %Column{} = to, actor) do
    if doing?(to) and not doing?(from),
      do: post(card, :subcard, "**Started**", by(actor))

    :ok
  end

  # A doing list by its category, else by its name (the guide's reading:
  # the Simple template's "Doing" has no category).
  defp doing?(%Column{} = column), do: Slipdock.Flow.doing_list?(column)

  @doc """
  A card was saved (`Slipdock.Boards.update_card/3`): a change of
  verification state, or a completion outside it, is a line; anything that
  changes what is done recounts the epic.
  """
  def saved(%Card{} = before, %Card{} = card) do
    case event(before, card) do
      nil -> :ok
      {:merged, line} -> merged(card, line)
      {who, text, detail} -> post(card, who, text, detail)
    end

    if before.completed != card.completed or before.archived_at != card.archived_at,
      do: recount(card)

    :ok
  end

  defp event(%{verify_state: same} = before, %{verify_state: same} = card) do
    if card.completed and not before.completed, do: {:subcard, "**Done**", nil}
  end

  defp event(_before, %{verify_state: "pending"} = card),
    do: {:own, "**Submitted** for verification", pr_and_sha(card, card.evidence_commit)}

  defp event(_before, %{verify_state: "rejected"} = card),
    do: {:own, "**Rejected**", first_line(card.verify_note)}

  defp event(_before, %{verify_state: "merging"} = card),
    do: {:own, "**Accepted**", pr_and_sha(card, card.verify_commit || card.evidence_commit)}

  defp event(%{verify_state: "merging"}, %{verify_state: "accepted"} = card),
    do: {:merged, pr_and_sha(card, card.merge_sha)}

  defp event(_before, %{verify_state: "accepted"} = card),
    do: {:own, "**Accepted**", pr_and_sha(card, card.verify_commit || card.evidence_commit)}

  defp event(_before, _card), do: nil

  @doc "A wait opened on a card: **Waiting on a person**, with what it needs."
  def wait_opened(%Card{} = card, wait) do
    post(card, :subcard, "**Waiting on a person**", first_line(Map.get(wait, :needs)))
  end

  @doc "A wait on a card closed: **Answered**, or **Skipped**, by whom."
  def wait_closed(%Card{} = card, how, actor) do
    text = if how == "skipped", do: "**Wait skipped**", else: "**Answered**"
    post(card, :subcard, text, by(actor))
  end

  @doc """
  A comment on a card: one reporting a red build (it opens with `Build
  failed`, bold or not) is a **Build failed** line, with the rest of its
  first line. The server's own lines are never read this way.
  """
  def commented(%Card{} = card, body, kind) when kind != @kind and is_binary(body) do
    first = body |> String.trim_leading() |> String.split(~r/\R/, parts: 2) |> hd()

    case Regex.run(~r/\A\**\s*Build failed\b[*:.\s—-]*(.*)\z/iu, first) do
      [_, rest] -> post(card, :own, "**Build failed**", blank_to_nil(String.trim(rest)))
      _ -> :ok
    end
  end

  def commented(_card, _body, _kind), do: :ok

  @doc """
  A deploy succeeded: each epic it names cards under gets one **Shipped**
  line, naming them, the environment and the commit.
  """
  def shipped(%{card_ids: ids, environment: env, sha: sha}) when is_list(ids) and ids != [] do
    Repo.all(from c in Card, where: c.id in ^ids, order_by: c.id)
    |> Enum.map(&{target(&1, :own), &1})
    |> Enum.reject(&is_nil(elem(&1, 0)))
    |> Enum.group_by(fn {epic, _} -> epic.id end)
    |> Enum.each(fn {_id, [{epic, _} | _] = pairs} ->
      refs = Enum.map_join(pairs, ", ", fn {_, card} -> "##{card.id}" end)
      line = "**Shipped** to #{env} · #{refs} · `#{short(sha)}` · #{count(epic)}"
      write(epic, line)
    end)
  end

  def shipped(_deployment), do: :ok

  ## Posting -----------------------------------------------------------------

  # `who` is :subcard for what only a subcard's line says (started, waits),
  # :own for what the epic's own card posts too (verification, builds).
  defp post(card, who, text, detail) do
    case target(card, who) do
      nil ->
        :ok

      epic ->
        write(epic, line(card, epic, text, detail))
    end
  end

  defp line(card, epic, text, detail) do
    [text, subject(card, epic), detail, count(epic)]
    |> Enum.reject(&Enum.member?([nil, ""], &1))
    |> Enum.join(" · ")
  end

  defp subject(%Card{id: id}, %Card{id: id}), do: "the epic itself"
  defp subject(card, _epic), do: "##{card.id} #{title(card.title)}"

  # A merge: the acceptance line it follows within @merge_seconds becomes
  # one line, else a line of its own.
  defp merged(card, detail) do
    case target(card, :own) do
      nil ->
        :ok

      epic ->
        accepted = "**Accepted** · " <> subject(card, epic)
        merged = line(card, epic, "**Accepted and merged**", detail)

        case recent_acceptance(epic, accepted) do
          %Comment{} = comment ->
            update_body(epic, comment, replace_line(comment.body, accepted, merged))

          nil ->
            write(epic, line(card, epic, "**Merged**", detail))
        end
    end
  end

  defp replace_line(body, starting, with) do
    body
    |> String.split("\n\n")
    |> Enum.map_join("\n\n", &if(String.starts_with?(&1, starting), do: with, else: &1))
  end

  defp recent_acceptance(epic, accepted) do
    since = DateTime.add(DateTime.utc_now(), -@merge_seconds, :second)

    from(c in Comment,
      where: c.card_id == ^epic.id and c.kind == @kind and c.updated_at >= ^since,
      order_by: [desc: c.id]
    )
    |> Repo.all()
    |> Enum.find(fn c ->
      c.body |> String.split("\n\n") |> Enum.any?(&String.starts_with?(&1, accepted))
    end)
  end

  # A line joins the epic's last comment when that is one of these and came
  # within @join_seconds; else it is a comment of its own.
  defp write(epic, line) do
    last =
      Repo.one(
        from c in Comment,
          where: c.card_id == ^epic.id,
          order_by: [desc: c.id],
          limit: 1
      )

    if joins?(last),
      do: update_body(epic, last, last.body <> "\n\n" <> line),
      else: Boards.add_comment(epic, line, kind: @kind)

    recount_epic(epic)
    :ok
  end

  defp joins?(%Comment{kind: @kind, updated_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second) <= @join_seconds

  defp joins?(_), do: false

  defp update_body(epic, comment, body) do
    {:ok, _} =
      comment
      |> Ecto.Changeset.change(body: body, updated_at: DateTime.utc_now(:second))
      |> Repo.update()

    Boards.card_changed(epic)
  end

  ## The epic ----------------------------------------------------------------

  @doc """
  The epic `card` posts on: its nearest top-level ancestor; for `:own`
  events, the card itself when it is a top-level card with subcards. nil
  for a top-level card otherwise.
  """
  def target(%Card{} = card, who) do
    case Repo.get(Board, card.board_id) do
      %Board{parent_card_id: nil} ->
        if who == :own and sub_board(card), do: card

      %Board{parent_card_id: parent_id} ->
        top(Repo.get(Card, parent_id))

      nil ->
        nil
    end
  end

  defp top(nil), do: nil

  defp top(%Card{} = card) do
    case Repo.get(Board, card.board_id) do
      %Board{parent_card_id: nil} -> card
      %Board{parent_card_id: parent_id} -> top(Repo.get(Card, parent_id))
      nil -> nil
    end
  end

  defp sub_board(%Card{id: id}), do: Repo.get_by(Board, parent_card_id: id)

  @doc "The epic's subcards, `{done, all}`: its own sub-board's open cards."
  def counts(%Card{} = epic) do
    case sub_board(epic) do
      nil ->
        {0, 0}

      %Board{id: board_id} ->
        from(c in Card,
          where: c.board_id == ^board_id and is_nil(c.archived_at) and is_nil(c.stand_in_for_id),
          select: {count(c.id), filter(count(c.id), c.completed)}
        )
        |> Repo.one()
        |> then(fn {all, done} -> {done, all} end)
    end
  end

  defp count(epic) do
    {done, all} = counts(epic)
    "#{done}/#{all} done"
  end

  @doc """
  Sets the % complete of `card`'s epic to done ÷ all of its subcards,
  unless a person set it by hand.
  """
  def recount(%Card{} = card) do
    case target(card, :subcard) do
      nil -> :ok
      epic -> recount_epic(epic)
    end
  end

  defp recount_epic(%Card{id: id}) do
    epic = Repo.get(Card, id)
    {done, all} = counts(epic)

    if all > 0 and not epic.percent_by_hand and epic.percent_complete != div(done * 100, all) do
      from(c in Card, where: c.id == ^epic.id)
      |> Repo.update_all(set: [percent_complete: div(done * 100, all)])

      Boards.card_changed(epic)
    end

    :ok
  end

  ## Words -------------------------------------------------------------------

  defp by(actor) do
    who = actor && actor_name(actor)
    job = actor && (Map.get(actor, :job_id) || Map.get(actor, "job_id"))

    case {who, job} do
      {nil, nil} -> nil
      {nil, job} -> "job ##{job}"
      {who, nil} -> "by #{who}"
      {who, job} -> "by #{who}, job ##{job}"
    end
  end

  defp actor_name(actor) do
    case Slipdock.Verified.who(actor) do
      "somebody" -> nil
      name -> name
    end
  end

  defp pr_and_sha(card, sha) do
    [pr(card.evidence_pr), sha && "`#{short(sha)}`"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp pr(nil), do: nil

  defp pr(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, n] -> "[PR ##{n}](#{url})"
      _ -> url
    end
  end

  defp short(sha), do: String.slice(sha, 0, 7)

  defp title(title) do
    if String.length(title) > 60, do: String.slice(title, 0, 59) <> "…", else: title
  end

  defp first_line(nil), do: nil

  defp first_line(text) do
    line = text |> String.trim() |> String.split(~r/\R/, parts: 2) |> hd() |> String.trim()
    if String.length(line) > 140, do: String.slice(line, 0, 139) <> "…", else: blank_to_nil(line)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
