defmodule SlipdockWeb.MCP.Tools.UpdateCard do
  @moduledoc "Changes a card's fields, flags, tags and assignees."
  @behaviour SlipdockWeb.MCP.Tool

  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}

  @fields ~w(title description priority due_date start_date percent_complete)
  @lists ~w(add_flags remove_flags add_tags remove_tags assignees add_assignees remove_assignees)

  @impl true
  def name, do: "update_card"

  @impl true
  def title, do: "Update a card"

  @impl true
  def description,
    do:
      "Changes a card: title, description, priority, dates, percent_complete, flags " <>
        "(blocked, waiting, review), tags and assignees. Only what you pass changes."

  @impl true
  def input_schema do
    list = %{type: "array", items: %{type: "string"}}

    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        title: %{type: "string"},
        description: %{type: "string", description: "Replaces the whole description."},
        priority: %{type: "string", enum: ["low", "medium", "high", "critical"]},
        due_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        start_date: %{type: "string"},
        percent_complete: %{type: "integer", minimum: 0, maximum: 100},
        add_flags: list,
        remove_flags: list,
        add_tags: list,
        remove_tags: list,
        assignees:
          Map.put(list, :description, "Replaces who is on it; [] unassigns. \"me\" for yourself."),
        add_assignees: list,
        remove_assignees: list
      },
      required: ["card"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, params} <- params(args),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         {:ok, card} <- Args.refusal(CardWrites.update(auth, card, params)) do
      {:ok, Tools.card_written(card, context.base_url)}
    end
  end

  defp params(args) do
    Enum.reduce_while(@lists, {:ok, Map.take(args, @fields)}, fn key, {:ok, acc} ->
      case Args.strings(args, key) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, list} -> {:cont, {:ok, Map.put(acc, key, list)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, params} when map_size(params) == 0 ->
        {:error, "nothing to change: pass at least one field"}

      other ->
        other
    end
  end
end
