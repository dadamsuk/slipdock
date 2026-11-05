defmodule Slipdock.Findings do
  @moduledoc """
  What each card taught, kept on the board for every pass (W-2310 §Findings).

  A pass writes them as a `Findings:` block in its closing comment, beside the
  `Handbook:` line (`Slipdock.Findings.Block`); the system records its own
  signals the same way (`record/1`). They are kept on the root board of the
  tree, listed (`list/2`) and triaged: promoted into the handbook, dismissed,
  or merged into another finding of the same tree.

  Settled knowledge goes straight into the handbook; findings are for what is
  uncertain, cuts across cards, or shows the handbook was wrong, so they get a
  second look before they become rules.
  """
  import Ecto.Query

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Comment}
  alias Slipdock.Findings.{Block, Finding}
  alias Slipdock.Repo

  @doc """
  Keeps the findings a card's comment carries. Idempotent: parsing a comment
  again (after an edit) replaces the open findings it made before, and an
  item already on the card (same kind and text, from any comment) is not
  made twice. A comment on a page, or with no block, makes none.
  """
  def from_comment(comment, opts \\ [])

  def from_comment(%Comment{card_id: nil}, _opts), do: {:ok, []}

  def from_comment(%Comment{} = comment, opts) do
    items = Block.parse(comment.body) || []

    Repo.transaction(fn ->
      drop_open(comment)

      case Repo.get(Card, comment.card_id) do
        nil -> []
        card -> Enum.flat_map(items, &insert_item(&1, card, comment, opts[:by]))
      end
    end)
  end

  defp insert_item(%{kind: kind, text: text}, card, comment, by) do
    text = String.slice(text, 0, Finding.max_text())

    if Repo.exists?(
         from f in Finding, where: f.card_id == ^card.id and f.kind == ^kind and f.text == ^text
       ) do
      []
    else
      user = by || (comment.user_id && Repo.get(User, comment.user_id))

      %Finding{
        board_id: root_id(card),
        card_id: card.id,
        comment_id: comment.id,
        user_id: user && user.id
      }
      |> Finding.changeset(%{
        by: user && User.display_name(user),
        kind: kind,
        source: "agent",
        text: text
      })
      |> Repo.insert!()
      |> List.wrap()
    end
  end

  @doc """
  A comment is going: the open findings it made go with it. Triaged ones
  stay, since the decision about them still stands.
  """
  def comment_deleted(%Comment{} = comment), do: drop_open(comment)

  defp drop_open(%Comment{id: id}) do
    from(f in Finding, where: f.comment_id == ^id and f.source == "agent" and f.status == "open")
    |> Repo.delete_all()
  end

  @doc """
  Records a finding from the system's own signals: `attrs` has `card` (or
  `board`), `source`, `kind`, `text`, and optionally `cause`, `job_id`, `by`.
  An open finding on the same card with the same source and cause counts the
  repeat (and takes the newer text) rather than making another.
  """
  def record(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:job_id, nil)
    cause = attrs[:cause] && String.slice(to_string(attrs[:cause]), 0, 255)

    case repeat(attrs, cause) do
      nil ->
        insert_signal(attrs, cause)

      # The same job seen again (a job's end can be heard twice) is no repeat.
      %Finding{job_id: job} = finding when not is_nil(job) and job == attrs.job_id ->
        {:ok, finding}

      finding ->
        count_repeat(finding, attrs)
    end
  end

  defp insert_signal(attrs, cause) do
    card = attrs[:card]

    %Finding{
      board_id: if(card, do: root_id(card), else: Board.root_id(attrs[:board])),
      card_id: card && card.id,
      job_id: attrs[:job_id]
    }
    |> Finding.changeset(%{
      kind: attrs[:kind] || "process",
      source: attrs[:source],
      text: attrs[:text],
      cause: cause,
      by: attrs[:by] || "Slipdock"
    })
    |> Repo.insert()
  end

  defp count_repeat(finding, attrs) do
    finding
    |> Ecto.Changeset.change(
      count: finding.count + 1,
      text: String.slice(to_string(attrs[:text] || finding.text), 0, Finding.max_text()),
      job_id: attrs[:job_id] || finding.job_id
    )
    |> Repo.update()
  end

  defp repeat(_attrs, nil), do: nil

  defp repeat(%{card: %Card{id: card_id}} = attrs, cause) do
    open_repeat(from(f in Finding, where: f.card_id == ^card_id), attrs[:source], cause)
  end

  # A finding about a whole board (a health incident with no card) repeats
  # on the root board.
  defp repeat(%{board: %Board{} = board} = attrs, cause) do
    root = Board.root_id(board)

    open_repeat(
      from(f in Finding, where: f.board_id == ^root and is_nil(f.card_id)),
      attrs[:source],
      cause
    )
  end

  defp repeat(_attrs, _cause), do: nil

  defp open_repeat(query, source, cause) do
    Repo.one(
      from f in query,
        where: f.source == ^source and f.cause == ^cause and f.status == "open",
        order_by: [desc: f.id],
        limit: 1
    )
  end

  @doc """
  The tree's findings, newest first. `filters`: `status` (default `open`;
  `all` for every one), `kind`, `source`, `card` (an id) and `since` (a
  `DateTime`, or ISO 8601 text, or a whole number of days back).
  """
  def list(%Board{} = board, filters \\ %{}) do
    with {:ok, since} <- since(filters["since"] || filters[:since]) do
      status = filters["status"] || filters[:status] || "open"

      Finding
      |> where([f], f.board_id == ^Board.root_id(board))
      |> by_value(:status, if(status == "all", do: nil, else: status))
      |> by_value(:kind, filters["kind"] || filters[:kind])
      |> by_value(:source, filters["source"] || filters[:source])
      |> by_value(:card_id, filters["card"] || filters[:card])
      |> since_query(since)
      |> order_by([f], desc: f.updated_at, desc: f.id)
      |> limit(500)
      |> preload(:card)
      |> Repo.all()
      |> then(&{:ok, &1})
    end
  end

  defp since_query(q, nil), do: q
  defp since_query(q, since), do: where(q, [f], f.updated_at >= ^since)

  defp by_value(q, _field, v) when v in [nil, ""], do: q
  defp by_value(q, field, v), do: where(q, [f], field(f, ^field) == ^v)

  defp since(v) when v in [nil, ""], do: {:ok, nil}
  defp since(%DateTime{} = at), do: {:ok, at}
  defp since(days) when is_integer(days) and days >= 0, do: {:ok, days_ago(days)}

  defp since(text) when is_binary(text) do
    cond do
      Regex.match?(~r/^\d+$/, text) ->
        {:ok, days_ago(String.to_integer(text))}

      match?({:ok, _, _}, DateTime.from_iso8601(text)) ->
        {:ok, text |> DateTime.from_iso8601() |> elem(1)}

      match?({:ok, _}, Date.from_iso8601(text)) ->
        {:ok, DateTime.new!(Date.from_iso8601!(text), ~T[00:00:00])}

      true ->
        {:error, "since is a date (2026-11-01), a time (ISO 8601) or a number of days"}
    end
  end

  defp since(_),
    do: {:error, "since is a date (2026-11-01), a time (ISO 8601) or a number of days"}

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(:second), -days * 86_400, :second)

  @doc "How many open findings a card has."
  def open_count(%Card{id: id}),
    do: Repo.aggregate(from(f in Finding, where: f.card_id == ^id and f.status == "open"), :count)

  @doc "How many open findings each of these cards has, as `%{card_id => n}` (none: absent)."
  def open_counts(card_ids) do
    from(f in Finding,
      where: f.card_id in ^card_ids and f.status == "open",
      group_by: f.card_id,
      select: {f.card_id, count(f.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get(id), do: Repo.get(Finding, id) |> Repo.preload(:card)

  @doc """
  Triages a finding: `"dismiss"`, `"promote"` (say what it became in `note`,
  e.g. `W-1950 §Tests TEST-4`), `"merge"` (with `into`, another finding of the
  same tree, which takes its count) or `"reopen"`.
  """
  def triage(%Finding{} = finding, action, params \\ %{}) do
    note = params["note"] || params[:note]

    case action do
      "dismiss" -> set(finding, "dismissed", note)
      "promote" -> set(finding, "promoted", note)
      "reopen" -> reopen(finding)
      "merge" -> merge(finding, params["into"] || params[:into], note)
      other -> {:error, "unknown change #{inspect(other)}: dismiss, promote, merge or reopen"}
    end
  end

  defp set(%Finding{status: "merged"}, _status, _note),
    do: {:error, "it was merged into another finding: reopen it first"}

  defp set(finding, status, note) do
    finding
    |> Finding.triage_changeset(%{status: status, note: note || finding.note})
    |> Repo.update()
  end

  defp reopen(%Finding{status: "merged", merged_into_id: into_id} = finding) do
    Repo.transaction(fn ->
      case into_id && Repo.get(Finding, into_id) do
        %Finding{} = into ->
          into
          |> Ecto.Changeset.change(count: max(into.count - finding.count, 1))
          |> Repo.update!()

        _ ->
          :ok
      end

      finding
      |> Finding.triage_changeset(%{status: "open"})
      |> Repo.update!()
    end)
  end

  defp reopen(finding),
    do: finding |> Finding.triage_changeset(%{status: "open"}) |> Repo.update()

  defp merge(_finding, into, _note) when into in [nil, ""],
    do: {:error, "say which finding it merges into (into)"}

  defp merge(%Finding{status: "merged"}, _into, _note),
    do: {:error, "it is already merged: reopen it first"}

  defp merge(finding, into, note) do
    into_id = if is_binary(into), do: Integer.parse(into), else: {into, ""}

    with {id, ""} when is_integer(id) <- into_id,
         %Finding{} = target <- Repo.get(Finding, id),
         :ok <- mergeable(finding, target) do
      Repo.transaction(fn ->
        target |> Ecto.Changeset.change(count: target.count + finding.count) |> Repo.update!()

        finding
        |> Finding.triage_changeset(%{status: "merged", note: note}, id)
        |> Repo.update!()
      end)
    else
      {:error, _} = e -> e
      _ -> {:error, "no finding #{into} in this tree to merge into"}
    end
  end

  defp mergeable(%Finding{id: id}, %Finding{id: id}),
    do: {:error, "a finding can't merge into itself"}

  defp mergeable(%Finding{board_id: b}, %Finding{board_id: other}) when b != other,
    do: {:error, "that finding is on another board tree"}

  defp mergeable(_, %Finding{status: "merged", merged_into_id: next}),
    do: {:error, "that one is merged itself: merge into ##{next} instead"}

  defp mergeable(_, _), do: :ok

  defp root_id(%Card{board: %Board{} = board}), do: Board.root_id(board)
  defp root_id(%Card{board_id: id}), do: Board.root_id(Repo.get!(Board, id))
end
