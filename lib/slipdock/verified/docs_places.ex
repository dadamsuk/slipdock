defmodule Slipdock.Verified.DocsPlaces do
  @moduledoc """
  The docs-places step of the verify and audit prompts: the rule it checks,
  the seven places a reader looks for what Slipdock does, whether a card
  falls in the rule's scope, and what the verifier and the builder are told.
  """

  alias Slipdock.Boards.Card

  ## The docs places (#2694) ---------------------------------------------------

  @docs_rule "SPEC-10"

  # The seven places a reader looks for what Slipdock does (SPEC-10), each
  # with the files to grep.
  @docs_places [
    {"the README", "README.md"},
    {"the manual", "docs/manual.md docs/manual/"},
    {"the app's in-app help (`HelpLive.Guides`)",
     "lib/slipdock_web/live/help_live/guides.ex lib/slipdock_web/live/help_live/guides/"},
    {"the agents' and runners' in-app help (`HelpLive.Agents`, `HelpLive.Flow`, and the CLI reference's `cli/help.txt`)",
     "lib/slipdock_web/live/help_live/agents.ex lib/slipdock_web/live/help_live/agents/ lib/slipdock_web/live/help_live/flow.ex lib/slipdock_web/live/help_live/flow/ cli/help.txt"},
    {"the agents page", "docs/agents.md"},
    {"the API guide", "lib/slipdock_web/api_guide.ex lib/slipdock_web/api_guide/"},
    {"the skills", "priv/skills/"}
  ]

  @doc "The rule whose places the docs-places step enumerates (#2694)."
  def docs_places_rule, do: @docs_rule

  @doc "The seven docs places (#2694): `{name, the files to grep}` each."
  def docs_places, do: @docs_places

  @doc """
  Whether `card` falls in the docs-places rule's scope (#2694), on `handbook`
  (as `Slipdock.Handbook.find/1` gives it): `:in` when its lane paths meet
  the scope of the handbook's `SPEC-10`, `:out` when they don't or the
  handbook has no such rule (or there is no handbook), and `:unknown` when
  the card has no paths, so the step is given for the diff to decide.
  """
  def docs_places_scope(_card, nil), do: :out

  def docs_places_scope(%Card{} = card, handbook) do
    rule = Enum.find(Slipdock.Handbook.Rules.rules(handbook), &(&1.id == @docs_rule))

    cond do
      rule == nil -> :out
      Enum.member?([nil, []], card.paths) -> :unknown
      Enum.any?(Slipdock.Handbook.rules_for(handbook, card.paths), &(&1.id == @docs_rule)) -> :in
      true -> :out
    end
  end

  @doc false
  def docs_places_steps(card, handbook, base, sha, opts) do
    case docs_places_scope(card, handbook) do
      :out -> []
      scope -> [docs_places_step(base, sha, scope, opts)]
    end
  end

  @doc """
  The docs-places step of a verify or audit prompt (#2694), for a card in
  SPEC-10's scope: enumerate the places, don't judge them. The names the
  change introduces or alters, from the diff, grepped across each of the
  seven places, and each place reported as updated, deferred to a card
  whose bar names it, n/a with why, or missing. `scope` is `:in`, or
  `:unknown` for a card with no paths (the diff's rules decide).
  """
  def docs_places_step(base, sha, scope \\ :in, opts \\ []) do
    lead =
      if scope == :unknown,
        do:
          "If the rules above list #{@docs_rule} (the card declared no paths, so its diff decides), check its places by enumerating them, not by judging them.",
        else:
          "This card's paths fall in #{@docs_rule}'s scope, so check its places by enumerating them, not by judging them."

    broken =
      if opts[:audit],
        do: "One `missing` is a disagreement",
        else: "One `missing` is a rejection"

    """
    The docs places (#{@docs_rule}). #{lead}
       - The names: read the diff (`git diff $(git merge-base #{base} #{sha}) #{sha}`) and list every name the change introduces or alters that a reader would look up: commands, flags and switches, MCP tool names and their fields, API paths and fields, settings, page and section names.
       - The places, seven:
    #{docs_places_lines()}
       - For each name, grep each place at the commit (`rg -n '<name>' <files>`), and give each place one result:
         - `updated`: the change edits it and it says the new or altered name.
         - `deferred to #N`: the builder left it to card #N, and #N's bar names this place (`slipdock card N`). A deferral to a card whose bar doesn't name the place doesn't count: it is `missing`.
         - `n/a`, with why: a reader wouldn't look for this name here (an internal helper, a page that doesn't cover it).
         - `missing`: none of these.
       - Give the seven results in the reason, one per place with the names checked (`Docs places: README updated; the manual updated; the skills deferred to #123; the API guide n/a (no API change); …`). #{broken}: `--check rule:#{@docs_rule}=broken:<place's file>:<the name it lacks>`, one line per place and name, every one in this round. All seven accounted for is `--check rule:#{@docs_rule}=ok`. Step: `checking the docs places`\
    """
  end

  defp docs_places_lines do
    @docs_places
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{name, files}, n} ->
      "     #{n}. #{name}: `#{files}`"
    end)
  end

  @doc """
  What a builder is told about the docs places (#2694), in a claimed job's
  prompt for a card in SPEC-10's scope: the same enumeration the verifier
  runs, and a place left out goes on the deferral card's bar by name, or the
  deferral doesn't count.
  """
  def docs_places_builder do
    "The docs places (#{@docs_rule}): this card's paths fall in its scope, so the verifier enumerates them rather than judging them, and so do you before submitting. List every name the change introduces or alters (commands, flags, MCP tool names, API fields, settings, page and section names), grep each across the seven places, and give each place as updated, deferred to #N, n/a with why, or missing. The places:\n" <>
      docs_places_lines() <>
      "\nA place your lane can't reach is deferred to a card you file: list each left-out place on that card's bar, by name with the names it must cover (`--bar \"1. docs/agents.md says --foo …\"`), and name the card in your evidence. A deferral to a card whose bar doesn't list the place doesn't count, and the verifier rejects it as missing."
  end
end
