defmodule SlipdockWeb.MCP.Tools.CardViews do
  @moduledoc """
  The caller's own card views (#2031, see `Slipdock.CardViews`): which
  elements of a card they see, by global, board and list. One tool with an
  `action`, because each tool costs every session context.

  Card views are a display preference of the token's owner. They never change
  what this or any other tool returns: an agent reading a card gets all of it
  whatever its owner has chosen to see.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.CardViews
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.Args

  @reads ~w(list get level applied)
  @writes ~w(create update delete set_level clear_level)
  @actions @reads ++ @writes

  @impl true
  def name, do: "card_views"

  @impl true
  def title, do: "Your card views"

  @impl true
  def description,
    do:
      "Your own card views: which card elements you see, global, per board, per list. " <>
        "list/get/create/update/delete named views; level, set_level, clear_level; applied " <>
        "explains each element. Display only: never changes what tools return."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        view: %{
          type: "string",
          description: "get, update, delete: one of your named card views, by id or name."
        },
        name: %{type: "string", description: "create: its name; update: a new name."},
        elements: %{
          type: "object",
          description:
            "Element key to true (show), false (hide) or null (inherit). Keys are in list's " <>
              "elements: tags, due_date, open.description, side.time and so on."
        },
        show: %{type: "array", items: %{type: "string"}, description: "Elements to show."},
        hide: %{type: "array", items: %{type: "string"}, description: "Elements to hide."},
        inherit: %{
          type: "array",
          items: %{type: "string"},
          description: "update, set_level: elements to stop stating, so they inherit."
        },
        reset: %{
          type: "boolean",
          description: "update, set_level: start from stating nothing before the changes."
        },
        board: %{
          type: "string",
          description:
            "level, set_level, clear_level, applied: board id, code or name. None: global."
        },
        list: %{
          type: "string",
          description: "With board: a list on it (id or name), for that list's level."
        },
        apply: %{
          type: ["string", "null"],
          description: "set_level: a named card view to apply there (id or name); null for none."
        },
        show_all: %{
          type: "boolean",
          description: "set_level on a board (no list): show every element of the card front."
        },
        saved_view: %{
          type: "string",
          description:
            "applied: a saved view on the board (id or name); its card view goes on top."
        }
      },
      required: ["action"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def writes?(args), do: Enum.member?(@writes, args["action"])

  @impl true
  def destructive?, do: true

  @impl true
  def call(args, %{user: user} = context) do
    with {:ok, action} <- Args.required(args, "action") do
      if Enum.member?(@actions, action),
        do: act(action, args, user, context),
        else: {:error, "action must be one of #{Enum.join(@actions, ", ")}"}
    end
  end

  defp act("list", _args, user, _context) do
    {:ok, %{card_views: Enum.map(CardViews.list(user), &view_json/1), elements: catalogue()}}
  end

  defp act("get", args, user, _context) do
    with {:ok, view} <- fetch_view(args, user), do: {:ok, %{card_view: view_json(view)}}
  end

  defp act("create", args, user, _context) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, attrs} <- changes(args),
         {:ok, view} <- user |> CardViews.create(Map.put(attrs, "name", name)) |> result(),
         do: {:ok, %{card_view: view_json(view)}}
  end

  defp act("update", args, user, _context) do
    with {:ok, view} <- fetch_view(args, user),
         {:ok, name} <- Args.optional(args, "name"),
         {:ok, attrs} <- changes(args),
         attrs = if(name, do: Map.put(attrs, "name", name), else: attrs),
         {:ok, view} <- user |> CardViews.update(view, attrs) |> result(),
         do: {:ok, %{card_view: view_json(view)}}
  end

  defp act("delete", args, user, _context) do
    with {:ok, view} <- fetch_view(args, user),
         used = CardViews.levels_using(user, view),
         {:ok, _} <- user |> CardViews.delete(view) |> result(),
         do: {:ok, %{deleted: view_json(view), levels_now_inheriting: used}}
  end

  defp act("level", args, user, context) do
    with {:ok, scope} <- scope(args, user, context),
         do: {:ok, %{level: level_json(scope, CardViews.level(user, scope))}}
  end

  defp act("set_level", args, user, context) do
    with {:ok, scope} <- scope(args, user, context),
         {:ok, attrs} <- level_changes(args),
         {:ok, level} <- user |> CardViews.update_level(scope, attrs) |> result(),
         do: {:ok, %{level: level_json(scope, level)}}
  end

  defp act("clear_level", args, user, context) do
    with {:ok, scope} <- scope(args, user, context),
         {:ok, _} <- CardViews.clear_level(user, scope),
         do: {:ok, %{level: level_json(scope, CardViews.level(user, scope))}}
  end

  defp act("applied", args, user, context) do
    with {:ok, scope} <- scope(args, user, context),
         {:ok, saved_ref} <- Args.optional(args, "saved_view"),
         do: applied(user, place(scope), saved_ref)
  end

  defp applied(_user, {nil, nil}, saved_ref) when is_binary(saved_ref),
    do: {:error, "saved_view needs a board: a saved view is on one"}

  defp applied(user, {nil, nil}, nil),
    do: {:ok, %{board: nil, list: nil, show_all: false, elements: CardViews.explain(user, nil)}}

  defp applied(user, {board, column}, saved_ref) do
    with {:ok, name} <- saved_view_card_view(board, saved_ref) do
      {:ok,
       %{
         board: board_json(board),
         list: column && %{id: column.id, name: column.name},
         saved_view_card_view: name,
         show_all: CardViews.level(user, {:board, board}).show_all,
         elements: CardViews.explain(user, board, column, card_view: name)
       }}
    end
  end

  ## Arguments

  defp fetch_view(args, user) do
    with {:ok, ref} <- Args.required(args, "view") do
      case CardViews.get(user, ref) do
        {:ok, view} -> {:ok, view}
        {:error, :not_found} -> {:error, "no card view of yours is called or numbered #{ref}"}
      end
    end
  end

  # The element changes, as `Slipdock.CardViews.changes/2` takes them; it
  # names any key that is not an element.
  defp changes(args) do
    with {:ok, reset} <- Args.boolean(args, "reset", false) do
      attrs = Map.take(args, ~w(elements show hide inherit))
      {:ok, if(reset, do: Map.put(attrs, "reset", true), else: attrs)}
    end
  end

  defp level_changes(args) do
    with {:ok, attrs} <- changes(args),
         {:ok, show_all} <- Args.boolean(args, "show_all") do
      attrs = if is_nil(show_all), do: attrs, else: Map.put(attrs, "show_all", show_all)

      case Map.fetch(args, "apply") do
        :error ->
          {:ok, attrs}

        {:ok, ref} when is_binary(ref) or is_integer(ref) or is_nil(ref) ->
          {:ok, Map.put(attrs, "card_view", ref && to_string(ref))}

        {:ok, _} ->
          {:error, "apply must be a card view's id or name, or null for none"}
      end
    end
  end

  # The level named: global with no board, a board's, or a list's on it.
  defp scope(args, user, context) do
    with {:ok, board_ref} <- Args.optional(args, "board"),
         {:ok, list_ref} <- Args.optional(args, "list"),
         {:ok, board} <- board(board_ref, context),
         {:ok, column} <- column(board, list_ref) do
      case CardViews.scope(user, board, column) do
        {:ok, scope} -> {:ok, scope}
        {:error, :not_found} -> Args.refusal({:error, :not_found, "board"})
      end
    end
  end

  defp board(nil, _context), do: {:ok, nil}

  defp board(ref, context) do
    with {:ok, board} <- Args.refusal(Authorize.fetch_board(Args.auth(context), ref, :read)),
         do: {:ok, CardViews.with_lists(board)}
  end

  defp column(_board, nil), do: {:ok, nil}
  defp column(nil, _ref), do: {:error, "list needs a board: a list is named on its board"}

  defp column(board, ref) do
    case Enum.find(board.columns, &(to_string(&1.id) == ref)) ||
           Enum.find(board.columns, &(String.downcase(&1.name) == String.downcase(ref))) do
      nil -> {:error, "no list #{ref} on board #{board.code || board.id}"}
      column -> {:ok, column}
    end
  end

  # The card view a saved view names, by the saved view's id or name.
  defp saved_view_card_view(_board, nil), do: {:ok, nil}

  defp saved_view_card_view(board, ref) do
    case Enum.find(board.saved_views, &(to_string(&1.id) == ref or &1.name == ref)) do
      nil -> {:error, "no saved view #{ref} on board #{board.code || board.id}"}
      %{config: %{"card_view" => name}} when is_binary(name) -> {:ok, name}
      _ -> {:ok, nil}
    end
  end

  defp result({:ok, _} = ok), do: ok
  defp result({:error, :not_found}), do: {:error, "no card view of yours matches that"}
  defp result(error), do: Args.refusal(error)

  ## Answers

  defp place(:global), do: {nil, nil}
  defp place({:board, board}), do: {board, nil}
  defp place({:list, board, column}), do: {board, column}

  defp view_json(view), do: SlipdockWeb.API.JSON.card_view(view)
  defp catalogue, do: SlipdockWeb.API.JSON.card_view_elements()

  defp board_json(board), do: %{id: board.id, code: board.code, name: board.name}

  defp level_json(scope, level), do: SlipdockWeb.API.JSON.card_view_level(place(scope), level)
end
