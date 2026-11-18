defmodule SlipdockWeb.Ops.EditCard do
  @moduledoc """
  Changing a card's fields, `PATCH /api/cards/:id`, defined once (#3361):
  the REST action and the CLI's `edit` (and `done`, `undone`, `flag`, `tag`,
  `set` and `log`, which are usages of it). The MCP tools `update_card` and
  `complete_card` combine it with other operations (SPEC-4), so they stay
  hand-composed, and take each param they share with it from here
  (`SlipdockWeb.Ops.params_from/2`).

  Every body param is `:any`, passed to `CardWrites.update/3` as sent, and
  `null: true`, a null clearing the field: what the route has always taken.
  `schema` is the MCP schema the composite tools share.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias SlipdockWeb.API.{Authorize, CardWrites}
  import SlipdockWeb.Ops.Shared, only: [card_json: 2]

  @list %{type: "array", items: %{type: "string"}}

  @border %{
    type: "string",
    description: "That edge of the card's front in a palette colour; \"\" takes it off."
  }

  @suite %{
    type: "object",
    properties: %{
      result: %{type: "string", enum: ["passed", "failed"]},
      passed: %{type: "integer", minimum: 0},
      failed: %{type: "integer", minimum: 0}
    },
    required: ["result"],
    additionalProperties: false,
    description: "The test suite's result and counts."
  }

  @doc """
  The body params: `{name, schema}`, in the order the guide lists them.
  Functions, not attributes, where the schema reads the app's lists.
  """
  def body do
    [
      {"title", %{type: "string"}},
      {"short_name",
       %{
         type: "string",
         description: "At most 40 characters, for tight spaces. \"\" hands it back to be made."
       }},
      {"description", %{type: "string", description: "Replaces the whole description."}},
      {"priority", %{type: "string", enum: ["none", "low", "medium", "high", "critical"]}},
      {"start_date", %{type: "string", description: "YYYY-MM-DD; \"\" clears it."}},
      {"due_date", %{type: "string", description: "YYYY-MM-DD; \"\" clears it."}},
      {"date_precision",
       %{type: "string", description: "How exact the dates are: day, month or year."}},
      {"percent_complete", %{type: "integer", minimum: 0, maximum: 100}},
      {"completed",
       %{type: "boolean", description: "Done or not; complete_card also moves it to done."}},
      {"bar",
       %{
         type: "string",
         description: "What done means for it; locks when work starts, where the board asks."
       }},
      {"paths",
       %{
         type: "array",
         items: %{type: "string"},
         description:
           "Globs of the files its work touches (lib/x/**); [] clears. They scope the " <>
             "card's handbook rules and feed its profile."
       }},
      {"profile",
       %{
         type: "string",
         enum: Slipdock.Profiles.names() ++ [""],
         description:
           "What kind of change it is: security, schema, feature, fix, docs or spike; \"\" " <>
             "clears it. Inferred when an agent starts it on a board with profiles on."
       }},
      {"caused_by",
       %{
         type: ["integer", "null"],
         description:
           "This card is an incident: the id of the card whose shipping caused it, on any " <>
             "board you can read. null clears it."
       }},
      {"missed_by",
       %{
         type: ["string", "null"],
         enum: Slipdock.Boards.Card.layers() ++ [nil],
         description:
           "The check that should have caught the incident: bar, rules, ci, verify, audit " <>
             "or none. With caused_by it records a process finding (source incident) on " <>
             "the causing card. null clears it."
       }},
      {"color",
       %{
         type: "string",
         enum: ["" | Slipdock.Palette.names()],
         description: "The card's cover colour, from the palette; \"\" takes it off."
       }},
      {"border_top", border()},
      {"border_right", border()},
      {"border_bottom", border()},
      {"border_left", border()},
      {"time_spent", %{type: "string", description: "Time spent so far: 90m, 1.5h, 2d."}},
      {"time_estimate", %{type: "string", description: "Time it should take: 90m, 1.5h, 2d."}},
      {"time_unit",
       %{type: "string", enum: ~w(minutes hours days weeks months), description: "Time's unit."}},
      {"log_time", %{type: "string", description: "Adds this to the time spent: 45m, 1h 30m."}},
      {"flags", Map.put(@list, :description, "Replaces the card's flags.")},
      {"add_flags", @list},
      {"remove_flags", @list},
      {"tags", Map.put(@list, :description, "Replaces the card's tags: names on the board.")},
      {"add_tags",
       Map.put(
         @list,
         :description,
         "Tag names already on the board (get_board lists them; create_tag adds one)."
       )},
      {"remove_tags", Map.put(@list, :description, "Tag names on the board.")},
      {"assignee", %{type: "string", description: "Who is on it alone: email or \"me\"."}},
      {"assignees",
       Map.put(@list, :description, "Replaces who is on it; [] unassigns. \"me\" for yourself.")},
      {"add_assignees", @list},
      {"remove_assignees", @list},
      {"column",
       %{type: "string", description: "Moves it to the bottom of this list (name or id)."}},
      {"fields",
       %{type: "object", description: "Custom fields: key, name or id => value; \"\" clears."}},
      {"evidence",
       %{
         type: "string",
         description: "What you checked (tests run, output); a board may require it."
       }},
      {"evidence_commit", %{type: "string", description: "The commit the evidence is for."}},
      {"evidence_branch", %{type: "string", description: "The commit's branch."}},
      {"evidence_tests",
       %{type: "array", items: %{type: "string"}, description: "The test files added or changed."}},
      {"evidence_suite", @suite},
      {"evidence_pr",
       %{
         type: "string",
         description:
           "The pull request's URL, on a board that ships by pull request. Give the " <>
             "evidence's commit with it, the PR's head: the PR is merged at that commit, and " <>
             "a PR without one is refused, on a resubmission too."
       }},
      {"evidence_no_code",
       %{
         type: "string",
         description:
           "Why the card changes no code (a sweep, a handbook reconcile, a read-and-file " <>
             "card): on a board that ships by pull request, given in place of the pull " <>
             "request, and accepting it merges nothing."
       }},
      {"changed_lines",
       %{
         type: "integer",
         minimum: 0,
         description:
           "The change's changed lines, added plus removed (`git diff --numstat`). With " <>
             "profiles on, a fix or docs card over 400 is raised to feature."
       }},
      {"changed_files",
       %{
         type: "array",
         items: %{type: "string"},
         description:
           "The files the change touches. With profiles on, a migration raises the card's " <>
             "profile to schema and a security path to security; never lowered."
       }}
    ]
  end

  defp border, do: Map.put(@border, :enum, ["" | Slipdock.Palette.names()])

  @impl true
  def definition do
    %{
      name: "edit_card",
      title: "Change a card",
      summary:
        "Changes a card's fields: only what you send changes, and null clears one. " <>
          "completed with the evidence fields completes it.",
      verb: :patch,
      path: "/api/cards/:id",
      permission: {:card, :write},
      writes?: true,
      # As sent: `CardWrites.fetch_card/1` reads it, so one that isn't a
      # number is a card not there (404), as the route has always said.
      params:
        [
          %{
            name: "card",
            type: :any,
            schema: %{type: "integer"},
            required: true,
            in_path: "id"
          }
        ] ++
          for({name, schema} <- body(), do: param(name, schema)),
      cli: %{
        command: "edit",
        positional: ["card"],
        flags: %{
          "title" => %{param: "title"},
          "short_name" => %{param: "short_name"},
          # `--desc -`, `--bar -`: read from stdin by the CLI.
          "desc" => %{param: "description", read: :stdin},
          "bar" => %{param: "bar", read: :stdin},
          "priority" => %{param: "priority"},
          "start" => %{param: "start_date"},
          "no_start" => %{param: "start_date", read: :parsed},
          "due" => %{param: "due_date"},
          "no_due" => %{param: "due_date", read: :parsed},
          "percent" => %{param: "percent_complete"},
          "no_percent" => %{param: "percent_complete", read: :parsed},
          "paths" => %{param: "paths"},
          "profile" => %{param: "profile"},
          "no_profile" => %{param: "profile", read: :parsed},
          "caused_by" => %{param: "caused_by"},
          "no_caused_by" => %{param: "caused_by", read: :parsed},
          "missed_by" => %{param: "missed_by"},
          "no_missed_by" => %{param: "missed_by", read: :parsed},
          "spent" => %{param: "time_spent"},
          "no_spent" => %{param: "time_spent", read: :parsed},
          "estimate" => %{param: "time_estimate"},
          "no_estimate" => %{param: "time_estimate", read: :parsed},
          "unit" => %{param: "time_unit"},
          "log" => %{param: "log_time"},
          "color" => %{param: "color"},
          "no_color" => %{param: "color", read: :parsed},
          "column" => %{param: "column"},
          # Repeatable: one is `assignee`, several `assignees`.
          "assignee" => %{param: "assignees", read: :parsed},
          "no_assignee" => %{param: "assignee", read: :parsed},
          "add_assignee" => %{param: "add_assignees", read: :parsed},
          "remove_assignee" => %{param: "remove_assignees", read: :parsed},
          # Every edge, then one edge over it; `none` is "".
          "border" => %{param: "border_top", read: :parsed},
          "no_border" => %{param: "border_top", read: :parsed},
          "border_top" => %{param: "border_top", read: :parsed},
          "border_right" => %{param: "border_right", read: :parsed},
          "border_bottom" => %{param: "border_bottom", read: :parsed},
          "border_left" => %{param: "border_left", read: :parsed},
          # `done`'s: the evidence, `-` reading it from stdin.
          "evidence" => %{param: "evidence", read: :stdin},
          "evidence_commit" => %{param: "evidence_commit"},
          "branch" => %{param: "evidence_branch"},
          "tests" => %{param: "evidence_tests", read: :parsed},
          "suite" => %{param: "evidence_suite", read: :parsed},
          "pr" => %{param: "evidence_pr"},
          "no_code" => %{param: "evidence_no_code", read: :stdin},
          # The change, counted from git (`--diff-base REF`) or given.
          "diff_base" => %{param: "changed_lines", read: :parsed},
          "changed_lines" => %{param: "changed_lines"},
          "changed_files" => %{param: "changed_files", read: :parsed}
        }
      }
    }
  end

  defp param(name, schema), do: %{name: name, type: :any, schema: schema, null: true}

  @impl true
  def run(%{"card" => id} = params, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         :ok <- Authorize.card(auth, card, :write),
         {:ok, card} <- CardWrites.update(auth, card, Map.delete(params, "card")) do
      {:ok, %{card: card_json(auth, card)}}
    end
  end
end
