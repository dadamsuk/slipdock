defmodule SlipdockWeb.BoardLive.Paths do
  @moduledoc """
  Where everything on a board lives. Every route is a (mode, panel) pair: the
  mode is the main view and the panel is the modal open on top of it. Each
  panel is reachable from every mode, and the view configuration travels
  along in the query string (`swim_query`).
  """
  use SlipdockWeb, :verified_routes

  import SlipdockWeb.SwimlaneComponents, only: [view_mode_path: 3]

  # The close path already carries the view's own query, so the page id is
  # appended rather than replacing it.
  def append_query(path, extra) do
    case String.split(path, "?", parts: 2) do
      [base] ->
        base <> "?" <> URI.encode_query(extra)

      [base, query] ->
        base <>
          "?" <>
          URI.encode_query(
            URI.decode_query(query)
            |> Map.merge(Map.new(extra, fn {k, v} -> {to_string(k), to_string(v)} end))
          )
    end
  end

  # Every route is a (mode, panel) pair: the mode is the main view (board or
  # swimlanes) and the panel is the modal open on top of it, if any.
  def split_action(:show), do: {:board, nil}
  def split_action(:card), do: {:board, :card}
  def split_action(:tags), do: {:board, :tags}
  def split_action(:activity), do: {:board, :activity}
  def split_action(:archive), do: {:board, :archive}
  def split_action(:settings), do: {:board, :settings}
  def split_action(:automations), do: {:board, :automations}
  def split_action(:swimlanes), do: {:swimlanes, nil}
  def split_action(:swimlanes_card), do: {:swimlanes, :card}
  def split_action(:swimlanes_tags), do: {:swimlanes, :tags}
  def split_action(:swimlanes_activity), do: {:swimlanes, :activity}
  def split_action(:swimlanes_archive), do: {:swimlanes, :archive}
  def split_action(:swimlanes_settings), do: {:swimlanes, :settings}
  def split_action(:swimlanes_automations), do: {:swimlanes, :automations}
  def split_action(:table), do: {:table, nil}
  def split_action(:table_card), do: {:table, :card}
  def split_action(:table_tags), do: {:table, :tags}
  def split_action(:table_activity), do: {:table, :activity}
  def split_action(:table_archive), do: {:table, :archive}
  def split_action(:table_settings), do: {:table, :settings}
  def split_action(:table_automations), do: {:table, :automations}
  def split_action(:timeline), do: {:timeline, nil}
  def split_action(:timeline_card), do: {:timeline, :card}
  def split_action(:timeline_tags), do: {:timeline, :tags}
  def split_action(:timeline_activity), do: {:timeline, :activity}
  def split_action(:timeline_archive), do: {:timeline, :archive}
  def split_action(:timeline_settings), do: {:timeline, :settings}
  def split_action(:timeline_automations), do: {:timeline, :automations}
  def split_action(:calendar), do: {:calendar, nil}
  def split_action(:calendar_card), do: {:calendar, :card}
  def split_action(:calendar_tags), do: {:calendar, :tags}
  def split_action(:calendar_activity), do: {:calendar, :activity}
  def split_action(:calendar_archive), do: {:calendar, :archive}
  def split_action(:calendar_settings), do: {:calendar, :settings}
  def split_action(:calendar_automations), do: {:calendar, :automations}
  def split_action(:outline), do: {:outline, nil}
  def split_action(:outline_card), do: {:outline, :card}
  def split_action(:outline_tags), do: {:outline, :tags}
  def split_action(:outline_activity), do: {:outline, :activity}
  def split_action(:outline_archive), do: {:outline, :archive}
  def split_action(:outline_settings), do: {:outline, :settings}
  def split_action(:outline_automations), do: {:outline, :automations}
  def split_action(:narrative), do: {:narrative, nil}
  def split_action(:narrative_card), do: {:narrative, :card}
  def split_action(:narrative_tags), do: {:narrative, :tags}
  def split_action(:narrative_activity), do: {:narrative, :activity}
  def split_action(:narrative_archive), do: {:narrative, :archive}
  def split_action(:narrative_settings), do: {:narrative, :settings}
  def split_action(:narrative_automations), do: {:narrative, :automations}
  def split_action(:prioritise), do: {:prioritise, nil}
  def split_action(:prioritise_card), do: {:prioritise, :card}
  def split_action(:prioritise_tags), do: {:prioritise, :tags}
  def split_action(:prioritise_activity), do: {:prioritise, :activity}
  def split_action(:prioritise_archive), do: {:prioritise, :archive}
  def split_action(:prioritise_settings), do: {:prioritise, :settings}
  def split_action(:prioritise_automations), do: {:prioritise, :automations}

  def panel_path(%{mode: :board, board: b, swim_query: q}, :close), do: ~p"/boards/#{b}?#{q}"
  def panel_path(%{mode: :board, board: b, swim_query: q}, :tags), do: ~p"/boards/#{b}/tags?#{q}"

  def panel_path(%{mode: :board, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/activity?#{q}"

  def panel_path(%{mode: :board, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/archive?#{q}"

  def panel_path(%{mode: :board, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/settings?#{q}"

  def panel_path(%{mode: :board, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/automations?#{q}"

  def panel_path(%{mode: :swimlanes, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/swimlanes?#{q}"

  def panel_path(%{mode: :swimlanes, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/swimlanes/tags?#{q}"

  def panel_path(%{mode: :swimlanes, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/swimlanes/activity?#{q}"

  def panel_path(%{mode: :swimlanes, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/swimlanes/archive?#{q}"

  def panel_path(%{mode: :swimlanes, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/swimlanes/settings?#{q}"

  def panel_path(%{mode: :swimlanes, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/swimlanes/automations?#{q}"

  def panel_path(%{mode: :table, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/table?#{q}"

  def panel_path(%{mode: :table, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/table/tags?#{q}"

  def panel_path(%{mode: :table, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/table/activity?#{q}"

  def panel_path(%{mode: :table, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/table/archive?#{q}"

  def panel_path(%{mode: :table, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/table/settings?#{q}"

  def panel_path(%{mode: :table, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/table/automations?#{q}"

  def panel_path(%{mode: :timeline, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/timeline?#{q}"

  def panel_path(%{mode: :timeline, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/timeline/tags?#{q}"

  def panel_path(%{mode: :timeline, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/timeline/activity?#{q}"

  def panel_path(%{mode: :timeline, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/timeline/archive?#{q}"

  def panel_path(%{mode: :timeline, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/timeline/settings?#{q}"

  def panel_path(%{mode: :timeline, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/timeline/automations?#{q}"

  def panel_path(%{mode: :calendar, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/calendar?#{q}"

  def panel_path(%{mode: :calendar, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/calendar/tags?#{q}"

  def panel_path(%{mode: :calendar, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/calendar/activity?#{q}"

  def panel_path(%{mode: :calendar, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/calendar/archive?#{q}"

  def panel_path(%{mode: :calendar, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/calendar/settings?#{q}"

  def panel_path(%{mode: :calendar, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/calendar/automations?#{q}"

  def panel_path(%{mode: :outline, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/outline?#{q}"

  def panel_path(%{mode: :outline, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/outline/tags?#{q}"

  def panel_path(%{mode: :outline, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/outline/activity?#{q}"

  def panel_path(%{mode: :outline, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/outline/archive?#{q}"

  def panel_path(%{mode: :outline, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/outline/settings?#{q}"

  def panel_path(%{mode: :outline, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/outline/automations?#{q}"

  def panel_path(%{mode: :narrative, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/narrative?#{q}"

  def panel_path(%{mode: :narrative, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/narrative/tags?#{q}"

  def panel_path(%{mode: :narrative, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/narrative/activity?#{q}"

  def panel_path(%{mode: :narrative, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/narrative/archive?#{q}"

  def panel_path(%{mode: :narrative, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/narrative/settings?#{q}"

  def panel_path(%{mode: :narrative, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/narrative/automations?#{q}"

  def panel_path(%{mode: :prioritise, board: b, swim_query: q}, :close),
    do: ~p"/boards/#{b}/prioritise?#{q}"

  def panel_path(%{mode: :prioritise, board: b, swim_query: q}, :tags),
    do: ~p"/boards/#{b}/prioritise/tags?#{q}"

  def panel_path(%{mode: :prioritise, board: b, swim_query: q}, :activity),
    do: ~p"/boards/#{b}/prioritise/activity?#{q}"

  def panel_path(%{mode: :prioritise, board: b, swim_query: q}, :archive),
    do: ~p"/boards/#{b}/prioritise/archive?#{q}"

  def panel_path(%{mode: :prioritise, board: b, swim_query: q}, :settings),
    do: ~p"/boards/#{b}/prioritise/settings?#{q}"

  def panel_path(%{mode: :prioritise, board: b, swim_query: q}, :automations),
    do: ~p"/boards/#{b}/prioritise/automations?#{q}"

  def card_path(%{mode: :board, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/cards/#{id}?#{q}"

  def card_path(%{mode: :swimlanes, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/swimlanes/cards/#{id}?#{q}"

  def card_path(%{mode: :table, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/table/cards/#{id}?#{q}"

  def card_path(%{mode: :timeline, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/timeline/cards/#{id}?#{q}"

  def card_path(%{mode: :calendar, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/calendar/cards/#{id}?#{q}"

  def card_path(%{mode: :prioritise, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/prioritise/cards/#{id}?#{q}"

  def card_path(%{mode: :outline, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/outline/cards/#{id}?#{q}"

  def card_path(%{mode: :narrative, board: b, swim_query: q}, id),
    do: ~p"/boards/#{b}/narrative/cards/#{id}?#{q}"

  # The base URL of the current mode with a query.
  def mode_path(%{board: b} = assigns, query),
    do: view_mode_path(b, Map.get(assigns, :mode, :swimlanes), query)
end
