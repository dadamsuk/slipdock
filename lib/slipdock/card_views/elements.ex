defmodule Slipdock.CardViews.Elements do
  @moduledoc """
  What a card view can switch on or off (#2031): every element of a card's
  front, then each section of the opened card's main panel (`open.`) and
  each group of its sidebar (`side.`).

  The front's keys are the Display facets (`Slipdock.Swimlanes.Config.facets/1`)
  and the marks the tile used to show whatever was chosen. An element's
  default is what a card showed before card views: the front's essentials
  (`Config.default_show/1`, which differs by card size), every mark, and every
  section and group of the opened card.
  """

  alias Slipdock.Swimlanes.Config

  @open [
    {"open.glance", "At a glance: Handoff"},
    {"open.wait", "Waiting on a person"},
    {"open.description", "Description"},
    {"open.profile", "Profile"},
    {"open.bar", "Bar"},
    {"open.paths", "Paths"},
    {"open.evidence", "Evidence"},
    {"open.verification", "Verification"},
    {"open.attachments", "Attachments"},
    {"open.checklist", "Checklist"},
    {"open.subcards", "Subcards"},
    {"open.dependencies", "Dependencies"},
    {"open.incident", "Incident"},
    {"open.docs", "Docs"},
    {"open.findings", "Findings"},
    {"open.jobs", "Jobs"},
    {"open.lead_time", "Lead time"},
    {"open.links", "Links"},
    {"open.urls", "URLs"},
    {"open.comments", "Comments and activity"},
    {"open.timeline", "Timeline"},
    {"open.sharing", "Sharing"},
    {"open.ai", "Ask AI"}
  ]

  @side [
    {"side.time", "Time"},
    {"side.status", "Status updates"},
    {"side.fields", "Fields"},
    {"side.votes", "Votes"},
    {"side.cover", "Cover"},
    {"side.borders", "Borders"},
    {"side.repeat", "Repeat"},
    {"side.snooze", "Snooze"}
  ]

  # The front's keys are read from `Config` when called, not when compiled:
  # a compile-time dependency on it would join the compile-connected cycle.
  @open_keys Enum.map(@open, &elem(&1, 0))
  @side_keys Enum.map(@side, &elem(&1, 0))
  @panel_keys @open_keys ++ @side_keys

  @doc "The card front's elements, as `{key, label}`."
  def front, do: Config.facets() ++ Enum.map(Config.card_marks(), fn {k, l, _} -> {k, l} end)
  @doc "The opened card's main-panel sections, as `{key, label}`."
  def open, do: @open
  @doc "The opened card's sidebar groups, as `{key, label}`."
  def side, do: @side

  @doc "The three groups, as `{group, title, [{key, label}]}`, for an editor or a listing."
  def groups,
    do: [
      {"front", "Card front", front()},
      {"open", "Opened card", @open},
      {"side", "Sidebar", @side}
    ]

  def keys, do: front_keys() ++ @panel_keys
  def front_keys, do: Enum.map(front(), &elem(&1, 0))
  def panel_keys, do: @panel_keys

  @doc "Whether `key` is an element a card view can set."
  def known?(key) when key in @panel_keys, do: true
  def known?(key), do: Enum.member?(front_keys(), key)

  @doc "An element's label, or the key itself."
  def label(key) do
    Enum.find_value(front() ++ @open ++ @side, key, fn {k, l} -> if k == key, do: l end)
  end

  @doc "Whether `key` is on when nothing states it, for a card of `density`."
  def default?(key, density \\ "normal")
  def default?(key, _density) when key in @panel_keys, do: true

  def default?(key, density),
    do: Enum.member?(Config.marks_on(), key) or Enum.member?(Config.default_show(density), key)

  @doc "Every element and its default, for a card of `density`."
  def defaults(density \\ "normal"), do: Map.new(keys(), &{&1, default?(&1, density)})
end
