defmodule SlipdockWeb.API.AutomationWrites do
  @moduledoc """
  Making and changing a board's automation rules on somebody's behalf,
  shared by the HTTP API (`SlipdockWeb.API.AutomationController`) and the
  MCP tools (`manage_automation`), so a rule written either way is built
  the same way.

  `params` are string-keyed, as the API takes them. Failures are a changeset
  or the API's `{:error, status, message}` shapes.
  """
  alias Slipdock.{Automations, Boards}
  alias Slipdock.Automations.Spec

  @doc """
  A new rule on `board` from one of `spec` (exact, no model), `preset` with
  `params` (a ready-made rule, no model) or `text` (a sentence the model
  turns into a spec). `name` and `scope` are optional.
  """
  def build(board, %{"spec" => spec} = params, user) when is_map(spec) do
    attrs = %{
      "name" => params["name"] || derived_name(board, spec),
      "source" => params["text"],
      "spec" => spec,
      "scope" => params["scope"] || "board",
      "board_id" => board.id
    }

    Automations.create_rule(attrs, created_by: user)
  end

  def build(board, %{"preset" => key} = params, user) when is_binary(key) do
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

  def build(board, %{"text" => text}, user) when is_binary(text) do
    case Automations.create_rule_from_text(Boards.get_board!(board.id), text, created_by: user) do
      {:ok, rule} -> {:ok, rule}
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      other -> other
    end
  end

  def build(_board, _params, _user) do
    {:error, :bad_request,
     "pass `spec` (a trigger/conditions/actions object — see GET /api/automations/vocabulary), " <>
       "`preset` with `params` (a ready-made rule — see GET /api/automations/presets) " <>
       "or `text` (a sentence for the model to turn into one)"}
  end

  @doc """
  Changes `rule`: any of `spec`, `name`, `scope` and `enabled` as given, or
  `text` for the model to rewrite it from, or `enabled` alone.
  """
  def change(rule, params, user) do
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
end
