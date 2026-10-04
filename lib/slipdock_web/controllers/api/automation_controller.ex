defmodule SlipdockWeb.API.AutomationController do
  @moduledoc """
  Automation rules over HTTP, for the CLI and for agents.

  A rule can be created two ways. `spec` is the exact one — the trigger,
  conditions and actions written out, validated against
  `Slipdock.Automations.Spec` and stored as given, with no model involved;
  this is what a program should use. `text` is the friendly one — a
  sentence the server's model turns into a spec, the same path the web UI
  takes, and it needs an OpenRouter key.

  `preset` is the third: one of the ready-made rules from
  `GET /api/automations/presets`, filled in with `params` — again no model.

  `GET /api/automations/vocabulary` is the whole grammar as data, so a
  caller can build a spec without guessing.
  """
  use SlipdockWeb, :controller

  alias Slipdock.{Automations, Boards}
  alias Slipdock.Automations.{Presets, Spec}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  # Rules act on everyone's cards, so only the board's owner may touch them.
  defp fetch_board(conn, ref, need), do: Authorize.fetch_board(conn, ref, need)

  defp fetch_rule(conn, board_ref, rule_ref) do
    with {:ok, board} <- fetch_board(conn, board_ref, :owner),
         {:ok, rule} <- find(Automations.find_rule(board, rule_ref), "automation") do
      {:ok, board, rule}
    end
  end

  def vocabulary(conn, _params) do
    json(conn, %{
      vocabulary: Spec.vocabulary(),
      example: %{
        name: "Tell ops about finished work",
        scope: "board",
        spec: %{
          trigger: %{type: "card_moved", to: "Done"},
          conditions: [%{field: "priority", op: "any_of", value: ["high", "critical"]}],
          actions: [
            %{
              type: "email",
              to: "ops@example.com",
              subject: "Done: {{card.title}}",
              body: "{{card.url}}"
            }
          ]
        }
      }
    })
  end

  def presets(conn, _params) do
    json(conn, %{presets: Presets.all()})
  end

  def index(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :owner) do
      json(conn, %{automations: Enum.map(Automations.list_rules(board.id), &V.automation/1)})
    end
  end

  def show(conn, %{"board" => ref, "id" => id}) do
    with {:ok, _board, rule} <- fetch_rule(conn, ref, id) do
      json(conn, %{automation: V.automation(rule)})
    end
  end

  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :owner),
         {:ok, rule} <- build(board, params, conn.assigns.current_user) do
      conn |> put_status(:created) |> json(%{automation: V.automation(rule)})
    end
  end

  def update(conn, %{"board" => ref, "id" => id} = params) do
    with {:ok, _board, rule} <- fetch_rule(conn, ref, id),
         {:ok, rule} <- change(rule, params, conn.assigns.current_user) do
      json(conn, %{automation: V.automation(rule)})
    end
  end

  def delete(conn, %{"board" => ref, "id" => id}) do
    with {:ok, _board, rule} <- fetch_rule(conn, ref, id),
         {:ok, _} <- Automations.delete_rule(rule) do
      json(conn, %{ok: true})
    end
  end

  @doc """
  Runs a rule now. A timed rule first forgets what it has already acted on,
  so it can act on the same cards again; the reply says how often it fired
  and what the rule made of it.
  """
  def run(conn, %{"board" => ref, "id" => id}) do
    with {:ok, _board, rule} <- fetch_rule(conn, ref, id) do
      fired = Automations.run_rule_now(rule)
      json(conn, %{fired: fired, automation: V.automation(Automations.get_rule!(rule.id))})
    end
  end

  @doc """
  The callbacks the board's rules have made, newest first: where each went,
  the HTTP status or error that came back, and when. `limit` (default 50,
  at most 200) says how many.
  """
  def callbacks(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :owner) do
      calls = Automations.list_callbacks(board.id, params["limit"])
      json(conn, %{callbacks: Enum.map(calls, &V.callback/1)})
    end
  end

  ## Alerts -------------------------------------------------------------------

  def alerts(conn, _params) do
    json(conn, %{alerts: Enum.map(Automations.list_alerts(conn.assigns.current_user), &V.alert/1)})
  end

  def dismiss(conn, %{"id" => id}) do
    Automations.dismiss_alert(conn.assigns.current_user, id)
    json(conn, %{ok: true})
  end

  def dismiss_all(conn, _params) do
    user = conn.assigns.current_user
    dismissed = length(Automations.list_alerts(user))
    Automations.dismiss_all_alerts(user)
    json(conn, %{ok: true, dismissed: dismissed})
  end

  ## Building rules -----------------------------------------------------------

  defp build(board, %{"spec" => spec} = params, user) when is_map(spec) do
    attrs = %{
      "name" => params["name"] || derived_name(board, spec),
      "source" => params["text"],
      "spec" => spec,
      "scope" => params["scope"] || "board",
      "board_id" => board.id
    }

    Automations.create_rule(attrs, created_by: user)
  end

  defp build(board, %{"preset" => key} = params, user) when is_binary(key) do
    params_in = if is_map(params["params"]), do: params["params"], else: %{}

    case Automations.create_rule_from_preset(board, key, params_in, created_by: user) do
      {:ok, rule} ->
        if is_binary(params["name"]),
          do: Automations.update_rule(rule, %{"name" => params["name"]}),
          else: {:ok, rule}

      {:error, message} ->
        {:error, :unprocessable_entity, message}
    end
  end

  defp build(board, %{"text" => text}, user) when is_binary(text) do
    case Automations.create_rule_from_text(Boards.get_board!(board.id), text, created_by: user) do
      {:ok, rule} -> {:ok, rule}
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      other -> other
    end
  end

  defp build(_board, _params, _user) do
    {:error, :bad_request,
     "pass `spec` (a trigger/conditions/actions object — see GET /api/automations/vocabulary), " <>
       "`preset` with `params` (a ready-made rule — see GET /api/automations/presets) " <>
       "or `text` (a sentence for the model to turn into one)"}
  end

  defp change(rule, params, user) do
    cond do
      is_map(params["spec"]) or is_binary(params["name"]) or is_binary(params["scope"]) ->
        attrs =
          %{}
          |> put_present("spec", params["spec"])
          |> put_present("name", params["name"])
          |> put_present("scope", params["scope"])
          |> put_present("enabled", params["enabled"])

        Automations.update_rule(rule, attrs)

      is_binary(params["text"]) ->
        case Automations.rewrite_rule(rule, params["text"], created_by: user) do
          {:ok, rule} -> {:ok, rule}
          {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
          other -> other
        end

      is_boolean(params["enabled"]) ->
        Automations.update_rule(rule, %{"enabled" => params["enabled"]})

      true ->
        {:error, :bad_request, "nothing to change: pass enabled, name, scope, spec or text"}
    end
  end

  # A spec given without a name is named after what it does.
  defp derived_name(board, spec) do
    case Spec.validate(spec) do
      {:ok, validated} -> validated |> Spec.summary() |> String.slice(0, 120)
      # An invalid spec is refused by the changeset, with the real reason.
      {:error, _} -> "Rule on #{board.name}"
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp find({:ok, x}, _), do: {:ok, x}
  defp find({:error, :not_found}, what), do: {:error, :not_found, what}
end
