defmodule Slipdock.Health do
  @moduledoc """
  The health monitor (W-2310 §Health monitor): server code on the scheduler
  clock that finds work stuck in ways only a person would otherwise notice,
  tries a safe fix, and flags what it can't fix.

  Each detector (`Slipdock.Health.Detector`, every module under
  `Slipdock.Health.Detectors`) finds a condition on a board tree. What it finds
  is an **incident** (`Slipdock.Health.Incident`), fingerprinted by the
  detector, the subject and the state that made it one, like a gardener
  suggestion: an active incident is never opened twice, a changed state is a
  new incident, and an incident clears when a later run no longer finds it.

  A run, for each incident it finds:

    1. **fixes** it where the detector has a safe fix, up to the detector's
       `max_attempts` (default 2), each attempt recorded in the incident's log
       and as a comment on its card;
    2. **flags** it when the fixes run out, or at once when there is none:
       the card gets the `stuck` flag and a comment saying what was found and
       tried, or with no card the board gets an alert. Either way rules with
       the `health_flagged` trigger hear about it, so a person can add an
       email.

  Fixes touch only orchestration state — jobs, the queue, flags, comments —
  and never delete, merge or close anything by force.

  Taking the `stuck` flag off a card marks its flagged incidents **handled**:
  that state is never flagged again, only a changed one.

  `tick/1` runs it from the scheduler every `interval_minutes` (default 5,
  `config :slipdock, :health, interval_minutes: N`, or `interval: :manual`),
  one run at a time under an advisory lock, for every root board with runners
  or automation rules.
  """

  import Ecto.Query

  require Logger

  alias Slipdock.{Automations, Boards, Repo}
  alias Slipdock.Automations.Rule
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Health.{Context, Incident, Pulse, Settings}
  alias Slipdock.Runners.Runner

  @pubsub Slipdock.PubSub
  @lock 7_593_175_901
  @default_interval 5

  ## Detectors ------------------------------------------------------------------

  @doc "Every detector: each module under `Slipdock.Health.Detectors` that implements the behaviour."
  def detectors do
    case :application.get_key(:slipdock, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.filter(&detector_module?/1)
        |> Enum.sort_by(& &1.key())

      _ ->
        []
    end
  end

  defp detector_module?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.Slipdock.Health.Detectors.") and
      Code.ensure_loaded?(module) and function_exported?(module, :detect, 2) and
      function_exported?(module, :key, 0)
  end

  @doc "The detector with that key, or nil."
  def detector(key, detectors \\ detectors()), do: Enum.find(detectors, &(&1.key() == key))

  @doc "Every detector with the settings it runs with on the tree rooted at `board`."
  def detector_settings(%Board{} = board, detectors \\ detectors()) do
    changes = Settings.changes(Board.root_id(board))

    Enum.map(detectors, fn d ->
      %{key: d.key(), label: d.label(), settings: Settings.for(changes, d)}
    end)
  end

  ## The clock ------------------------------------------------------------------

  @doc "Minutes between runs, or `:manual`."
  def interval do
    config = Slipdock.Config.get(:health, [])

    case config[:interval] do
      :manual -> :manual
      _ -> config[:interval_minutes] || @default_interval
    end
  end

  @doc """
  Called on every scheduler tick: runs every tree when the last run is at
  least `interval/0` old. Answers `:ran`, `:not_due`, `:busy` (another node
  holds the lock) or `:manual`.
  """
  def tick(now \\ DateTime.utc_now()) do
    case interval() do
      :manual ->
        :manual

      minutes ->
        last = Pulse.last("monitor")

        if is_nil(last) or DateTime.diff(now, last, :minute) >= minutes,
          do: run_all(now: now),
          else: :not_due
    end
  end

  @doc """
  Runs the monitor on every root board with runners or automation rules,
  under an advisory lock so only one run happens at a time, and records the
  monitor's pulse. `:ran` or `:busy`.
  """
  def run_all(opts \\ []) do
    now = opts[:now] || DateTime.utc_now()

    Repo.checkout(fn ->
      case Repo.query!("SELECT pg_try_advisory_lock($1)", [@lock]) do
        %{rows: [[true]]} ->
          try do
            Enum.each(watched_boards(), fn board ->
              try do
                run(board, Keyword.put(opts, :now, now))
              rescue
                e ->
                  Logger.error(
                    "Health monitor failed on board #{board.id}: #{Exception.message(e)}"
                  )
              end
            end)

            Pulse.beat("monitor", now)
            :ran
          after
            Repo.query!("SELECT pg_advisory_unlock($1)", [@lock])
          end

        _ ->
          :busy
      end
    end)
  end

  @doc "The root boards the monitor watches: those with runners or automation rules, not archived."
  def watched_boards do
    ids =
      Repo.all(from(r in Runner, distinct: true, select: r.board_id)) ++
        Repo.all(from(r in Rule, distinct: true, select: r.board_id))

    roots =
      from(b in Board,
        where: b.id in ^Enum.uniq(ids),
        distinct: true,
        select: coalesce(b.root_id, b.id)
      )
      |> Repo.all()

    from(b in Board, where: b.id in ^roots and is_nil(b.archived_at), order_by: b.id)
    |> Repo.all()
  end

  ## A run ----------------------------------------------------------------------

  @doc """
  Looks the tree `board` is in over with each detector that is on, fixes or
  flags what it finds, and clears what has gone. Options: `:now`,
  `:detectors` (default `detectors/0`).

  `{:ok, %{"found" => n, "opened" => n, "fixed" => n, "tried" => n,
  "flagged" => n, "cleared" => n, "handled" => n}}`.
  """
  def run(%Board{} = board, opts \\ []) do
    now = (opts[:now] || DateTime.utc_now()) |> DateTime.truncate(:second)
    root = Repo.get!(Board, Board.root_id(board))
    changes = Settings.changes(root.id)

    enabled =
      (opts[:detectors] || detectors())
      |> Enum.map(&{&1, Settings.for(changes, &1)})
      |> Enum.filter(fn {_, s} -> s["enabled"] == true end)

    counts = %{"handled" => release_handled(root.id, now)}
    ctx = Context.new(root, now)

    found =
      for {detector, settings} <- enabled,
          finding <- safe_detect(detector, ctx, settings),
          into: %{},
          do: {fingerprint(detector.key(), finding), {detector, settings, finding}}

    counts =
      Enum.reduce(found, counts, fn {fp, {detector, settings, finding}}, acc ->
        root.id
        |> step(fp, detector, settings, finding, now)
        |> Enum.reduce(acc, &Map.update(&2, &1, 1, fn n -> n + 1 end))
      end)

    keys = Enum.map(enabled, fn {d, _} -> d.key() end)
    cleared = clear_missing(root.id, keys, Map.keys(found), now)

    counts =
      Map.merge(
        %{"opened" => 0, "fixed" => 0, "tried" => 0, "flagged" => 0},
        Map.merge(counts, %{"found" => map_size(found), "cleared" => cleared})
      )

    if Enum.any?(~w(opened fixed tried flagged cleared handled), &(counts[&1] > 0)),
      do: broadcast(root.id)

    {:ok, counts}
  end

  defp safe_detect(detector, ctx, settings) do
    detector.detect(ctx, settings)
  rescue
    e ->
      Logger.error("Health detector #{detector.key()} failed: #{Exception.message(e)}")
      []
  end

  @doc "A finding's fingerprint: its detector, subject and state."
  def fingerprint(key, finding) do
    :crypto.hash(:sha256, :erlang.term_to_binary({key, finding.subject, finding.state}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # One finding: open it if it is new, then fix it or flag it. Answers what
  # happened, as count keys.
  defp step(root_id, fp, detector, settings, finding, now) do
    case active(root_id, fp) do
      %Incident{status: "flagged"} ->
        []

      %Incident{status: "open"} = incident ->
        attempt(incident, detector, settings, now)

      nil ->
        if handled?(root_id, fp) do
          []
        else
          incident = open(root_id, fp, detector, finding, now)
          ["opened" | attempt(incident, detector, settings, now)]
        end
    end
  end

  defp active(root_id, fp) do
    Repo.one(
      from(i in Incident,
        where:
          i.board_id == ^root_id and i.fingerprint == ^fp and
            i.status in ^Incident.active_statuses()
      )
    )
  end

  defp handled?(root_id, fp) do
    Repo.exists?(
      from(i in Incident,
        where: i.board_id == ^root_id and i.fingerprint == ^fp and i.status == "handled"
      )
    )
  end

  # A state that comes back after a fix worked keeps the attempts spent on
  # it, so the fixes stay bounded however often it comes back.
  defp open(root_id, fp, detector, finding, now) do
    spent =
      from(i in Incident,
        where: i.board_id == ^root_id and i.fingerprint == ^fp and i.status == "fixed",
        select: coalesce(sum(i.attempts), 0)
      )
      |> Repo.one()

    Repo.insert!(%Incident{
      board_id: root_id,
      card_id: finding[:card_id],
      detector: detector.key(),
      fingerprint: fp,
      subject: stringify(finding.subject),
      summary: finding.summary,
      data: stringify(finding[:data] || %{}),
      status: "open",
      attempts: spent || 0,
      log: [entry(now, "Found: #{finding.summary}")],
      inserted_at: now,
      updated_at: now
    })
  end

  defp attempt(%Incident{} = incident, detector, settings, now) do
    max = settings["max_attempts"] || 2

    cond do
      not function_exported?(detector, :resolve, 2) ->
        flag(incident, detector, "No safe fix to try.", now)

      incident.attempts >= max ->
        flag(
          incident,
          detector,
          "Still stuck after #{incident.attempts} #{plural(incident.attempts, "attempt")}.",
          now
        )

      true ->
        n = incident.attempts + 1
        resolved(safe_resolve(detector, incident, n), incident, detector, n, max, now)
    end
  end

  defp resolved(result, incident, detector, n, max, now) do
    case result do
      :fixed -> fixed(incident, detector, "Fixed.", n, now)
      {:fixed, what} -> fixed(incident, detector, "Fixed: #{what}", n, now)
      {:tried, what} -> tried(incident, detector, what, n, max, now)
      {:no_fix, why} -> flag(incident, detector, why, now)
      _no_fix -> flag(incident, detector, "No safe fix to try.", now)
    end
  end

  defp safe_resolve(detector, incident, n) do
    detector.resolve(incident, n)
  rescue
    e -> {:tried, "the fix failed (#{Exception.message(e)})"}
  end

  defp fixed(incident, detector, what, n, now) do
    incident
    |> change(
      status: "fixed",
      attempts: n,
      resolved_at: now,
      log: incident.log ++ [entry(now, what)]
    )
    |> note(detector, what)

    ["fixed"]
  end

  defp tried(incident, detector, what, n, max, now) do
    line = "Tried (#{n} of #{max}): #{what}"

    incident
    |> change(attempts: n, log: incident.log ++ [entry(now, line)])
    |> note(detector, line)

    ["tried"]
  end

  defp flag(incident, detector, why, now) do
    incident =
      change(incident,
        status: "flagged",
        flagged_at: now,
        log: incident.log ++ [entry(now, "Flagged for a person. " <> why)]
      )

    tried =
      incident.log
      |> Enum.map(& &1["what"])
      |> Enum.filter(&String.starts_with?(&1, "Tried"))

    body =
      [
        "**Health monitor: stuck** (#{detector.label()}, incident ##{incident.id}).",
        "",
        "- Found: #{incident.summary}"
      ] ++
        Enum.map(tried, &"- #{&1}") ++
        [
          "- #{why} Flagged `stuck` for a person.",
          "",
          "Take the `stuck` flag off once it is dealt with."
        ]

    cards = live_cards(incident)

    incident =
      case cards do
        [] ->
          {:ok, alert} =
            Automations.raise_alert(%{
              "board_id" => incident.board_id,
              "title" => String.slice("Stuck (#{detector.label()}): #{incident.summary}", 0, 200),
              "body" => why,
              "severity" => "warning"
            })

          change(incident, alert_id: alert.id)

        cards ->
          Enum.each(cards, fn card ->
            unless "stuck" in card.flags,
              do: Boards.update_card(card, %{"flags" => card.flags ++ ["stuck"]})

            # Its job's log keeps the failure time from now (#1872).
            Slipdock.Runners.TranscriptRetention.card_failed(card, verify: false)

            Boards.add_comment(Repo.get!(Card, card.id), Enum.join(body, "\n"))
          end)

          incident
      end

    card = List.first(cards) && Repo.get(Card, hd(cards).id)

    Automations.dispatch(%{
      type: "health_flagged",
      board_id: (card && card.board_id) || incident.board_id,
      card: card,
      incident: incident
    })

    # Every flag is a finding too (W-2310 §Findings).
    Slipdock.Findings.Signals.health_flagged(incident, detector.label(), cards)

    ["flagged"]
  end

  # A comment on the incident's card for each fix tried; with no card, the
  # incident's log is the record.
  defp note(incident, detector, line) do
    with %Card{archived_at: nil} = card <- incident.card_id && Repo.get(Card, incident.card_id) do
      Boards.add_comment(
        card,
        "**Health monitor** (#{detector.label()}, incident ##{incident.id}).\n\n" <>
          "- Found: #{incident.summary}\n- #{line}"
      )
    end

    incident
  end

  defp live_cards(incident) do
    ids = Incident.card_ids(incident)

    from(c in Card, where: c.id in ^ids and is_nil(c.archived_at))
    |> Repo.all()
    |> Enum.sort_by(&Enum.find_index(ids, fn id -> id == &1.id end))
  end

  # A flagged incident whose card no longer has the `stuck` flag: a person
  # took it off, so it is handled.
  defp release_handled(root_id, now) do
    from(i in Incident,
      join: c in Card,
      on: c.id == i.card_id,
      where: i.board_id == ^root_id and i.status == "flagged",
      where: not fragment("? = ANY(?)", "stuck", c.flags) or not is_nil(c.archived_at)
    )
    |> Repo.all()
    |> Enum.map(fn incident ->
      change(incident,
        status: "handled",
        resolved_at: now,
        log: incident.log ++ [entry(now, "Handled: the stuck flag was taken off.")]
      )
    end)
    |> length()
  end

  # Active incidents of the detectors that ran that this run didn't find:
  # their condition has gone. A card left with no flagged incident loses the
  # `stuck` flag the monitor put on it.
  defp clear_missing(root_id, keys, fingerprints, now) do
    gone =
      from(i in Incident,
        where:
          i.board_id == ^root_id and i.detector in ^keys and
            i.status in ^Incident.active_statuses() and i.fingerprint not in ^fingerprints
      )
      |> Repo.all()

    Enum.each(gone, fn incident ->
      was_flagged = incident.status == "flagged"

      incident =
        change(incident,
          status: "cleared",
          resolved_at: now,
          log: incident.log ++ [entry(now, "Cleared: no longer found.")]
        )

      if was_flagged, do: unflag(incident)
    end)

    length(gone)
  end

  defp unflag(incident) do
    for card <- live_cards(incident), "stuck" in card.flags do
      still =
        from(i in Incident, where: i.board_id == ^incident.board_id and i.status == "flagged")
        |> Repo.all()
        |> Enum.any?(&(card.id in Incident.card_ids(&1)))

      unless still do
        Boards.update_card(card, %{"flags" => List.delete(card.flags, "stuck")})

        Boards.add_comment(
          Repo.get!(Card, card.id),
          "**Health monitor:** cleared (incident ##{incident.id}). It is no longer stuck, " <>
            "so the `stuck` flag is off."
        )
      end
    end
  end

  defp change(incident, attrs) do
    incident
    |> Ecto.Changeset.change(Keyword.put(attrs, :updated_at, DateTime.utc_now(:second)))
    |> Repo.update!()
  end

  defp entry(now, what), do: %{"at" => DateTime.to_iso8601(now), "what" => what}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  ## Reading --------------------------------------------------------------------

  @doc "The tree's open and flagged incidents, newest first."
  def list_active(%Board{} = board) do
    from(i in Incident,
      where: i.board_id == ^Board.root_id(board) and i.status in ^Incident.active_statuses(),
      order_by: [desc: i.updated_at, desc: i.id],
      preload: [:card]
    )
    |> Repo.all()
  end

  @doc "The tree's most recent finished incidents (fixed, cleared, handled), newest first."
  def list_recent(%Board{} = board, limit \\ 20) do
    from(i in Incident,
      where: i.board_id == ^Board.root_id(board) and i.status not in ^Incident.active_statuses(),
      order_by: [desc: i.updated_at, desc: i.id],
      limit: ^limit,
      preload: [:card]
    )
    |> Repo.all()
  end

  @doc "When the monitor last ran, on any tree, or nil."
  def last_run, do: Pulse.last("monitor")

  ## The pulse ------------------------------------------------------------------

  # A fresh boot hasn't ticked yet, and the pulse in the database may be the
  # old container's: stale clocks don't count for this long after start.
  @boot_grace_seconds 600

  @doc """
  The two clocks the monitor depends on, for `/healthz` (#1765): when the
  scheduler last ticked and the monitor last ran, each as
  `%{"last" => iso8601 | nil, "age_seconds" => n | nil, "stale_after_seconds"
  => n | nil, "stale" => bool}`. A clock is stale when it hasn't beaten for
  a few of its intervals (the scheduler 5, the monitor 3), except within ten
  minutes of boot; a clock set to `:manual` is never stale.

  Options, for tests: `:now`, `:uptime_seconds`, `:last` (`%{name => at}`)
  and `:intervals` (`%{name => seconds | :manual}`).
  """
  def pulse(opts \\ []) do
    now = opts[:now] || DateTime.utc_now()
    uptime = opts[:uptime_seconds] || div(elem(:erlang.statistics(:wall_clock), 0), 1000)
    intervals = Map.merge(clock_intervals(), opts[:intervals] || %{})

    Map.new([{"scheduler", 5}, {"monitor", 3}], fn {name, times} ->
      last = Map.get(opts[:last] || %{}, name, :read)
      last = if last == :read, do: Pulse.last(name), else: last
      age = last && max(DateTime.diff(now, last), 0)

      limit =
        case intervals[name] do
          seconds when is_integer(seconds) -> seconds * times
          _ -> nil
        end

      stale = not is_nil(limit) and uptime > @boot_grace_seconds and (is_nil(age) or age > limit)

      {name,
       %{
         "last" => last && DateTime.to_iso8601(last),
         "age_seconds" => age,
         "stale_after_seconds" => limit,
         "stale" => stale
       }}
    end)
  end

  @doc "Why `pulse` is unhealthy, in words, or nil when it isn't."
  def stale_reason(pulse) do
    [{"scheduler", "the scheduler"}, {"monitor", "the health monitor"}]
    |> Enum.filter(fn {name, _} -> pulse[name]["stale"] end)
    |> Enum.map(fn {name, words} ->
      case pulse[name]["age_seconds"] do
        nil -> "#{words} has never run"
        age -> "#{words} last ran #{div(age, 60)} minutes ago"
      end
    end)
    |> case do
      [] -> nil
      reasons -> Enum.join(reasons, "; ")
    end
  end

  defp clock_intervals do
    scheduler =
      case Slipdock.Config.get(:automations, [])[:interval] do
        :manual -> :manual
        nil -> 60
        ms when is_integer(ms) -> div(ms, 1000)
      end

    monitor =
      case interval() do
        :manual -> :manual
        minutes -> minutes * 60
      end

    %{"scheduler" => scheduler, "monitor" => monitor}
  end

  @doc "Subscribes to `{:health_changed, root_id}` for the tree `board` is in."
  def subscribe(%Board{} = board),
    do: Phoenix.PubSub.subscribe(@pubsub, "health:#{Board.root_id(board)}")

  defp broadcast(root_id),
    do: Phoenix.PubSub.broadcast(@pubsub, "health:#{root_id}", {:health_changed, root_id})
end
