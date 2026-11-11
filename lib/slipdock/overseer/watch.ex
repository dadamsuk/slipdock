defmodule Slipdock.Overseer.Watch do
  @moduledoc """
  The overseer's deterministic layer (#2068): every check in `checks/0`
  over one root board's tree, and what it found kept as conditions
  (`Slipdock.Overseer.Condition`).

    * A condition found for the first time **fires**: it is kept, a
      warning alert goes up on the root board (the automation facility's
      alert, `Slipdock.Automations.raise_alert/1`), and the board's owner
      is emailed, unless the settings turn that off.
    * One still found stays quiet: its words are brought up to date, and
      nothing is raised again.
    * One no longer found **clears**: it is closed and its alert taken
      down, for everybody.

  A card going round in circles is told on the event by
  `Slipdock.Verified.Circling`; its condition takes over that alert rather
  than raising a second, and sends no second email.
  """

  import Ecto.Query

  alias Slipdock.Automations
  alias Slipdock.Automations.Alert
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Overseer.{Condition, Settings}
  alias Slipdock.Repo

  @checks [
    Slipdock.Overseer.Checks.Looping,
    Slipdock.Overseer.Checks.WaitingIdle,
    Slipdock.Overseer.Checks.Slow,
    Slipdock.Overseer.Checks.IdleCapacity,
    Slipdock.Overseer.Checks.NoWayForward,
    Slipdock.Overseer.Checks.NotShipped
  ]

  # The checks that run on a board whose overseer is off (#2819): a board
  # with delivery metrics on is told of a merged card that never shipped
  # whether or not it turned the overseer on.
  @always [Slipdock.Overseer.Checks.NotShipped]

  @doc "Every watch check, in the order they run."
  def checks, do: @checks

  @doc "The checks that run whether or not the board's overseer is on."
  def always, do: @always

  @doc "The keys of every check."
  def check_keys, do: Enum.map(@checks, & &1.key())

  @doc """
  Runs every check over `root`'s tree and keeps what they found. Returns
  `%{fired: [condition], cleared: [condition], open: [condition]}`.

  `checks:` in `opts` runs only those (`always/0`, on a board whose
  overseer is off): the conditions of the checks left out are neither
  refreshed nor cleared, and the settings' `watched_at` stays as it was.
  """
  def run(%Board{} = root, %Settings{} = settings, now \\ DateTime.utc_now(), opts \\ []) do
    now = DateTime.truncate(now, :second)
    checks = Keyword.get(opts, :checks, @checks)
    keys = Enum.map(checks, & &1.key())
    ctx = %{root: root, board_ids: tree_ids(root), settings: settings, now: now}

    found =
      for check <- checks, c <- check.find(ctx), into: %{} do
        {{check.key(), c.subject}, Map.put(c, :check, check.key())}
      end

    open =
      for cond <- open_conditions(root.id), Enum.member?(keys, cond.check), into: %{} do
        {{cond.check, cond.subject}, cond}
      end

    cleared =
      for {key, cond} <- open, not Map.has_key?(found, key), do: clear(cond, now)

    {fired, kept} =
      Enum.reduce(found, {[], []}, fn {key, c}, {fired, kept} ->
        case open[key] do
          nil -> {fire(root, settings, c, now) ++ fired, kept}
          cond -> {fired, [refresh(cond, c) | kept]}
        end
      end)

    if checks == @checks and settings.id,
      do:
        Repo.update_all(from(s in Settings, where: s.id == ^settings.id), set: [watched_at: now])

    %{fired: fired, cleared: cleared, open: fired ++ kept}
  end

  @doc "The open conditions on the trees of `root_ids`, oldest first."
  def open_conditions(root_ids) when is_list(root_ids) do
    from(c in Condition,
      where: c.board_id in ^root_ids and is_nil(c.cleared_at),
      order_by: [asc: c.opened_at, asc: c.id]
    )
    |> Repo.all()
  end

  def open_conditions(root_id), do: open_conditions([root_id])

  @doc "Conditions on `root_id`'s tree cleared since `since`, newest first."
  def cleared_since(root_id, since) do
    from(c in Condition,
      where: c.board_id == ^root_id and c.cleared_at >= ^since,
      order_by: [desc: c.cleared_at, desc: c.id]
    )
    |> Repo.all()
  end

  defp tree_ids(root) do
    Repo.all(from(b in Board, where: b.id == ^root.id or b.root_id == ^root.id, select: b.id))
  end

  defp fire(root, settings, c, now) do
    attrs = %{
      board_id: root.id,
      check: c.check,
      subject: c.subject,
      card_id: c.card_id,
      severity: Map.get(c, :severity, "warning"),
      title: String.slice(c.title, 0, 200),
      why: c.why,
      todo: c.todo,
      opened_at: now,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Condition, [attrs],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, ~s|("board_id","check","subject") WHERE cleared_at IS NULL|},
           returning: true
         ) do
      {1, [cond]} ->
        {alert_id, told?} = alert(root, cond)
        if not told? and settings.email, do: email(root, cond)

        cond =
          if alert_id do
            Repo.update_all(from(x in Condition, where: x.id == ^cond.id),
              set: [alert_id: alert_id]
            )

            %{cond | alert_id: alert_id}
          else
            cond
          end

        Boards.ActivityLog.log_activity(
          root.id,
          cond.card_id,
          "overseer",
          "overseer: #{cond.title}"
        )

        [cond]

      _ ->
        []
    end
  end

  # The alert for a condition: the one Circling raised already for a card
  # going round in circles (already emailed: `told?`), else a new one.
  defp alert(root, %Condition{check: "looping", subject: "card:" <> rest} = cond) do
    if String.ends_with?(rest, ":rejections") do
      case circling_alert(root.id, cond.card_id) do
        %Alert{id: id} -> {id, true}
        nil -> raise_alert(root, cond)
      end
    else
      raise_alert(root, cond)
    end
  end

  defp alert(root, cond), do: raise_alert(root, cond)

  defp circling_alert(board_id, card_id) do
    prefix = "Card ##{card_id} is going round in circles"

    Repo.one(
      from(a in Alert,
        where: a.board_id == ^board_id and a.card_id == ^card_id,
        where: like(a.title, ^(prefix <> "%")),
        order_by: [desc: a.id],
        limit: 1
      )
    )
  end

  defp raise_alert(root, cond) do
    case Automations.raise_alert(%{
           "board_id" => root.id,
           "card_id" => cond.card_id,
           "severity" => cond.severity,
           "title" => String.slice("Overseer: " <> cond.title, 0, 200),
           "body" => body(cond)
         }) do
      {:ok, alert} -> {alert.id, false}
      _ -> {nil, false}
    end
  end

  @doc "What a condition's alert and email say: why, then what to do."
  def body(%{why: why, todo: todo}), do: String.slice(why <> "\n\nWhat to do: " <> todo, 0, 2000)

  defp email(root, cond) do
    with id when is_integer(id) <- root.owner_id,
         %{email: address} <- Repo.get(Slipdock.Accounts.User, id) do
      card = cond.card_id && Repo.get(Card, cond.card_id)
      subject = String.slice("Overseer on #{root.name}: #{cond.title}", 0, 200)

      Slipdock.Deferred.defer(fn ->
        Automations.Notifier.deliver([address], subject, body(cond), card: card)
      end)
    end

    :ok
  end

  defp refresh(cond, c) do
    changes =
      [title: String.slice(c.title, 0, 200), why: c.why, todo: c.todo, card_id: c.card_id]
      |> Enum.reject(fn {k, v} -> Map.get(cond, k) == v end)

    if changes == [] do
      cond
    else
      Repo.update_all(from(x in Condition, where: x.id == ^cond.id), set: changes)
      struct(cond, changes)
    end
  end

  defp clear(cond, now) do
    Repo.update_all(from(x in Condition, where: x.id == ^cond.id), set: [cleared_at: now])
    if cond.alert_id, do: Automations.delete_alert(cond.alert_id)

    Boards.ActivityLog.log_activity(
      cond.board_id,
      cond.card_id,
      "overseer",
      "overseer cleared: #{cond.title}"
    )

    %{cond | cleared_at: now}
  end
end
