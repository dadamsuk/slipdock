defmodule Slipdock.AgenticBuilding do
  @moduledoc """
  Agentic Building (#2011): the board's one switch for how agents build on
  it. On, the board menu has an **Agentic Building** item opening a page
  (`SlipdockWeb.AgenticLive.Index`) that holds every setting about it:
  verified work, lanes, profiles and the human tier, findings, who gets
  asked, handoffs, WIP limits holding automated work and runner job logs.

  The switch only shows and hides: off, every setting keeps its value and
  goes on holding, so work already running keeps its rules. `live_rules/1`
  names the ones set, which turning it off warns about, and
  `backfill_sql/0` is what the migration turned it on with.
  """

  alias Slipdock.Boards.Board

  # Each setting the page holds, with its default and what it is called.
  # A setting away from its default is a live rule.
  @rules [
    {:bar_required, false, "A bar before work starts"},
    {:evidence_required, false, "Evidence on completion"},
    {:verify_work, false, "A second agent verifies"},
    {:verify_pool, nil, "A verify pool"},
    {:verify_rejection_limit, 2, "A rejection limit"},
    {:verify_audit, 0, "Audits"},
    {:ship_via, "push", "Shipping by pull request"},
    {:lane_mode, "off", "Lanes"},
    {:shared_paths, [], "Shared paths"},
    {:profiles, false, "Profiles"},
    {:profile_tiers, %{}, "A human tier"},
    {:findings_propose_at, 3, "Findings promotion"},
    {:wait_routes, %{}, "Who gets asked"},
    {:wait_default_after, nil, "Approval waits default"},
    {:handoff_label, nil, "A handoff label"},
    {:handoff_prompt, nil, "Handoff instructions"},
    {:automation_wip, false, "WIP limits holding automated work"},
    {:job_log_hours, 24, "Job log retention"},
    {:failure_log_hours, 168, "Failure log retention"}
  ]

  @doc "The settings the page holds, as board fields."
  def fields, do: Enum.map(@rules, &elem(&1, 0))

  @doc "Whether the board shows its Agentic Building item and page."
  def on?(%Board{agentic_building: on}), do: on == true
  def on?(_), do: false

  @doc """
  The settings on this board that are away from their defaults, by name,
  in the page's order: what turning the switch off would hide while it
  goes on holding.
  """
  def live_rules(%Board{} = board) do
    for {field, default, label} <- @rules, set?(Map.get(board, field), default), do: label
  end

  defp set?(value, default) when value in [nil, "", [], %{}],
    do: not Enum.member?([nil, "", [], %{}], default)

  defp set?(value, default), do: value != default

  @doc """
  The SQL the migration ran (#2011): every board with one of the page's
  settings away from its default turns the switch on, so nobody's settings
  drop out of sight on deploy. Kept here so a test runs the same text.
  """
  def backfill_sql do
    """
    UPDATE boards SET agentic_building = true
    WHERE bar_required OR evidence_required OR verify_work
       OR verify_pool IS NOT NULL OR verify_rejection_limit <> 2 OR verify_audit <> 0
       OR ship_via <> 'push' OR lanes OR lane_mode <> 'off'
       OR cardinality(shared_paths) > 0
       OR profiles OR profile_tiers <> '{}'::jsonb
       OR findings_propose_at <> 3 OR wait_routes <> '{}'::jsonb
       OR handoff_label IS NOT NULL OR handoff_prompt IS NOT NULL
       OR automation_wip OR job_log_hours <> 24 OR failure_log_hours <> 168
    """
  end
end
