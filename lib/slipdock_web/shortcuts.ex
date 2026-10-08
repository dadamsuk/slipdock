defmodule SlipdockWeb.Shortcuts do
  @moduledoc """
  The catalogue of keyboard shortcuts, and the one place that knows them.

  `sections/0` is what the help sheet (`?`) renders and what the manual
  (`docs/manual.md`) describes; the keys themselves are acted on by the `Keys`, `BoardKeys` and
  `CardKeys` hooks in `assets/js/app.js`, which read this list nowhere — so a
  key added here is documentation, and a key added there is behaviour. Keep
  them in step. A card's section keys are the letters underlined in its
  headings, which `SlipdockWeb.SlipdockComponents.keyed_label/1` draws.
  """

  @sections [
    {"Anywhere",
     [
       {"Ctrl-P", "Commands — type what you want to do"},
       {"Ctrl-O", "Open a card — type its title, or a page's code"},
       {"h", "All boards"},
       {"b", "Switch board — then the board's own key"},
       {"q", "Quick add a card"},
       {"l", "Alerts"},
       {"?", "This list"},
       {"Esc", "Close whatever is open"}
     ]},
    {"On a board",
     [
       {"v", "Switch view — then the view's key"},
       {"/", "Search the board"},
       {"a", "Chat about this page with AI"},
       {"j", "Label every card on screen; type a label to open that card"},
       {"J", "Label every card; type a label to pick it up and move it"},
       {"c", "Label every list; type a label to step through it"}
     ]},
    {"On an open card",
     [
       {"j k ↑ ↓", "Scroll the card"},
       {"h l", "The section before or after"},
       {"PgUp PgDn", "A screenful at a time"},
       {"Home End", "The top or the bottom"},
       {"f t d", "Flags · Tags · Description"},
       {"a e s", "Attachments · Checklist · Subcards"},
       {"p n", "Dependencies · Links"},
       {"w c", "Web links · Comments"},
       {"Esc", "Close the card"}
     ]},
    {"Carrying a card (after J)",
     [
       {"h l ← →", "Move it to the list either side"},
       {"j k ↑ ↓", "Move it up or down its own list"},
       {"Enter", "Drop it"},
       {"Esc", "Let go, leaving it where it is"}
     ]},
    {"Stepping through a list (after c)",
     [
       {"j k ↑ ↓", "The card above or below"},
       {"h l ← →", "The list either side"},
       {"Enter", "Open the card"},
       {"J", "Pick the card up"},
       {"c", "Add a card to this list"},
       {"Esc", "Stop"}
     ]},
    {"In a palette you type into",
     [
       {"↑ ↓", "The row above or below"},
       {"Enter", "Follow the row you are on"},
       {"Esc", "Close it"}
     ]},
    {"While labels are showing",
     [
       {"a–z, 0–9", "Type a label; it narrows as you go"},
       {"Backspace", "Un-type a character"},
       {"Esc", "Dismiss the labels"}
     ]}
  ]

  @doc "The shortcuts, grouped by where they work, for the help sheet and the docs."
  def sections, do: @sections

  @doc "Every shortcut as a flat list of `{key, description}`."
  def all, do: Enum.flat_map(@sections, fn {_section, keys} -> keys end)
end
