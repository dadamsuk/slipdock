defmodule SlipdockWeb.MCP.Tools.UpdateCard do
  @moduledoc """
  Changes a card's fields, flags, tags and assignees, what blocks it, and its
  checklist. All of it lands or none of it does.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.{Boards, Repo}
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}

  @fields ~w(title description priority due_date start_date percent_complete)
  @lists ~w(add_flags remove_flags add_tags remove_tags assignees add_assignees remove_assignees)
  @id_lists ~w(add_blocked_by remove_blocked_by check_items uncheck_items)

  @impl true
  def name, do: "update_card"

  @impl true
  def title, do: "Update a card"

  @impl true
  def description,
    do:
      "Changes a card: title, description, priority, dates, percent_complete, flags " <>
        "(blocked, waiting, review), tags, assignees, the cards blocking it and its " <>
        "checklist (item ids from get_card). Only what you pass changes."

  @impl true
  def input_schema do
    list = %{type: "array", items: %{type: "string"}}
    ids = %{type: "array", items: %{type: "integer"}}

    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        title: %{type: "string"},
        description: %{type: "string", description: "Replaces the whole description."},
        priority: %{type: "string", enum: ["none", "low", "medium", "high", "critical"]},
        due_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        start_date: %{type: "string", description: "YYYY-MM-DD; \"\" clears it."},
        percent_complete: %{type: "integer", minimum: 0, maximum: 100},
        add_flags: list,
        remove_flags: list,
        add_tags: list,
        remove_tags: list,
        assignees:
          Map.put(list, :description, "Replaces who is on it; [] unassigns. \"me\" for yourself."),
        add_assignees: list,
        remove_assignees: list,
        add_blocked_by: Map.put(ids, :description, "Cards that must finish before this one."),
        remove_blocked_by: ids,
        add_checklist: Map.put(list, :description, "New checklist items, in order."),
        check_items: Map.put(ids, :description, "Checklist item ids to tick."),
        uncheck_items: ids
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
         {:ok, blockers} <- blockers(auth, params["add_blocked_by"]),
         {:ok, unblockers} <- cards(params["remove_blocked_by"]),
         {:ok, to_check} <- items(card, params["check_items"]),
         {:ok, to_uncheck} <- items(card, params["uncheck_items"]),
         {:ok, card} <-
           write(auth, card, params, blockers, unblockers, to_check, to_uncheck) do
      {:ok, Tools.card_written(card, context.base_url)}
    end
  end

  # Everything is checked before anything is written; what can still fail
  # (a dependency that would make a loop, say) rolls the rest back with it.
  defp write(auth, card, params, blockers, unblockers, to_check, to_uncheck) do
    Repo.transaction(fn ->
      with {:ok, card} <-
             update_fields(auth, card, Map.drop(params, @id_lists ++ ["add_checklist"])),
           :ok <- each(blockers, &add_blocker(card, &1)),
           :ok <- each(unblockers, &Boards.remove_dependency(card, &1)),
           :ok <- each(params["add_checklist"] || [], &Boards.add_checklist_item(card, &1)),
           :ok <- each(Enum.reject(to_check, & &1.done), &Boards.toggle_checklist_item/1),
           :ok <- each(Enum.filter(to_uncheck, & &1.done), &Boards.toggle_checklist_item/1) do
        Boards.get_card!(card.id)
      else
        error -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, card} -> {:ok, card}
      {:error, error} -> Args.refusal(error)
    end
  end

  defp update_fields(_auth, card, params) when map_size(params) == 0, do: {:ok, card}
  defp update_fields(auth, card, params), do: CardWrites.update(auth, card, params)

  # Already blocked by it is what was asked for, not a mistake.
  defp add_blocker(card, blocker) do
    if Enum.any?(card.blocked_by, &(&1.id == blocker.id)),
      do: {:ok, card},
      else: Boards.add_dependency(card, blocker)
  end

  defp each(things, fun) do
    Enum.reduce_while(things, :ok, fn thing, :ok ->
      case fun.(thing) do
        {:error, message} when is_binary(message) -> {:halt, {:error, message}}
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, :ok}
      end
    end)
  end

  # A blocker may sit on another board; reading it is enough, as over the API.
  defp blockers(auth, ids) do
    with {:ok, cards} <- cards(ids) do
      Enum.reduce_while(cards, {:ok, cards}, fn card, acc ->
        case Authorize.card(auth, card, :read) do
          :ok -> {:cont, acc}
          refused -> {:halt, Args.refusal(refused)}
        end
      end)
    end
  end

  defp cards(nil), do: {:ok, []}

  defp cards(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case CardWrites.fetch_card(id) do
        {:ok, card} -> {:cont, {:ok, acc ++ [card]}}
        _ -> {:halt, {:error, "no card ##{id} you can see"}}
      end
    end)
  end

  defp items(_card, nil), do: {:ok, []}

  defp items(card, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Enum.find(card.checklist_items, &(&1.id == id)) do
        nil -> {:halt, {:error, "checklist item #{id} is not on card ##{card.id}"}}
        item -> {:cont, {:ok, acc ++ [item]}}
      end
    end)
  end

  defp params(args) do
    with {:ok, params} <- collect(@lists, &Args.strings/2, args, Map.take(args, @fields)),
         {:ok, params} <- collect(~w(add_checklist), &Args.strings/2, args, params),
         {:ok, params} <- collect(@id_lists, &Args.ids/2, args, params) do
      if map_size(params) == 0,
        do: {:error, "nothing to change: pass at least one field"},
        else: {:ok, params}
    end
  end

  defp collect(keys, read, args, params) do
    Enum.reduce_while(keys, {:ok, params}, fn key, {:ok, acc} ->
      case read.(args, key) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end
end
