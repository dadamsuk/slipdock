defmodule Slipdock.Verified.Audits do
  @moduledoc """
  Audits of accepted work: how often a tree audits and which cards are
  sampled, an audit's agreement or disagreement, the rework card and alert
  a disagreement files, and the tree's recent audit misses.
  """

  import Ecto.Query, only: [from: 2]

  alias Slipdock.Boards.{Board, Card, Column}
  alias Slipdock.Repo
  alias Slipdock.Verified.{Actors, Outcome, Util}

  @doc false
  def checks_param(params) do
    case Slipdock.Verified.Checks.parse(Map.get(params, "checks")) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  # The handbook's rules for the card's tree, for the severity of each rule
  # a verdict names; none without a handbook.
  @doc false
  def handbook_rules(card) do
    case card |> Util.board() |> Slipdock.Handbook.find() do
      nil -> []
      handbook -> Slipdock.Handbook.Rules.rules(handbook)
    end
  end

  ## Audits (#1780) -------------------------------------------------------------

  @doc """
  How often `card`'s tree audits accepted work: its root board's
  `verify_audit`, 1 in N (0: never).
  """
  def audit_every(%Card{} = card) do
    board = Util.board(card)
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

  # An audit's say (#1780): a comment, and for a disagreement an alert for
  # the board's owner. Nothing on the card changes. It comes from an audit
  # job on the card, or a person; never from whoever accepted it.
  @doc false
  def audit_decision(card, decision, params, reason, actor, user) do
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

      Actors.same_actor?(card.verify_by, actor) ->
        {:error, :forbidden, "you accepted card ##{card.id}: a different agent audits it"}

      Actors.gated?(actor) and not in_audit_job?(card, actor) ->
        {:error, :forbidden,
         "an agent audits card ##{card.id} only from its audit job (a person may at any time)"}

      true ->
        :ok
    end
  end

  defp in_audit_job?(%Card{id: card_id}, actor) do
    case Actors.actor_map(actor) do
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
    by = Actors.who(actor, user)
    agrees = decision == "agree"

    line =
      if agrees,
        do: "**Audit: agrees** with the acceptance, by #{by}.",
        else: "**Audit: disagrees** with the acceptance, by #{by}."

    said =
      Outcome.comment(card, line, Outcome.with_parts(Util.blank_to_nil(reason), checks), user)

    unless agrees do
      # The rework is filed with the disagreement (#2632), and the finding
      # and the alert name it.
      rework = file_rework(card, reason, checks, said, by, user)
      Slipdock.Findings.Signals.audit_disagreed(card, reason, actor, rework, checks)
      root = card |> Util.board() |> Slipdock.Handbook.root()

      title = "#{@audit_alert_lead}#{card.id}"

      body =
        "#{by} audited “#{card.title}”, accepted by #{Actors.who(card.verify_by)}: " <>
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

        Slipdock.Boards.Comments.add_comment(rework, body, by: user)
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

  # Where an audit's rework card goes: a fix, so the Housekeeping list
  # (#2779) when the card's board has one, else its root's, else the ready
  # list as before.
  defp rework_list(board, columns) do
    root =
      if board.parent_card_id,
        do: Repo.preload(Repo.get(Board, Slipdock.Boards.root_of_board(board.id)), :columns)

    Enum.find(columns, &Column.housekeeping?/1) ||
      (root && Enum.find(root.columns, &Column.housekeeping?/1)) ||
      Slipdock.Flow.ready_list(columns) || List.first(columns)
  end

  defp new_rework(card, reason, checks, link, failed, by) do
    board = card |> Util.board() |> Repo.preload(:columns)
    columns = Enum.sort_by(board.columns, & &1.position)
    column = rework_list(board, columns)

    description =
      "#{@rework_lead}#{card.id} “#{card.title}” (accepted by #{Actors.who(card.verify_by)}): " <>
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

    case Slipdock.Boards.Cards.create_card(column, attrs,
           actor: Slipdock.Actor.automation(),
           origin: "verify"
         ) do
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

  ## What audits caught recently (#2695) ------------------------------------

  @misses_limit 5
  @misses_days 30
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
    root = card |> Util.board() |> Board.root_id()
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
end
