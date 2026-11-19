defmodule SlipdockWeb.Ops.SetBoard do
  @moduledoc """
  Changing a board's settings, `PATCH /api/boards/:board`, defined once
  (#3361): the REST action and the CLI's `set-board`. Only the board's owner
  may. The MCP tool `update_board` also sets the overseer and the caller's
  own Waiting on you, and answers the board's summary with its tiers, so it
  stays hand-composed (SPEC-4), and takes each param it shares with this
  from here (`SlipdockWeb.Ops.params_from/2`).

  Every body param is `:any`, passed on as sent, and `null: true`: what the
  route has always taken.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  @hours %{type: "integer", description: "Hours."}

  @doc "The body params, `{name, schema}`: every setting the route takes."
  def body do
    [
      {"name", %{type: "string"}},
      {"code", %{type: "string", description: "Short slug the board goes by in links and ids."}},
      {"shortcut", %{type: "string", description: "A key to open it with in the web app."}},
      {"description", %{type: "string"}},
      {"color", %{type: "string", description: "A palette colour."}},
      {"simple", %{type: "boolean", description: "A plain to-do list."}},
      {"kind", %{type: "string", description: "sprints, or \"\" for none."}},
      {"default_view",
       %{type: "string", description: "What opening the board shows: board, wiki…"}},
      {"add_card", %{type: "boolean", description: "Every list's foot offers Add a card."}},
      {"add_page", %{type: "boolean", description: "Every list's foot offers Add a page."}},
      {"add_document",
       %{type: "boolean", description: "Every list's foot offers Add a document."}},
      {"page_card_features",
       %{type: "boolean", description: "The card contents under every wiki page."}},
      {"show_pulse", %{type: "boolean", description: "The pulse strip over the lists."}},
      {"close_on_complete",
       %{type: "boolean", description: "Completing an open card closes it to the board."}},
      {"vote_budget", %{type: "integer", description: "Votes each person has on the board."}},
      {"vote_max", %{type: "integer", description: "Most votes one person may put on a card."}},
      {"automation_wip",
       %{type: "boolean", description: "WIP limits hold runner jobs and list_top sends."}},
      {"agentic_building",
       %{
         type: "boolean",
         description:
           "Show the Agentic Building item and page in the web app. Off changes no setting."
       }},
      {"delivery_metrics", %{type: "boolean", description: "Deploys and DORA metrics."}},
      {"incident_tag",
       %{type: "string", description: "The tag that files a card as an incident."}},
      {"hotfix_window_hours",
       Map.put(@hours, :description, "A fix shipped within this many hours is a hotfix.")},
      {"not_shipped_minutes",
       %{
         type: "integer",
         description: "Minutes a merged card may wait to ship before it is said."
       }},
      {"card_ref_pattern",
       %{type: "string", description: "A regex for card ids in commit messages."}},
      {"handoff_label",
       %{type: "string", description: "What a handoff is called; \"\" default."}},
      {"handoff_prompt",
       %{type: "string", description: "The AI's instructions for drafting a handoff."}},
      {"inbound_senders",
       %{
         type: "string",
         description: "Who else may mail the board's card addresses, comma-separated; \"\" none."
       }},
      {"bar_required", %{type: "boolean", description: "Agents write a card's bar before work."}},
      {"evidence_required", %{type: "boolean", description: "Agents give evidence to complete."}},
      {"verify_work", %{type: "boolean", description: "A second agent accepts or rejects."}},
      {"verify_pool", %{type: "string", description: "Runner pool for verify jobs; \"\" none."}},
      {"verify_rejection_limit",
       %{type: "integer", description: "Rejections before the next goes to a person; 0 never."}},
      {"verify_audit",
       %{type: "integer", description: "Audit 1 in this many cards an agent accepted; 0 none."}},
      {"ship_via",
       %{
         type: "string",
         enum: ["push", "pull_request"],
         description: "How verified work ships: push, or pull_request (needs verify_work)."
       }},
      {"release_mode",
       %{
         type: "string",
         enum: Slipdock.Boards.Board.release_modes(),
         description:
           "How merged work reaches production: on_merge (each merge deploys) or batched " <>
             "(merges wait for a release). Root board only."
       }},
      {"release_age_cap_hours",
       %{
         type: ["integer", "null"],
         description:
           "Batched: release once the oldest waiting merge has waited this many hours; " <>
             "null off. Root board only."
       }},
      {"release_command",
       %{
         type: ["string", "null"],
         description:
           "Batched: the one-line command a runner's release job runs; null for the " <>
             "default (gh workflow run release.yml). Any other command runs only on a " <>
             "machine whose local.json lists it under release_commands. Root board only."
       }},
      {"profiles",
       %{
         type: "boolean",
         description:
           "Give a card an agent claims or starts a profile (docs, fix, feature, schema, " <>
             "security, spike) when it has none."
       }},
      {"profile_tiers",
       %{
         type: "object",
         description:
           "Each profile's human tier on the tree (root board only): none or ledger (acceptance " <>
             "merges), before_merge (a person decides first); default puts one back. Defaults: " <>
             "docs/fix/spike none, feature ledger, schema/security before_merge.",
         properties:
           Map.new(Slipdock.Profiles.names(), fn p ->
             {p, %{type: "string", enum: Slipdock.Profiles.tiers() ++ ["default"]}}
           end),
         additionalProperties: false
       }},
      {"job_log_hours",
       %{type: "integer", description: "Hours a finished runner job's log stays (24 by default)."}},
      {"failure_log_hours",
       %{
         type: "integer",
         description: "Hours a failed, stuck or rejected job's log stays (168 by default)."
       }},
      {"findings_propose_at",
       %{
         type: "integer",
         description:
           "A finding seen this many times gets a handbook rule proposal drafted (3 by default; 0 off)."
       }},
      {"wait_default_after",
       %{
         type: ["string", "integer", "null"],
         description:
           "How long an approval wait (kind other, with choices and a default) goes " <>
             "unanswered before its proposal stands: 4h, 90m, 2d or minutes; off or null " <>
             "turns it off (the default). Never for product, ux, security or release waits."
       }},
      {"wait_routes",
       %{
         type: "object",
         description:
           "Who each kind of question goes to: kind => emails of the board's users, the first " <>
             "is who it waits on, the rest are told; [] takes a kind's route off.",
         properties:
           Map.new(Slipdock.WaitRoutes.kinds(), fn kind ->
             {kind, %{type: "array", items: %{type: "string"}}}
           end),
         additionalProperties: false
       }}
    ]
  end

  # Set by their own code, not the board's changeset.
  @own ~w(wait_routes)

  @impl true
  def definition do
    %{
      name: "set_board",
      title: "Change a board's settings",
      summary: "Changes a board you own: only what you send changes.",
      verb: :patch,
      path: "/api/boards/:board",
      permission: {:board, :owner},
      writes?: true,
      params:
        [
          %{
            name: "board",
            type: :string,
            required: true,
            in_path: "board",
            doc: "Board id, code or name."
          }
        ] ++
          for({name, schema} <- body(), do: %{name: name, type: :any, schema: schema, null: true}),
      cli: %{
        command: "set-board",
        positional: ["board"],
        flags: %{
          "name" => %{param: "name"},
          "code" => %{param: "code"},
          "shortcut" => %{param: "shortcut"},
          "desc" => %{param: "description", read: :stdin},
          "color" => %{param: "color"},
          "add_card" => %{param: "add_card"},
          "add_page" => %{param: "add_page"},
          "add_document" => %{param: "add_document"},
          "page_card_features" => %{param: "page_card_features"},
          "simple" => %{param: "simple"},
          "show_pulse" => %{param: "show_pulse"},
          "close_on_complete" => %{param: "close_on_complete"},
          "automation_wip" => %{param: "automation_wip"},
          # on|off, worked out by the CLI.
          "agentic_building" => %{param: "agentic_building", read: :parsed},
          "profiles" => %{param: "profiles", read: :parsed},
          "job_log_hours" => %{param: "job_log_hours"},
          "failure_log_hours" => %{param: "failure_log_hours"},
          "bar_required" => %{param: "bar_required"},
          "evidence_required" => %{param: "evidence_required"},
          "verify_work" => %{param: "verify_work"},
          "verify_pool" => %{param: "verify_pool"},
          "verify_rejection_limit" => %{param: "verify_rejection_limit"},
          "verify_audit" => %{param: "verify_audit"},
          "findings_propose_at" => %{param: "findings_propose_at"},
          "wait_default_after" => %{param: "wait_default_after"},
          # pull-request is pull_request, on-merge on_merge; off and default "".
          "ship_via" => %{param: "ship_via", read: :parsed},
          "release_mode" => %{param: "release_mode", read: :parsed},
          "release_age_cap" => %{param: "release_age_cap_hours", read: :parsed},
          "release_command" => %{param: "release_command", read: :parsed},
          "delivery_metrics" => %{param: "delivery_metrics"},
          "incident_tag" => %{param: "incident_tag"},
          "hotfix_hours" => %{param: "hotfix_window_hours"},
          "not_shipped_minutes" => %{param: "not_shipped_minutes"},
          "card_ref_pattern" => %{param: "card_ref_pattern"},
          "default_view" => %{param: "default_view"},
          "handoff_label" => %{param: "handoff_label"},
          "handoff_prompt" => %{param: "handoff_prompt", read: :parsed},
          "handoff_prompt_file" => %{param: "handoff_prompt", read: :file},
          "inbound_senders" => %{param: "inbound_senders"},
          # Repeatable: KIND=EMAIL[,EMAIL], and --no-route KIND.
          "route" => %{param: "wait_routes", read: :parsed},
          "no_route" => %{param: "wait_routes", read: :parsed},
          "profile_tier" => %{param: "profile_tiers", read: :parsed},
          "sprints" => %{param: "kind", read: :parsed}
        }
      }
    }
  end

  @impl true
  def run(%{"board" => ref} = params, auth) do
    params = Map.delete(params, "board")

    with {:ok, board} <- Authorize.fetch_board(auth, ref, :owner),
         board = Boards.with_owner(board),
         {:ok, params} <- profile_tiers(board, params),
         {:ok, board} <- wait_routes(board, params),
         {:ok, board} <- Boards.update_board(board, Map.drop(params, @own)) do
      {:ok,
       agentic_warning(
         %{board: V.board_summary(board, auth.assigns.current_user)},
         board,
         params
       )}
    end
  end

  # Agentic Building turned off with rules still set (#2011): they hold on,
  # so the answer says which.
  defp agentic_warning(body, board, %{"agentic_building" => off}) when off in [false, "false"] do
    case V.agentic_warning(board) do
      nil -> body
      warning -> Map.put(body, :warnings, [warning])
    end
  end

  defp agentic_warning(body, _board, _params), do: body

  # `wait_routes` (#1949): `{kind: [email, ...]}`, a blank or empty list
  # taking a kind's route off. Refused whole if any of it is wrong.
  defp wait_routes(board, %{"wait_routes" => routes}) do
    case Slipdock.WaitRoutes.set(board, routes) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  defp wait_routes(board, _params), do: {:ok, board}

  # `profile_tiers` (#1952): `{profile: tier}` merged onto the root's, a
  # blank or `default` putting one back.
  defp profile_tiers(board, params) do
    case Slipdock.Profiles.put_tiers(board, params) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end
end
