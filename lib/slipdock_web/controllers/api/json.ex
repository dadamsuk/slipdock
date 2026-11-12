defmodule SlipdockWeb.API.JSON do
  @moduledoc "Plain-map serializers for API responses."

  alias Slipdock.Boards.{
    Activity,
    Board,
    Card,
    ChecklistItem,
    Column,
    Comment,
    SavedView,
    Tag,
    Template
  }

  alias Slipdock.Automations.{Alert, Callback, Rule}
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Wiki.{Link, Page, Revision}

  @doc "A named card view (#2031), as REST and MCP give it."
  def card_view(%Slipdock.CardViews.CardView{} = view),
    do: %{id: view.id, name: view.name, elements: view.elements}

  @doc """
  One level of a person's card views (#2031): which level, its board and
  list, the named view it applies, what it states and, on a board, Show all.
  `place` is `{board_or_nil, column_or_nil}`.
  """
  def card_view_level({board, column}, %Slipdock.CardViews.Level{} = level) do
    %{
      level:
        cond do
          column -> "list"
          board -> "board"
          true -> "global"
        end,
      board: board && %{id: board.id, code: board.code, name: board.name},
      list: column && %{id: column.id, name: column.name},
      card_view: level.card_view && %{id: level.card_view.id, name: level.card_view.name},
      elements: level.elements,
      show_all: level.show_all
    }
  end

  @doc "Every element a card view can set (#2031), with its group and default."
  def card_view_elements do
    alias Slipdock.CardViews.Elements

    for {group, _title, elements} <- Elements.groups(),
        {key, label} <- elements,
        do: %{key: key, label: label, group: group, default: Elements.default?(key)}
  end

  @doc """
  A board's DORA report (#1134) as the API and MCP give it: the numbers, or
  — while the board's delivery metrics are off — that they are, and how to
  turn them on.
  """
  def dora(%Board{} = board, environment, days) do
    head = %{board: %{id: board.id, code: board.code}}

    case Slipdock.Dora.for_board(board, environment: blank_param(environment), days: days) do
      {:ok, report} ->
        Map.merge(head, %{enabled: true, dora: report})

      {:error, :off} ->
        Map.merge(head, %{
          enabled: false,
          dora: nil,
          message: Slipdock.Deployments.off_message(board)
        })
    end
  end

  defp blank_param(v) when v in [nil, ""], do: nil
  defp blank_param(v), do: v

  @doc """
  A card's delivery lines (#1134), for a card read on its own: `shipped`
  (`Slipdock.Deployments.shipped/1`), `deploy_failed` (where its latest
  deploy attempt failed, `Slipdock.Deployments.deploy_failed/1`, #2820),
  `incident_of`, the deploy it says caused it, and `release`
  (`Slipdock.Releases.state/1`, #2834) on a board that releases in
  batches. Each only when there is one, so a board with delivery metrics
  off answers as it always did. Each line's `text` gives its date and time
  in `zone`, the reader's (#2022). And `not_shipped` (#2819,
  `Slipdock.Deployments.NotShipped`), on a merged card no succeeded deploy
  names once the board's `not_shipped_minutes` have gone by: `sha`,
  `merged_at`, `seconds` since, `minutes` (the setting) and `text`. On a
  board that releases in batches the minutes and `seconds` count from the
  card's release, given as `release_requested_at` (#2839).
  """
  def put_delivery(map, card, zone \\ "Etc/UTC") do
    map
    |> then(fn m ->
      case Slipdock.Deployments.shipped(card) do
        [] ->
          m

        lines ->
          Map.put(
            m,
            :shipped,
            Enum.map(lines, &Map.put(&1, :text, Slipdock.Deployments.shipped_text(&1, zone)))
          )
      end
    end)
    |> then(fn m ->
      case Slipdock.Deployments.deploy_failed(card) do
        [] ->
          m

        lines ->
          Map.put(
            m,
            :deploy_failed,
            Enum.map(
              lines,
              &Map.put(&1, :text, Slipdock.Deployments.deploy_failed_text(&1, zone))
            )
          )
      end
    end)
    |> then(fn m ->
      case Slipdock.Deployments.NotShipped.for_card(card) do
        nil -> m
        line -> Map.put(m, :not_shipped, line)
      end
    end)
    |> then(fn m ->
      case card do
        %{caused_by_deployment_id: id} when is_integer(id) -> Map.put(m, :incident_of, id)
        _ -> m
      end
    end)
    |> put_release(card, zone)
  end

  # Merged, awaiting release, or released (#2834): only on a batched board.
  defp put_release(map, %Card{} = card, zone) do
    case Slipdock.Releases.state(card) do
      nil -> map
      state -> Map.put(map, :release, Map.put(state, :text, Slipdock.Releases.text(state, zone)))
    end
  end

  defp put_release(map, _card, _zone), do: map

  @doc """
  A release request (#2835, `Slipdock.Releases.Request`): its `status`,
  every trigger that asked for it (`triggers`: `trigger`, `by`, `at`), the
  cards it covers (`card_ids`), its runner job and the run it fired.
  """
  def release_request(nil), do: nil

  def release_request(%Slipdock.Releases.Request{} = r) do
    %{
      id: r.id,
      board_id: r.board_id,
      status: r.status,
      triggers: r.triggers,
      card_ids: r.card_ids,
      job_id: r.job_id,
      run_url: r.run_url,
      note: r.note,
      requested_at: r.inserted_at,
      started_at: r.started_at,
      finished_at: r.finished_at
    }
  end

  @doc """
  A hold on a tree's releases after a red release (#2838,
  `Slipdock.Releases.hold/1`): the `reason`, the `stage` that failed, the
  failing `run_url`, the `sha`, the failed `deployment_id`, the batch's
  `card_ids`, the `fix_card_id` whose merge lifts it, `held_at` and `text`,
  the whole of it in words. Null while releases run.
  """
  def release_hold(nil), do: nil

  def release_hold(%{} = hold) do
    %{
      reason: hold["reason"],
      stage: hold["stage"],
      run_url: hold["run_url"],
      sha: hold["sha"],
      deployment_id: hold["deployment_id"],
      card_ids: hold["card_ids"] || [],
      fix_card_id: hold["fix_card_id"],
      held_at: hold["held_at"],
      text: Slipdock.Releases.held_text(hold)
    }
  end

  @doc """
  Where a tree's releases stand (#2835, `Slipdock.Releases.status/1`): its
  `mode`, the `hold` (#2838, `release_hold/1`, null while releases run),
  the `running` and `queued` requests, the `last` one that ended, and the
  cards `awaiting` release (`id`, `title`, `priority`, `merged_at`).
  """
  def release_status(%{} = status) do
    %{
      mode: status.mode,
      hold: release_hold(Map.get(status, :hold)),
      running: release_request(status.running),
      queued: release_request(status.queued),
      last: release_request(status.last),
      awaiting:
        Enum.map(
          status.awaiting,
          &%{id: &1.id, title: &1.title, priority: &1.priority, merged_at: &1.completed_at}
        )
    }
  end

  @doc """
  A finished card's outcome (#2022, `Slipdock.CardOutcome`), for a card
  read on its own: `outcome` (`text`, its time in `zone`, `done_at`,
  `accepted_by`, `pr`, `merge_sha`, `commit`). The handoff written before
  it finished is no longer where it stands: it moves to `last_handoff`
  (with `before_finish: true`) and `handoff` is nil. One left after it
  finished, for what is still to do, stays the `handoff`. An open card
  answers as it always did.
  """
  def put_outcome(map, %Card{} = card, zone \\ "Etc/UTC") do
    case Slipdock.CardOutcome.of(card) do
      nil ->
        map

      outcome ->
        map
        |> Map.put(
          :outcome,
          Map.put(
            Map.delete(outcome, :pr_number),
            :text,
            Slipdock.CardOutcome.text(outcome, zone)
          )
        )
        |> fold_handoff(card)
    end
  end

  defp fold_handoff(%{handoff: %{at: _} = h} = map, card) do
    if Slipdock.CardOutcome.before_finish?(card, %{inserted_at: h.at}),
      do:
        map |> Map.put(:handoff, nil) |> Map.put(:last_handoff, Map.put(h, :before_finish, true)),
      else: map
  end

  defp fold_handoff(map, _card), do: map

  @doc """
  A card's lead time with what its jobs spent beside it (#1954), for a card
  read on its own: `lead_time` (`Slipdock.LeadTime.brief/2`) with `seconds`,
  `ends`, `phases`, `cost` (`total` and `phases`, each with
  `model_seconds`, `tool_seconds`, `jobs` and `tokens` only when known; nil
  when no job sent a log) and, on an epic, `rollup` (its subcards added
  in). Only on a card a runner job was sent on, or an epic
  (`Slipdock.LeadTime.worked_brief/2`), so any other card answers as it
  always did.
  """
  def put_lead_time(map, card) do
    case Slipdock.LeadTime.worked_brief(card) do
      nil -> map
      lt -> Map.put(map, :lead_time, lead_time(lt))
    end
  end

  defp lead_time(lt) do
    %{
      seconds: lt.seconds,
      ends: lt.ends,
      phases: lt.phases,
      cost: lead_cost(lt.cost),
      rollup:
        lt.rollup &&
          %{
            subcards: lt.rollup.subcards,
            seconds: lt.rollup.seconds,
            cost: lead_cost(lt.rollup.cost)
          }
    }
  end

  defp lead_cost(nil), do: nil

  defp lead_cost(%{total: total, phases: phases}) do
    %{
      total: Slipdock.Runners.JobCost.json(total),
      phases: Map.new(phases, fn {phase, c} -> {phase, Slipdock.Runners.JobCost.json(c)} end)
    }
  end

  @doc "A deploy from the ledger (#1134), its commits included."
  def deployment(%Slipdock.Deployments.Deployment{} = d) do
    %{
      id: d.id,
      board_id: d.board_id,
      environment: d.environment,
      sha: d.sha,
      tag: d.tag,
      previous_sha: d.previous_sha,
      status: d.status,
      started_at: d.started_at,
      finished_at: d.finished_at,
      source: d.source,
      rollback: d.rollback,
      note: d.note,
      stage: d.stage,
      run_url: d.run_url,
      cards: d.card_ids,
      commits: d.commits
    }
  end

  @doc """
  A board in a listing. `viewer` is who is reading, and is what decides
  `shared`: a board whose owner is somebody else. The owner is named either
  way, so a client can say whose board it is looking at.
  """
  def board_summary(%Board{} = b, viewer \\ nil) do
    cards = if Ecto.assoc_loaded?(b.cards), do: b.cards, else: []
    columns = if Ecto.assoc_loaded?(b.columns), do: b.columns, else: []
    release = Slipdock.Releases.settings(b)

    %{
      id: b.id,
      name: b.name,
      code: b.code,
      shortcut: b.shortcut,
      description: b.description,
      color: b.color,
      kind: b.kind,
      simple: b.simple,
      page_card_features: b.page_card_features,
      wiki_tree_icons: b.wiki_tree_icons,
      wiki_sort: b.wiki_sort,
      show_pulse: b.show_pulse,
      delivery_metrics: b.delivery_metrics,
      card_ref_pattern: b.card_ref_pattern,
      incident_tag: b.incident_tag || "incident",
      hotfix_window_hours: b.hotfix_window_hours,
      not_shipped_minutes: b.not_shipped_minutes,
      deploy_token: Slipdock.Deployments.token?(b),
      automation_wip: b.automation_wip,
      # Agentic Building (#2011): the board menu's item and page for these
      # settings. Off hides them; the settings below hold either way.
      agentic_building: b.agentic_building,
      # How long runner job logs stay, in hours (#1872).
      job_log_hours: b.job_log_hours,
      failure_log_hours: b.failure_log_hours,
      # Verified work's switches (#1620), all off by default.
      bar_required: b.bar_required,
      # Lanes (#1628), off by default.
      lanes: b.lanes,
      # What an overlap does (#1972): off, hold or advise.
      lane_mode: b.lane_mode,
      # Profiles inferred when an agent starts a card (#1951), and each
      # profile's human tier on the tree (#1952), nil with profiles off.
      profiles: b.profiles,
      profile_tiers: if(b.profiles, do: Slipdock.Profiles.board_tiers(b)),
      # Globs that never count toward a lane (#1971); [] none.
      shared_paths: b.shared_paths,
      evidence_required: b.evidence_required,
      verify_work: b.verify_work,
      verify_pool: b.verify_pool,
      verify_rejection_limit: b.verify_rejection_limit,
      verify_audit: b.verify_audit,
      # A finding seen this many times is drafted as a proposal (#1942); 0 off.
      findings_propose_at: b.findings_propose_at,
      # An approval wait's proposal stands after this long (#2096): "4h"; nil off.
      wait_default_after: Slipdock.WaitDefaults.format(b.wait_default_after),
      # Who each kind of question goes to (#1949): kind => people, first is on.
      wait_routes: wait_routes(b),
      ship_via: b.ship_via,
      # How merged work reaches production (#2834), the tree root's.
      release_mode: release.mode,
      release_age_cap_hours: release.age_cap_hours,
      # The command a release job runs (#2835); nil is the default.
      release_command: release.command,
      # What the board calls a handoff, and its own drafting instructions
      # (nil: the built-in ones) (#1212).
      handoff_label: Board.handoff_label(b),
      handoff_prompt: b.handoff_prompt,
      # Who else may mail the board's card addresses (#1289): the owner's
      # to see, nil for anybody else.
      inbound_senders: if(owner?(b, viewer), do: b.inbound_senders),
      default_view: Board.home_view(b),
      owner: owner_ref(b),
      shared: shared?(b, viewer),
      columns: length(columns),
      cards: length(cards),
      completed: Enum.count(cards, & &1.completed),
      archived_at: b.archived_at,
      inserted_at: b.inserted_at
    }
  end

  def template(%Template{} = t) do
    %{
      id: t.id,
      name: t.name,
      description: t.description,
      columns: t.columns,
      pages: t.pages,
      folders: t.folders,
      tags: t.tags,
      automations: t.automations,
      kind: t.kind,
      # Built in: read-only to everyone. Otherwise it is the caller's own.
      system: t.system
    }
  end

  def board(%Board{} = b) do
    release = Slipdock.Releases.settings(b)

    %{
      id: b.id,
      name: b.name,
      code: b.code,
      shortcut: b.shortcut,
      description: b.description,
      color: b.color,
      # "sprints" on a sprint board (its cards are sprints), nil otherwise.
      kind: b.kind,
      # On a sprint board, where its sprints are planned from:
      # [%{board_id, column_ids}], no column ids meaning every open list.
      sprint_sources: b.sprint_sources || [],
      owner: owner_ref(b),
      archived_at: b.archived_at,
      root_id: Board.root_id(b),
      parent_card:
        case b.parent_card do
          %Card{} = c -> %{id: c.id, title: c.title, board_id: c.board_id}
          _ -> nil
        end,
      tags: Enum.map(b.tags, &tag/1),
      milestones: Enum.map(Map.get(b, :milestones) || [], &milestone/1),
      fields: Enum.map(Map.get(b, :fields) || [], &field_definition/1),
      votes: %{budget: b.vote_budget, max_per_card: b.vote_max},
      # What the foot of every list offers, and so what a client should draw.
      add: %{card: b.add_card, page: b.add_page, document: b.add_document},
      # Whether the wiki's pages show the card contents (status, checklist,
      # links, fields, votes, comments). The data is there either way.
      page_card_features: b.page_card_features,
      # Whether the wiki's tree shows pages' and folders' icons and colours
      # (#792). The names are in the listings either way.
      wiki_tree_icons: b.wiki_tree_icons,
      # How the wiki's tree orders the top of the board and every folder that
      # follows it (#789): by name until someone chooses.
      wiki_sort: b.wiki_sort,
      # The view opening the board lands on in the web app ("board", "wiki",
      # "table"…), from the board list, the switcher and favourites.
      default_view: Board.home_view(b),
      # A plain to-do list: a client should leave out the tracking details
      # (`hidden_facets`) and the Timeline and Prioritise views.
      simple: b.simple,
      hidden_facets: Board.hidden_facets(b),
      # Whether the board page shows its pulse strip; `GET .../pulse` has
      # the numbers on any board.
      show_pulse: b.show_pulse,
      delivery_metrics: b.delivery_metrics,
      card_ref_pattern: b.card_ref_pattern,
      incident_tag: b.incident_tag || "incident",
      hotfix_window_hours: b.hotfix_window_hours,
      not_shipped_minutes: b.not_shipped_minutes,
      deploy_token: Slipdock.Deployments.token?(b),
      automation_wip: b.automation_wip,
      # Agentic Building (#2011): the board menu's item and page for these
      # settings. Off hides them; the settings below hold either way.
      agentic_building: b.agentic_building,
      # How long runner job logs stay, in hours (#1872).
      job_log_hours: b.job_log_hours,
      failure_log_hours: b.failure_log_hours,
      # Verified work's switches (#1620), all off by default.
      bar_required: b.bar_required,
      # Lanes (#1628), off by default.
      lanes: b.lanes,
      # What an overlap does (#1972): off, hold or advise.
      lane_mode: b.lane_mode,
      # Profiles inferred when an agent starts a card (#1951), and each
      # profile's human tier on the tree (#1952), nil with profiles off.
      profiles: b.profiles,
      profile_tiers: if(b.profiles, do: Slipdock.Profiles.board_tiers(b)),
      # Globs that never count toward a lane (#1971); [] none.
      shared_paths: b.shared_paths,
      evidence_required: b.evidence_required,
      verify_work: b.verify_work,
      verify_pool: b.verify_pool,
      verify_rejection_limit: b.verify_rejection_limit,
      verify_audit: b.verify_audit,
      # A finding seen this many times is drafted as a proposal (#1942); 0 off.
      findings_propose_at: b.findings_propose_at,
      # An approval wait's proposal stands after this long (#2096): "4h"; nil off.
      wait_default_after: Slipdock.WaitDefaults.format(b.wait_default_after),
      # Who each kind of question goes to (#1949): kind => people, first is on.
      wait_routes: wait_routes(b),
      ship_via: b.ship_via,
      # How merged work reaches production (#2834), the tree root's.
      release_mode: release.mode,
      release_age_cap_hours: release.age_cap_hours,
      # The command a release job runs (#2835); nil is the default.
      release_command: release.command,
      # What the board calls a handoff, and its own drafting instructions
      # (nil: the built-in ones) (#1212).
      handoff_label: Board.handoff_label(b),
      handoff_prompt: b.handoff_prompt,
      columns:
        Enum.map(b.columns, fn col ->
          col
          |> column()
          |> Map.put(:cards, Enum.map(col.cards, &card/1))
          # Wiki pages placed in this list sit in the same order as its
          # cards, so a client that draws the list draws both.
          |> Map.put(:pages, Enum.map(placed(col), &page_summary/1))
        end)
    }
  end

  defp placed(%Column{pages: pages}) when is_list(pages), do: pages
  defp placed(_), do: []

  def column(%Column{} = c) do
    %{
      id: c.id,
      name: c.name,
      position: c.position,
      wip_limit: c.wip_limit,
      show_age: c.show_age,
      show_images: c.show_images,
      color: c.color,
      category: c.category,
      # How the web app draws the list's cards; `position` is still the
      # order they were put in.
      sort_by: c.sort_by,
      sort_dir: c.sort_dir,
      group_by: c.group_by,
      horizon:
        if Column.horizon?(c) do
          %{
            from: c.horizon_from,
            to: c.horizon_to,
            unit: c.horizon_unit,
            label: Column.horizon_label(c)
          }
        end
    }
  end

  def field_definition(%Slipdock.Boards.FieldDefinition{} = f) do
    %{
      id: f.id,
      name: f.name,
      key: f.key,
      kind: f.kind,
      position: f.position,
      options: f.options,
      config: f.config,
      sum: f.sum
    }
  end

  def milestone(%Slipdock.Boards.Milestone{} = m),
    do: %{id: m.id, name: m.name, date: m.date, color: m.color, card_id: m.card_id}

  def status_update(%Slipdock.Boards.StatusUpdate{} = u) do
    %{
      id: u.id,
      health: u.health,
      body: u.body,
      user_id: u.user_id,
      inserted_at: u.inserted_at
    }
  end

  # The card's handoff if it has one: nil when none was written, when the
  # newest row is a clear, or when the handoff wasn't loaded.
  defp current_handoff(%Card{handoff: %Slipdock.Boards.Handoff{} = h}) do
    if Slipdock.Boards.Handoff.cleared?(h), do: nil, else: handoff(h)
  end

  defp current_handoff(_), do: nil

  @doc "A handoff note: the one next step, the note, and who left it, when and how."
  def handoff(%Slipdock.Boards.Handoff{} = h) do
    %{
      id: h.id,
      next_step: h.next_step,
      body: h.body,
      cleared: Slipdock.Boards.Handoff.cleared?(h),
      by: if(match?(%Slipdock.Accounts.User{}, h.user), do: person_ref(h.user)),
      via: h.via,
      job_id: h.job_id,
      at: h.inserted_at
    }
  end

  @doc """
  A card's timeline (#1131, `Slipdock.CardTimeline`): its stays in lists,
  waits and jobs, each with `from`, `to`, `seconds` and `open`.
  """
  def timeline(%Slipdock.CardTimeline{} = t) do
    %{
      from: t.from,
      to: t.to,
      stays:
        Enum.map(t.stays, fn s ->
          s
          |> Map.take(~w(list category board_id from to open unsure how)a)
          |> Map.put(:seconds, Slipdock.CardTimeline.seconds(s))
        end),
      waits: Enum.map(t.waits, &Map.put(&1, :seconds, Slipdock.CardTimeline.seconds(&1))),
      jobs: Enum.map(t.jobs, &Map.put(&1, :seconds, Slipdock.CardTimeline.seconds(&1)))
    }
  end

  @doc "A card's snooze, while it is snoozed: until when, why, who and how it wakes."
  def snooze(%Card{} = c) do
    if Card.snoozed?(c) do
      %{
        until: c.snoozed_until,
        note: c.snooze_note,
        by_id: c.snoozed_by_id,
        at: c.snoozed_at,
        notify: c.snooze_notify,
        wake_on_activity: c.snooze_wake_on_activity
      }
    end
  end

  def snooze(_), do: nil

  defp current_recurrence(%Card{recurrence: %Slipdock.Recurrence.Series{} = s}), do: recurrence(s)
  defp current_recurrence(_), do: nil

  @doc """
  A recurring card's series: the rule (stored form and in words), when and
  where instances are made, what a missed one does, when it ends, and the
  next one.
  """
  def recurrence(%Slipdock.Recurrence.Series{} = s) do
    rule = Slipdock.Recurrence.Series.rule(s)

    %{
      id: s.id,
      card_id: s.card_id,
      kind: s.kind,
      rule: s.rule,
      summary: Slipdock.Recurrence.Series.summary(s),
      starts_on: s.starts_on,
      at: Calendar.strftime(s.create_at, "%H:%M"),
      timezone: s.timezone,
      lead_days: s.lead_days,
      column_id: s.column_id,
      on_missed: s.on_missed,
      ends: s.ends,
      ends_on: s.ends_on,
      count: s.count,
      made: s.made,
      next_on: s.next_on,
      next_at: s.next_at,
      upcoming:
        if(s.next_on && Slipdock.Recurrence.Series.active?(s),
          do: [s.next_on | Slipdock.Recurrence.Rule.upcoming(rule, s.next_on, 2)],
          else: []
        ),
      paused: s.paused,
      ended_at: s.ended_at,
      last_created_card_id: s.last_created_card_id
    }
  end

  def tag(%Tag{} = t), do: %{id: t.id, name: t.name, color: t.color}

  # A wiki page placed in a list stands beside the cards in every view, so it
  # comes back from a grid too — as the page summary it is, `kind: "page"` and
  # all, rather than pretending to be a card.
  def card(%Page{} = p), do: page_summary(p)

  def card(%Card{} = c) do
    checklist = if Ecto.assoc_loaded?(c.checklist_items), do: c.checklist_items, else: []
    comments = if Ecto.assoc_loaded?(c.comments), do: c.comments, else: []
    attachments = if Ecto.assoc_loaded?(c.attachments), do: c.attachments, else: []
    urls = if Ecto.assoc_loaded?(c.urls), do: c.urls, else: []

    %{
      id: c.id,
      board_id: c.board_id,
      column_id: c.column_id,
      column: if(Ecto.assoc_loaded?(c.column), do: c.column.name),
      position: c.position,
      title: c.title,
      # A label for tight spaces, and its folder's name on disk (W-2201).
      short_name: c.short_name,
      short_name_edited: c.short_name_edited,
      # "card" or "document" — a card whose whole content is the file on it
      # (see `Slipdock.Kinds`), which is what `cards?kind=` filters by.
      kind: Slipdock.Kinds.kind_of(c),
      # Where the card was left: read this before the comments (W-1804).
      handoff: current_handoff(c),
      # The series this card is the current instance of, when it repeats
      # (W-1802); `series_id` marks any instance a series made.
      recurrence: current_recurrence(c),
      series_id: c.series_id,
      # Hidden until a moment (W-1803): nil when it isn't snoozed.
      snoozed_until: if(Card.snoozed?(c), do: c.snoozed_until),
      snooze: snooze(c),
      description: c.description,
      priority: c.priority,
      flags: c.flags,
      # Who clears each flag (#2624): "person" when somebody has to act,
      # "auto" when the board's own processes clear it, "none" for a mark
      # that asks nothing, each with a line saying why.
      flag_attention: Slipdock.Attention.map(c),
      tags: if(Ecto.assoc_loaded?(c.tags), do: Enum.map(c.tags, & &1.name), else: []),
      start_date: c.start_date,
      due_date: c.due_date,
      date_precision: c.date_precision,
      completed: c.completed,
      completed_at: c.completed_at,
      percent_complete: c.percent_complete,
      time: time(c),
      stated_health: Card.stated_health(c),
      fields: field_values(c),
      scores: Map.get(c, :scores) || %{},
      votes: Card.vote_total(c),
      status_updates:
        if(Ecto.assoc_loaded?(c.status_updates),
          do: Enum.map(c.status_updates, &status_update/1),
          else: []
        ),
      color: c.color,
      # Each edge's own colour (#1209); nil is none.
      border_top: c.border_top,
      border_right: c.border_right,
      border_bottom: c.border_bottom,
      border_left: c.border_left,
      archived_at: c.archived_at,
      assignee: assignee(c),
      assignees: Enum.map(Card.assignees(c), &person_ref/1),
      rollup: rollup(c),
      blocked: Card.blocked?(c),
      blocked_by: dependency_stubs(c.blocked_by),
      blocks: dependency_stubs(c.blocks),
      links: links(c),
      sub_board: sub_board_summary(c),
      stand_in_for: stand_in_for(c),
      checklist: %{
        done: Enum.count(checklist, & &1.done),
        total: length(checklist),
        items: Enum.map(checklist, &checklist_item/1)
      },
      comments: Enum.map(comments, &comment/1),
      attachments: Enum.map(attachments, &attachment/1),
      urls: Enum.map(urls, &card_url/1),
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
    |> put_open_wait(c)
    |> put_verified(c)
    # What is happening to it and how long it has sat in its list (#1117):
    # only the keys there is something to say for.
    |> Map.merge(Slipdock.CardState.to_map(c.state))
  end

  # Verified work (#1620): only the keys a card has something in, so a card
  # on a board with the switches off reads as it always has.
  defp put_verified(map, %Card{} = c) do
    [
      bar: c.bar,
      bar_locked_at: c.bar_locked_at,
      evidence: c.evidence,
      evidence_commit: c.evidence_commit,
      evidence_branch: c.evidence_branch,
      evidence_tests: c.evidence_tests,
      evidence_suite: c.evidence_suite,
      evidence_pr: c.evidence_pr,
      evidence_no_code: c.evidence_no_code,
      # What kind of change it is (#1951): one word, or nil.
      profile: c.profile,
      # Where it came from (#2018): "inferred", "person", "agent", "rule", or
      # nil (no profile, or not recorded).
      profile_source: c.profile_source,
      # Who or what made it (#2778, `Slipdock.Origin`), and the runner job
      # an agent made it in; nil on cards made before origins were kept.
      origin: c.origin,
      origin_job_id: c.origin_job_id,
      # Where an agent's completion stands, on a board that verifies (#1633).
      verify_state: c.verify_state,
      verify_note: c.verify_note,
      verify_commit: c.verify_commit,
      merge_sha: c.merge_sha,
      verify_submitter: c.verify_submitter,
      verify_by: c.verify_by,
      verify_at: c.verify_at,
      verify_rejections: if(c.verify_rejections > 0, do: c.verify_rejections),
      # The last decision's verdict in parts (#1778).
      verify_checks: c.verify_checks,
      # The paths its work touches (#1628), when it declares any.
      paths: if(not Enum.member?([nil, []], c.paths), do: c.paths),
      # An incident (#1946): the card that caused it and the check that
      # missed it, when it says.
      caused_by: c.caused_by_id,
      missed_by: c.missed_by
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.into(map)
  end

  # Waiting on a person (#1114): only on a card that is, so a board with no
  # waits reads as it always has.
  defp put_open_wait(map, %Card{} = c) do
    case Card.open_wait(c) do
      nil -> map
      w -> Map.put(map, :wait, wait(w))
    end
  end

  @doc """
  A wait (#1114): what is needed, its numbered questions and their answers
  (#1220), from whom, the choices, who opened it (as `Slipdock.Actor`
  classified them), and how it ended once it has.
  """
  def wait(nil), do: nil

  def wait(%Slipdock.Boards.Wait{} = w) do
    %{
      id: w.id,
      card_id: w.card_id,
      needs: w.needs,
      # A numbered series (#1220): [] when it asks the one thing in needs.
      questions: w.questions,
      on: wait_person(w.on_user),
      choices: w.choices,
      opened_by: wait_person(w.opened_by),
      # The opener's actor kind; `question` is the kind of question (#1949).
      kind: w.kind,
      question: w.question,
      via: w.via,
      agent: w.agent,
      job_id: w.job_id,
      set_flag: w.set_flag,
      opened_at: w.inserted_at,
      open: is_nil(w.closed_at),
      closed_at: w.closed_at,
      closed_by: wait_person(w.closed_by),
      close_reason: w.close_reason,
      answer: w.answer,
      answers: w.answers,
      choice: w.choice,
      choice_text: Slipdock.Boards.Wait.choice_text(w, w.choice),
      # The choice the asker proposes (#2096), from 1; nil when none.
      default_choice: w.default_choice,
      requeue_state: w.requeue_state,
      requeue_note: w.requeue_note
    }
  end

  defp wait_person(%Slipdock.Accounts.User{} = u), do: person_ref(u)
  defp wait_person(_), do: nil

  # Time tracking, in the card's own unit with the raw minutes beside it so
  # nothing has to know what a "day" is to add them up. `spent` includes a
  # running timer; `percent` is of the estimate and can pass 100.
  defp time(%Card{} = c) do
    alias Slipdock.TimeTracking, as: T
    unit = c.time_unit || T.default_unit()
    spent = T.spent(c)

    %{
      unit: unit,
      spent: T.in_unit(spent, unit),
      estimate: T.in_unit(c.time_estimate, unit),
      spent_minutes: spent,
      estimate_minutes: c.time_estimate,
      percent: T.percent(c),
      timer_running: T.running?(c),
      timer_started_at: c.timer_started_at
    }
  end

  # Stored custom field values keyed by field key (formulas are under `scores`).
  defp field_values(%Card{field_values: values}) when is_list(values) do
    for %{field: %Slipdock.Boards.FieldDefinition{} = f} = v <- values,
        into: %{},
        do: {f.key, Slipdock.Boards.FieldValue.get(v)}
  end

  defp field_values(_), do: %{}

  # Who the board belongs to. nil on a board with no owner — one made before
  # accounts existed, and open until somebody claims it.
  defp owner_ref(%Board{owner: %Slipdock.Accounts.User{} = u}),
    do: %{id: u.id, email: u.email, name: Slipdock.Accounts.User.display_name(u)}

  defp owner_ref(_), do: nil

  defp owner?(%Board{owner_id: id}, %Slipdock.Accounts.User{id: id}) when not is_nil(id), do: true
  defp owner?(_board, _viewer), do: false

  defp shared?(%Board{owner_id: nil}, _viewer), do: false
  defp shared?(%Board{}, nil), do: false
  defp shared?(%Board{owner_id: owner_id}, %Slipdock.Accounts.User{id: id}), do: owner_id != id
  defp shared?(%Board{}, _viewer), do: false

  # `assignee` is the lead — the first of `assignees` — kept for anything
  # written when a card had only one.
  defp assignee(%Card{} = c) do
    case Card.assignees(c) do
      [lead | _] -> person_ref(lead)
      [] -> nil
    end
  end

  defp person_ref(u),
    do: %{id: u.id, email: u.email, name: Slipdock.Accounts.User.display_name(u)}

  @doc """
  What turning Agentic Building off says (#2011) when the board still has
  agent rules set: they go on holding, out of sight in the web app. nil
  when nothing is set, or the switch is on.
  """
  def agentic_warning(%Board{agentic_building: true}), do: nil

  def agentic_warning(%Board{} = b) do
    case Slipdock.AgenticBuilding.live_rules(b) do
      [] ->
        nil

      rules ->
        "Agentic Building is off, but these still hold: " <>
          Enum.join(rules, ", ") <> ". Turn it on again to see or change them in the web app."
    end
  end

  @doc "A board's wait routes (#1949): each kind of question => its people, in order."
  def wait_routes(%Board{} = b) do
    b
    |> Slipdock.WaitRoutes.routes()
    |> Map.new(fn {k, users} -> {k, Enum.map(users, &person_ref/1)} end)
  end

  # What the card's subcards roll up to (see Slipdock.Rollup); nil for a leaf.
  defp rollup(%Card{rollup: %{children: n} = r}) when n > 0 do
    %{
      done: r.done,
      total: r.total,
      start: r.start,
      due: r.due,
      start_derived: r.start_derived?,
      due_derived: r.due_derived?,
      # What the subcards themselves say, whether or not the card's own dates
      # win above. Without these, `due_slip_days` is a number with nothing on
      # screen to measure it against.
      derived_start: r.derived_start,
      derived_due: r.derived_due,
      # `slip_days` is the due-date overrun, kept under its old name so
      # existing callers do not break; `start_slip_days` is the new one.
      slip_days: r.due_slip,
      due_slip_days: r.due_slip,
      start_slip_days: r.start_slip,
      blocked: r.blocked,
      overdue: r.overdue,
      health: r.health,
      depth: r.depth
    }
    # Subcards waiting for verification (#1624), only when there are some.
    |> then(&if(Map.get(r, :awaiting, 0) > 0, do: Map.put(&1, :awaiting, r.awaiting), else: &1))
  end

  defp rollup(_), do: nil

  # A stand-in names the card it stands for and where that card has got to
  # (see `SlipdockWeb.SlipdockComponents.stand_in_state/1`); nil on a card.
  defp stand_in_for(%Card{stand_in_for_id: nil}), do: nil

  defp stand_in_for(%Card{stand_in_for_id: id} = c) do
    target = if Ecto.assoc_loaded?(c.stand_in_for), do: c.stand_in_for

    %{
      id: id,
      title: target && target.title,
      board_id: target && target.board_id,
      status: to_string(SlipdockWeb.SlipdockComponents.stand_in_state(target))
    }
  end

  defp sub_board_summary(%Card{sub_board: %Board{} = b} = c) do
    {done, total} = Card.subcard_progress(c)
    columns = if Ecto.assoc_loaded?(b.columns), do: b.columns, else: []
    cards = if Ecto.assoc_loaded?(b.cards), do: b.cards, else: []

    awaiting = Enum.count(cards, &(&1.verify_state == "pending" and not &1.completed))

    %{
      id: b.id,
      name: b.name,
      completed: done,
      total: total,
      columns:
        Enum.map(columns, fn col ->
          %{id: col.id, name: col.name, cards: Enum.count(cards, &(&1.column_id == col.id))}
        end)
    }
    # Subcards waiting for verification (#1624), only when there are some.
    |> then(&if(awaiting > 0, do: Map.put(&1, :awaiting, awaiting), else: &1))
  end

  defp sub_board_summary(_), do: nil

  defp links(%Card{links_out: out, links_in: inn}) when is_list(out) and is_list(inn) do
    Enum.map(out, fn l -> %{id: l.id, kind: l.kind, direction: "out", card: link_stub(l.to)} end) ++
      Enum.map(inn, fn l ->
        %{id: l.id, kind: l.kind, direction: "in", card: link_stub(l.from)}
      end)
  end

  defp links(_), do: []

  defp link_stub(%Card{} = c) do
    %{
      id: c.id,
      title: c.title,
      completed: c.completed,
      board_id: c.board_id,
      board: if(match?(%Board{}, c.board), do: c.board.name)
    }
  end

  # A stub the reader can't see (`hidden`, see
  # `Slipdock.Access.hide_unreadable_dependencies/3`) keeps its id and state
  # but says nothing of its title or board.
  defp dependency_stubs(deps) when is_list(deps) do
    Enum.map(deps, fn d ->
      %{
        id: d.id,
        title: d.title,
        completed: d.completed,
        archived: not is_nil(d.archived_at),
        released: d.verify_released == true,
        board_id: d.board_id,
        board: if(match?(%Board{}, d.board), do: d.board.code),
        hidden: d.hidden == true
      }
    end)
  end

  defp dependency_stubs(_), do: []

  def attachment(%Slipdock.Boards.Attachment{} = a) do
    %{
      id: a.id,
      filename: a.filename,
      content_type: a.content_type,
      size: a.size,
      sha256: a.sha256,
      url: Slipdock.Boards.Attachments.attachment_url(a),
      hide_on_card: a.hide_on_card,
      transcript_status: a.transcript_status,
      transcript: a.transcript,
      transcript_error: a.transcript_error,
      text_status: text_status(a),
      inserted_at: a.inserted_at
    }
  end

  # Where reading the file for text has got to (see `Slipdock.OCR`). The text
  # itself is `GET /api/attachments/:id/text`: it can be a megabyte.
  defp text_status(%Slipdock.Boards.Attachment{
         document_text: %Slipdock.OCR.Text{status: status}
       }),
       do: status

  defp text_status(_attachment), do: nil

  def card_url(%Slipdock.Boards.CardUrl{} = u) do
    %{
      id: u.id,
      url: u.url,
      title: u.title,
      label: Slipdock.Boards.CardUrl.label(u),
      added_at: u.inserted_at
    }
  end

  def checklist_item(%ChecklistItem{} = i),
    do: %{id: i.id, text: i.text, done: i.done, position: i.position}

  # `author` is who wrote it, shaped like an assignee; null for a comment from
  # before authors were kept, or one the system wrote.
  def comment(%Comment{} = c),
    do: %{id: c.id, body: c.body, author: author(c), inserted_at: c.inserted_at}

  defp author(%Comment{user: %Slipdock.Accounts.User{} = u}), do: person_ref(u)
  defp author(_), do: nil

  @doc """
  A saved view. `favourite?` is the *reading* user's own mark, not the
  view's: favourites belong to people (see `Slipdock.Favourites`).
  """
  def saved_view(%SavedView{} = v, favourite? \\ false) do
    %{
      id: v.id,
      board_id: v.board_id,
      name: v.name,
      favourite: favourite?,
      config: v.config |> Config.from_map() |> Config.to_map(),
      url: "/boards/#{v.board_id}/swimlanes?view=#{v.id}",
      inserted_at: v.inserted_at,
      updated_at: v.updated_at
    }
  end

  @doc "A swimlane grid (see `Slipdock.Swimlanes.grid/2`) with each cell's cards."
  def grid(%Board{} = board, grid, %Config{} = config, view \\ nil, favourite? \\ false) do
    col_names = Map.new(board.columns, &{&1.id, &1.name})

    %{
      view: view && saved_view(view, favourite?),
      config: Config.to_map(config),
      rows: Enum.map(grid.rows, &bucket/1),
      cols: Enum.map(grid.cols, &bucket/1),
      cells:
        Enum.map(grid.rows, fn row ->
          Enum.map(row.cells, fn cards ->
            Enum.map(cards, fn c -> c |> card() |> Map.put(:column, col_names[c.column_id]) end)
          end)
        end),
      shown: grid.shown,
      hidden: grid.hidden
    }
  end

  defp bucket(b), do: %{key: b.key, label: b.label, count: b.count, color: b.color, tone: b.tone}

  def activity(%Activity{} = a),
    do: %{
      id: a.id,
      kind: a.kind,
      card_id: a.card_id,
      page_id: a.page_id,
      message: a.message,
      at: a.inserted_at
    }

  ## Wiki --------------------------------------------------------------------

  @doc """
  A page without its body: what listings and trees return, so asking for a
  board's wiki does not hand back every word on it.
  """
  def page_summary(%Page{} = p) do
    %{
      id: p.id,
      code: p.code,
      number: p.number,
      board_id: p.board_id,
      parent_id: p.parent_id,
      # Where it is filed, as opposed to what it is part of: its home folder.
      folder_id: p.folder_id,
      # Listed in a folder it is also filed in, rather than its home.
      also: p.also,
      title: p.title,
      # The third kind of thing a list can hold (see `Slipdock.Kinds`), said out
      # loud so a client holding cards and pages together can tell them apart.
      kind: "page",
      slug: p.slug,
      summary: p.summary,
      status: p.status,
      template: p.template,
      position: p.position,
      archived_at: p.archived_at,
      content_hash: p.content_hash,
      url: page_url(p),
      # Whether anyone with a link can read it, and the link if so.
      # The card facets a page carries (see `Slipdock.Wiki.Page`), so a client
      # that draws a card can draw a page.
      priority: p.priority,
      flags: p.flags,
      start_date: p.start_date,
      due_date: p.due_date,
      date_precision: p.date_precision,
      completed: p.completed,
      percent_complete: p.percent_complete,
      color: p.color,
      # What it wears in the wiki, tinted by `color` (#792).
      icon: p.icon,
      assignee: assignee_ref(p),
      tags: page_tags(p),
      # The tags the note gives itself, on a board in a vault — never the
      # board's card tags above (see `Slipdock.Wiki.NoteTags`).
      note_tags: p.note_tags,
      # The other names `[[links]]` find it by, from its front matter.
      aliases: p.aliases,
      # Where it sits on the board, when it has been put there.
      column_id: p.column_id,
      board_position: p.column_id && p.board_position,
      published: not is_nil(p.public_token),
      published_at: p.published_at,
      public_url: p.public_token && "/w/#{p.public_token}",
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  @doc "A page in full: the Markdown source, not HTML — the model edits what it reads."
  def page(%Page{} = p) do
    checklist = loaded(p.checklist_items)

    p
    |> page_summary()
    |> Map.merge(%{
      body: p.body,
      # The YAML of the front matter the page's file came with, kept exactly
      # (see `Slipdock.Wiki.FrontMatter`); null for a page that had none.
      front_matter: Slipdock.Wiki.FrontMatter.yaml(p.front_matter),
      # The folders it is also filed in, beside its home `folder_id`.
      also_in: Enum.map(Slipdock.Wiki.Placements.folders(p), &placement_folder/1),
      created_by: user_ref(p.created_by),
      updated_by: user_ref(p.updated_by),
      # The card contents a page carries (see `Slipdock.Boards.Owned`), named
      # and shaped exactly as a card's are.
      stated_health: Card.stated_health(p),
      votes: Card.vote_total(p),
      fields: page_field_values(p),
      status_updates: Enum.map(loaded(p.status_updates), &status_update/1),
      checklist: %{
        done: Enum.count(checklist, & &1.done),
        total: length(checklist),
        items: Enum.map(checklist, &checklist_item/1)
      },
      comments: Enum.map(loaded(p.comments), &comment/1),
      urls: Enum.map(loaded(p.urls), &card_url/1)
    })
  end

  defp loaded(list) when is_list(list), do: list
  defp loaded(_), do: []

  defp page_field_values(%Page{field_values: values}) when is_list(values) do
    for %{field: %Slipdock.Boards.FieldDefinition{} = f} = v <- values,
        into: %{},
        do: {f.key, Slipdock.Boards.FieldValue.get(v)}
  end

  defp page_field_values(_), do: %{}

  @doc "A page and its children, however deep — `%{page: …, children: […]}` nodes."
  def page_tree(nodes) when is_list(nodes) do
    Enum.map(nodes, fn %{page: page, children: children} ->
      page |> page_summary() |> Map.put(:children, page_tree(children))
    end)
  end

  defp placement_folder(%Slipdock.Wiki.Folder{} = f),
    do: %{
      folder_id: f.id,
      board_id: f.board_id,
      board: f.board && f.board.code,
      path: Slipdock.Wiki.folder_path(f)
    }

  @doc """
  One wiki folder — filing, not writing (see `Slipdock.Wiki.Folder`).
  `also_in` is where else it is filed (#808): given, or looked up.
  """
  def folder(%Slipdock.Wiki.Folder{} = f, also_in \\ nil) do
    also_in = also_in || Slipdock.Wiki.FolderPlacements.folders(f)

    %{
      id: f.id,
      board_id: f.board_id,
      parent_id: f.parent_id,
      name: f.name,
      slug: f.slug,
      # The card it is the folder of, if any (W-2201 rule 3).
      card_id: f.card_id,
      path: Slipdock.Wiki.folder_path(f),
      position: f.position,
      # Its own order in the tree, or nil to follow the board's (#789).
      sort: f.sort,
      # What it wears on the main page and in the tree (#792).
      icon: f.icon,
      color: f.color,
      # The folders it is also filed in, beside its home (#808).
      also_in: Enum.map(also_in, &placement_folder/1),
      inserted_at: f.inserted_at,
      updated_at: f.updated_at
    }
  end

  @doc """
  A vault (see `Slipdock.Vaults`), for `reader`: its settings, how many pages
  it holds, and the boards in it.
  """
  def vault(%Slipdock.Vaults.Vault{} = v, %Slipdock.Accounts.User{} = reader) do
    %{
      id: v.id,
      name: v.name,
      owned: v.user_id == reader.id,
      # How it is reached in the web app (#1204): b then `shortcut`, and its
      # owner's Ctrl+Shift digit, if they gave it one.
      shortcut: v.shortcut,
      hotkey: Slipdock.Hotkeys.get(%Slipdock.Accounts.User{id: v.user_id}, v),
      # The vault's own view in the web app (#752).
      url: SlipdockWeb.VaultUrls.url(v),
      pages: Slipdock.Vaults.page_count(v),
      # `empty`: nothing written on it or below it, so a tree leaves it out.
      boards:
        (fn empty ->
           v
           |> Slipdock.Vaults.tree_boards()
           |> Enum.map(&Map.put(vault_board(&1), :empty, MapSet.member?(empty, &1.board.id)))
         end).(Slipdock.Vaults.empty_board_ids(v)),
      # The folders it is synced to, as far as the server can tell: each
      # token that has listed it or followed its feed (`touch_mirror/2`).
      mirrors:
        v
        |> Slipdock.Vaults.mirrors()
        |> Enum.map(&%{label: &1.label, last_synced_at: &1.last_synced_at}),
      # Where its meeting recordings are on the owner's Google Drive (W-1690).
      recordings_folder: v.recordings_folder,
      inserted_at: v.inserted_at,
      updated_at: v.updated_at
    }
  end

  @doc """
  The reader's one wiki (W-2201), as `/api/wiki` gives it: what `vault/2`
  says, less the name and id a person no longer sees, and where their
  Knowledge Base is.
  """
  def wiki(%Slipdock.Vaults.Vault{} = v, %Slipdock.Accounts.User{} = reader) do
    kb = Slipdock.Wiki.KnowledgeBase.get(reader)

    v
    |> vault(reader)
    |> Map.drop([:id, :name, :owned])
    |> Map.put(:knowledge_base, kb && %{id: kb.id, code: kb.code, name: kb.name})
    # The websocket topic its changes are announced on.
    |> Map.put(:channel, "vault:#{v.id}")
  end

  @doc """
  One board in a vault: where its folder is and what a client needs to show
  it. `archived` is a flag and nothing more: the path stays the same.
  """
  def vault_board(%Slipdock.Vaults.Vault{} = v, board_id) do
    v |> Slipdock.Vaults.boards() |> Enum.find(&(&1.board.id == board_id)) |> vault_board()
  end

  def vault_board(%{board: b, path: path}) do
    %{
      id: b.id,
      code: b.code,
      name: b.name,
      path: "/" <> path,
      archived: not is_nil(b.archived_at),
      wiki_tree_icons: b.wiki_tree_icons,
      wiki_sort: b.wiki_sort
    }
  end

  @doc """
  A folder tree with the pages filed in each — `%{folder:, children:, pages:}`
  nodes, as `Slipdock.Wiki.Folders.tree/2` builds them.
  """
  def folder_tree(nodes, also \\ %{}) when is_list(nodes) do
    ids = tree_folder_ids(nodes)
    also_in = Slipdock.Wiki.FolderPlacements.by_folder(ids)
    folder_tree(nodes, also, also_in, Slipdock.Wiki.CardFolders.labels(ids))
  end

  defp folder_tree(nodes, also, also_in, labels) do
    Enum.map(nodes, fn %{folder: f, children: children, pages: pages} ->
      # The pages also filed here follow the ones at home, marked `also`,
      # each page once (W-103 R12.6, R12.7).
      home_ids = MapSet.new(pages, & &1.page.id)

      placed =
        also
        |> Map.get(f.id, [])
        |> Enum.reject(&MapSet.member?(home_ids, &1.id))
        |> Enum.map(&(&1 |> page_summary() |> Map.put(:children, [])))

      f
      |> folder(Map.get(also_in, f.id, []))
      |> Map.merge(%{
        title: (labels[f.id] || %{title: f.name}).title,
        short_name: labels[f.id][:short_name],
        folders: folder_tree(children, also, also_in, labels),
        pages: page_tree(pages) ++ placed
      })
    end)
  end

  defp tree_folder_ids(nodes),
    do: Enum.flat_map(nodes, &[&1.folder.id | tree_folder_ids(&1.children)])

  def revision(%Revision{} = r) do
    %{
      id: r.id,
      page_id: r.page_id,
      title: r.title,
      summary: r.summary,
      via: r.via,
      agent: r.agent,
      byte_size: r.byte_size,
      author: user_ref(r.author),
      at: r.inserted_at
    }
  end

  @doc "A diff as `Slipdock.Wiki.diff/2` returns it, as JSON-safe hunks."
  def diff(hunks) do
    Enum.map(hunks, fn {op, lines} -> %{op: to_string(op), lines: lines} end)
  end

  def page_url(%Page{} = p), do: "/boards/#{p.board_id}/wiki/#{p.slug}"

  defp assignee_ref(%Page{assignee: %Slipdock.Accounts.User{} = u}),
    do: %{id: u.id, email: u.email, name: u.name}

  defp assignee_ref(_), do: nil

  defp page_tags(%Page{tags: tags}) when is_list(tags), do: Enum.map(tags, & &1.name)
  defp page_tags(_), do: []

  @doc "One reference written in a page."
  def link(%Link{} = l) do
    %{
      id: l.id,
      kind: l.kind,
      raw: l.raw,
      label: l.label,
      count: l.count,
      pinned: l.pinned,
      resolved: l.resolved,
      target: link_target(l)
    }
  end

  defp link_target(%Link{kind: "page", target_page: %Page{} = p}),
    do: %{id: p.id, code: p.code, title: p.title, url: page_url(p)}

  defp link_target(%Link{kind: "card", target_card: %Card{} = c}),
    do: %{
      id: c.id,
      title: c.title,
      url: "/boards/#{c.board_id}/cards/#{c.id}",
      completed: c.completed
    }

  defp link_target(%Link{kind: "board", target_board: %Board{} = b}),
    do: %{id: b.id, code: b.code, name: b.name, url: "/boards/#{b.id}"}

  defp link_target(%Link{kind: "view", target_view: %SavedView{} = v}),
    do: %{id: v.id, name: v.name, url: "/boards/#{v.board_id}?view=#{v.id}"}

  defp link_target(_), do: nil

  @doc "A page that links here, as the other end of the arrow."
  def backlink(%Link{page: %Page{} = p} = l),
    do: %{page: page_summary(p), count: l.count, pinned: l.pinned, raw: l.raw}

  # Writing on a card is writing: a card that names a page is a backlink too.
  def backlink(%Link{source_card: %Card{} = c} = l),
    do: %{card: card_stub(c), count: l.count, pinned: l.pinned, raw: l.raw}

  @doc """
  A board's lanes as they hold for it (#1628, #1971, #1972): `%{on:, mode:,
  shared_paths:}`, the switch and the mode as its tree has them and the globs that never count toward a lane
  there (its root's and its own); nil on a board with neither.
  """
  def board_lanes(%Slipdock.Boards.Board{} = board) do
    on = Slipdock.Lanes.on?(board)
    shared = Slipdock.Lanes.shared_paths(board)

    if on or shared != [],
      do: %{on: on, mode: Slipdock.Lanes.mode(board), shared_paths: shared}
  end

  @doc """
  Who created a card and who changed it last (#2028), on a single card's
  JSON (`Slipdock.CardAuthors`): `created_by` and `updated_by`, each
  `%{kind:, name:, user_id:}` (`kind` one of person, agent, runner,
  automation; a runner's also has `job_id`) or nil when nobody is
  recorded, and `updated_at` replaced by the card's last change: the later
  of its newest activity row and its own `updated_at`.
  """
  def put_authors(map, %Card{} = card) do
    authors = Slipdock.CardAuthors.for_card(card)

    map
    |> Map.put(:created_by, author_json(authors.created_by))
    |> Map.put(:updated_by, author_json(authors.updated_by))
    |> Map.put(:updated_at, authors.updated_at)
  end

  defp author_json(nil), do: nil
  defp author_json(%{} = who), do: Map.take(who, [:kind, :name, :user_id, :job_id])

  @doc """
  The instance of a series `card` was copied from (#2081), as `copied_from`
  (`%{id, title}`): left off for a card no series made, for the first, and
  when `user` can't read the one it came from.
  """
  def put_copied_from(map, %Card{} = card, user) do
    case Slipdock.Recurrence.copied_from(card, user) do
      nil -> map
      from -> Map.put(map, :copied_from, %{id: from.id, title: from.title})
    end
  end

  @doc """
  Lanes on a card's JSON. Shared paths (#1971), when its board has any:
  `shared_paths`, the globs that never count toward a lane there (what the
  lane-check hook lets through), and `paths_shared`, those of the card's own
  paths wholly inside one. And `lane_overlap` (#1972), with lanes on and a
  card in progress in the way: `%{card:, title:, mode:}`, `mode` saying
  whether it holds this card (`hold`) or only tells (`advise`), and, when
  a broad glob makes it (#2698), `broad` (`this`, `other` or `both`: whose
  glob is broad) and `broad_paths` (those globs). `paths_broad` (#2698)
  lists the card's own globs that claim a whole top-level directory
  (`Slipdock.Lanes.broad?/2`), with `paths_broad_reason`: advice, nothing
  is refused for them. Each is left off when there is nothing to say.
  """
  def put_lanes(map, %Card{} = card) do
    board = Slipdock.Boards.get_board_record(card.board_id)
    shared = Slipdock.Lanes.shared_paths(board)

    map
    |> put_shared(card, shared)
    |> put_broad(card, shared)
    |> put_overlap(board, card, shared)
  end

  defp put_broad(map, card, shared) do
    case Slipdock.Lanes.broad_paths(card.paths, shared) do
      [] ->
        map

      broad ->
        map
        |> Map.put(:paths_broad, broad)
        |> Map.put(:paths_broad_reason, Slipdock.Lanes.broad_reason())
    end
  end

  defp put_shared(map, _card, []), do: map

  defp put_shared(map, card, shared) do
    map
    |> Map.put(:shared_paths, shared)
    |> Map.put(:paths_shared, Enum.filter(card.paths, &Slipdock.Lanes.shared?(&1, shared)))
  end

  defp put_overlap(map, board, card, shared) do
    with true <- board != nil and Slipdock.Lanes.on?(board),
         %Card{} = other <- Slipdock.Lanes.conflict(card) do
      overlap =
        %{card: other.id, title: other.title, mode: Slipdock.Lanes.mode(board)}
        |> put_broad_side(Slipdock.Lanes.broad_overlap(card, other, shared))

      Map.put(map, :lane_overlap, overlap)
    else
      _ -> map
    end
  end

  defp put_broad_side(overlap, nil), do: overlap

  defp put_broad_side(overlap, %{side: side, this: this, other: other}),
    do: Map.merge(overlap, %{broad: side, broad_paths: this ++ other})

  @doc "How many open findings the card has (W-2310 §Findings)."
  def put_findings(map, %Card{} = card),
    do: Map.put(map, :findings, Slipdock.Findings.open_count(card))

  @doc """
  Puts both ends of an incident (#1946) on a card's JSON, as `user` may read
  them through `token` (which only narrows): `caused_by_card`, the card it
  names as its cause (`hidden` with no title when it can't be read), and
  `incidents`, the cards naming it as theirs, each with the check that missed
  it. Left off when there are none.
  """
  def put_incidents(map, %Card{} = card, user, token \\ nil) do
    cause =
      case Slipdock.Incidents.cause(card) do
        nil ->
          nil

        cause ->
          if Slipdock.Incidents.readable?(cause, user, token),
            do: incident_stub(cause),
            else: %{id: cause.id, hidden: true}
      end

    caused =
      card
      |> Slipdock.Incidents.caused_readable(user, token)
      |> Enum.map(&Map.put(incident_stub(&1), :missed_by, &1.missed_by))

    [caused_by_card: cause, incidents: if(caused != [], do: caused)]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Enum.into(map)
  end

  defp incident_stub(%Card{} = c) do
    %{
      id: c.id,
      title: c.title,
      completed: c.completed,
      board_id: c.board_id,
      board: if(match?(%Board{}, c.board), do: c.board.code)
    }
  end

  @doc """
  How the card's work ships, on a board that ships by pull request (#1655):
  the branch and what the builder does. Nothing on a push board.
  """
  def put_shipping(map, %Card{} = card) do
    case Slipdock.Verified.ship_instructions(card) do
      nil ->
        map

      text ->
        Map.put(map, :shipping, %{
          via: "pull_request",
          branch: Slipdock.Verified.pr_branch(card),
          # A security card's PR describes the change neutrally (#1794).
          neutral: Slipdock.Verified.neutral?(card),
          instructions: text
        })
    end
  end

  @doc """
  Puts a card's handbook (#1265, see `Slipdock.Handbook.for_card/3`) on its
  JSON: the index and the sections to read before building. Left off when
  the card's root board keeps no handbook, or `user` can't read it.
  """
  def put_handbook(map, card, user, token) do
    case Slipdock.Handbook.for_card(card, user, token: token) do
      nil -> map
      handbook -> Map.put(map, :handbook, handbook)
    end
  end

  @doc "The answer a live query block gives, whatever shape it takes."
  def query_result(%{kind: :count} = result), do: %{kind: "count", count: result.count}

  def query_result(%{kind: :progress} = result),
    do: %{
      kind: "progress",
      done: result.done,
      total: result.total,
      percent: result.percent,
      label: result[:label]
    }

  def query_result(%{kind: :list} = result),
    do: %{kind: "list", count: result[:count], cards: Enum.map(result.cards, &card_stub/1)}

  def query_result(%{kind: :groups} = result),
    do: %{
      kind: "groups",
      count: result[:count],
      groups:
        Enum.map(
          result.groups,
          &%{label: &1.label, cards: Enum.map(&1.cards, fn c -> card_stub(c) end)}
        )
    }

  def query_result(%{kind: :table} = result),
    do: %{
      kind: "table",
      count: result[:count],
      headers: result.headers,
      fields: result.keys,
      rows: Enum.map(result.rows, &%{card: card_stub(&1.card), cells: &1.cells})
    }

  def query_result(%{kind: :pages} = result),
    do: %{
      kind: "pages",
      count: result[:count],
      headers: result.headers,
      fields: result.keys,
      rows:
        Enum.map(
          result.rows,
          &%{page: %{id: &1.page.id, code: &1.page.code, title: &1.page.title}, cells: &1.cells}
        )
    }

  def query_result(_result), do: %{kind: "unknown"}

  defp card_stub(%Card{} = c),
    do: %{
      id: c.id,
      title: c.title,
      board_id: c.board_id,
      completed: c.completed,
      url: "/boards/#{c.board_id}/cards/#{c.id}"
    }

  @doc "A page linked to but never written."
  def wanted(%{raw: raw, title: title, count: count, from: from}),
    do: %{raw: raw, title: title, count: count, from: Enum.map(from, &page_summary/1)}

  defp user_ref(%Slipdock.Accounts.User{} = u), do: %{id: u.id, email: u.email, name: u.name}
  defp user_ref(_), do: nil

  def automation(%Rule{} = r) do
    %{
      id: r.id,
      board_id: r.board_id,
      name: r.name,
      summary: Rule.summary(r),
      source: r.source,
      spec: r.spec,
      trigger: Rule.trigger_type(r),
      scheduled: Rule.scheduled?(r),
      scope: r.scope,
      enabled: r.enabled,
      run_count: r.run_count,
      last_run_at: r.last_run_at,
      last_error: r.last_error,
      inserted_at: r.inserted_at
    }
  end

  def callback(%Callback{} = c) do
    %{
      id: c.id,
      board_id: c.board_id,
      rule_id: c.rule_id,
      rule: c.rule_name,
      card_id: c.card_id,
      card: c.card_title,
      method: c.method,
      url: c.url,
      ok: Callback.ok?(c),
      status: c.status,
      error: c.error,
      duration_ms: c.duration_ms,
      at: c.inserted_at
    }
  end

  def alert(%Alert{} = a) do
    %{
      id: a.id,
      title: a.title,
      body: a.body,
      severity: a.severity,
      board_id: a.board_id,
      board: if(Ecto.assoc_loaded?(a.board) and a.board, do: a.board.name),
      card_id: a.card_id,
      card: if(Ecto.assoc_loaded?(a.card) and a.card, do: a.card.title),
      rule_id: a.rule_id,
      url:
        if(a.card_id,
          do: "/boards/#{a.board_id}/cards/#{a.card_id}",
          else: "/boards/#{a.board_id}"
        ),
      at: a.inserted_at
    }
  end

  @doc "A runner, for the board's owner. Never its token."
  def runner(%Slipdock.Runners.Runner{} = r) do
    %{
      id: r.id,
      name: r.name,
      pool: r.pool,
      board_id: r.board_id,
      current_job_id: r.current_job_id,
      last_seen_at: r.last_seen_at,
      # The job kinds it said it takes on its last claim (#1656); nil if never.
      kinds: r.kinds,
      missing_kinds: Slipdock.Runners.missing_kinds(r),
      # Its installed skills and CLI against what this server serves (#1795).
      drift: drift(r),
      session: Slipdock.Runners.Runner.session?(r),
      # A machine's runner (#2571); nil for a session's, or a retired shell
      # runner's, with a token of its own (#2582).
      machine_id: r.machine_id,
      settings: r.settings || %{},
      created_at: r.inserted_at
    }
  end

  defp drift(runner) do
    %{skills: skills, cli: cli} = Slipdock.Runners.Drift.states(runner)

    %{
      skills: skills_word(skills),
      drifted_skills: drifted_names(skills),
      cli: to_string(cli)
    }
  end

  # `unsigned` (#2916): they differ from an archive served with no signature.
  defp skills_word({state, _names}), do: to_string(state)
  defp skills_word(state), do: to_string(state)

  defp drifted_names({_state, names}), do: names
  defp drifted_names(_state), do: []

  @doc """
  `%{paused: [pause, ...]}` while `board`'s tree or a pool on it is paused
  (#1116), else `%{}`: merged into get_board, list_cards and the board and
  cards answers, so an agent with no pool still sees the brake.
  """
  def paused(%Board{} = board) do
    case Slipdock.Runners.pauses(board) do
      [] -> %{}
      pauses -> %{paused: Enum.map(pauses, &pause/1)}
    end
  end

  def pause(nil), do: nil

  def pause(%Slipdock.Runners.Pause{} = p) do
    %{
      id: p.id,
      board_id: p.root_board_id,
      pool: p.pool,
      scope: Slipdock.Runners.Pause.scope(p),
      reason: p.reason,
      by: Slipdock.Runners.Pause.who(p),
      line: Slipdock.Runners.Pause.line(p),
      paused_at: p.inserted_at,
      resumed_at: p.resumed_at
    }
  end

  @doc """
  Where a read of a job's live log (#1871) stands: the job, whether more
  can come, the line it read `from` and the `next` to read from. REST adds
  the `entries`, MCP the `log` as text.
  """
  def job_log(%Slipdock.Runners.Job{} = job, from, next) do
    %{
      job: %{
        id: job.id,
        card_id: job.card_id,
        status: job.status,
        open: Slipdock.Runners.Job.open?(job)
      },
      from: from,
      next: next,
      capped: job.transcript_capped
    }
  end

  @doc "One entry of a job's log (#1871), with `line` the way `slipdock job-log` prints it."
  def log_entry(entry) do
    %{
      id: entry.id,
      at: entry.at,
      kind: entry.kind,
      text: entry.text,
      detail: entry.detail,
      line: Slipdock.Runners.TranscriptView.format(entry)
    }
  end

  def job(%Slipdock.Runners.Job{} = j) do
    %{
      id: j.id,
      card_id: j.card_id,
      card: if(Ecto.assoc_loaded?(j.card) and j.card, do: j.card.title),
      card_url:
        "#{Slipdock.Automations.Runner.base_url()}/boards/#{j.board_id}/cards/#{j.card_id}",
      board_id: j.board_id,
      rule_id: j.rule_id,
      pool: j.pool,
      kind: j.kind,
      status: j.status,
      runner_id: j.runner_id,
      runner: j.runner_name,
      attempts: j.attempts,
      wait_while_doing: j.wait_while_doing,
      # A verify job re-checking an accepted card (#1780).
      audit: j.audit,
      recovery: j.recovery,
      # Why a queued job isn't being taken (#1116): paused, WIP full,
      # waiting on a card in progress, or no runner online for its pool.
      waiting_on: Slipdock.Runners.held_reason(j),
      cancel_requested: not is_nil(j.cancel_requested_at),
      exit_code: j.exit_code,
      error: j.error,
      prompt: j.prompt,
      log_tail: j.log_tail,
      # Its live log (#1870): the transcript lines held so far, read with
      # GET /api/jobs/:id/transcript.
      transcript_lines: j.transcript_lines,
      transcript_capped: j.transcript_capped,
      transcript_at: j.transcript_at,
      # Kept or not (#1872): when the log goes (nil while the job runs, once
      # kept or gone), the page Keep this log wrote, and when it went.
      transcript_expires_at: Slipdock.Runners.TranscriptRetention.expires_at(j),
      transcript_failure: Slipdock.Runners.TranscriptRetention.failure?(j),
      transcript_page_id: j.transcript_page_id,
      transcript_deleted_at: j.transcript_deleted_at,
      # The latest progress message its agent gave (#1668), and when.
      step: j.step,
      step_at: j.step_at,
      # Every step it reported, oldest first (#1875): `[{text, at}]`.
      steps: j.steps || [],
      output: j.output,
      queued_at: j.inserted_at,
      claimed_at: j.claimed_at,
      started_at: j.started_at,
      finished_at: j.finished_at,
      lease_expires_at: j.lease_expires_at
    }
  end

  def errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
