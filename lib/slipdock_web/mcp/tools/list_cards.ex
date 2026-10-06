defmodule SlipdockWeb.MCP.Tools.ListCards do
  @moduledoc "Cards on a board, filtered the way `slipdock cards` filters them."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.MCP.{Args, Tools}

  @max 200

  # What `Boards.list_cards/2` takes for each.
  @archived %{"exclude" => nil, "include" => "all", "only" => "true"}

  @impl true
  def name, do: "list_cards"

  @impl true
  def title, do: "List cards"

  @impl true
  def description,
    do:
      "Cards on a board, in list order. To find the next thing to do: column = the ready " <>
        "list, open = true, deps = \"ready\", no_assignee = true, then take the first."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        board: %{type: "string", description: "Board id, code or name."},
        column: %{type: "string", description: "Only this list (name or id)."},
        open: %{
          type: "boolean",
          description: "true: only cards not completed; false: only completed."
        },
        deps: %{
          type: "string",
          enum: keys(Config.deps()),
          description: "Dependency state; \"ready\" = nothing unfinished blocks it."
        },
        assignee: %{type: "string", description: "Email or name; \"me\" for yourself."},
        no_assignee: %{type: "boolean", description: "Only cards nobody is assigned to."},
        archived: %{
          type: "string",
          enum: Map.keys(@archived),
          description: "Archived cards: left out (exclude, the default), as well, or alone."
        },
        due: %{type: "string", enum: keys(Config.dues())},
        tag: %{type: "string"},
        q: %{type: "string", description: "Words in the title or description."},
        limit: %{type: "integer", description: "At most this many (default 50, max #{@max})."}
      },
      required: ["board"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, ref} <- Args.required(args, "board"),
         {:ok, filters} <- filters(args, context.user),
         {:ok, limit} <- Args.limit(args, "limit", 50, @max),
         {:ok, board} <- Args.refusal(Authorize.fetch_board(auth, ref, :read)) do
      cards = Authorize.visible(auth, Boards.list_cards(board, filters))

      {:ok,
       %{
         board: %{id: board.id, code: board.code, name: board.name},
         total: length(cards),
         truncated: length(cards) > limit,
         cards: cards |> Enum.take(limit) |> Enum.map(&Tools.card_line/1)
       }}
    end
  end

  defp filters(args, user) do
    with {:ok, column} <- Args.optional(args, "column"),
         {:ok, open} <- Args.boolean(args, "open"),
         {:ok, deps} <- bucket(args, "deps", Config.deps()),
         {:ok, due} <- bucket(args, "due", Config.dues()),
         {:ok, assignee} <- Args.optional(args, "assignee"),
         {:ok, nobody} <- Args.boolean(args, "no_assignee", false),
         {:ok, tag} <- Args.optional(args, "tag"),
         {:ok, q} <- Args.optional(args, "q"),
         {:ok, archived} <- archived(args) do
      assignee =
        cond do
          nobody -> "none"
          assignee in ~w(me myself mine) -> user.email
          true -> assignee
        end

      filters =
        %{
          "column" => column,
          "completed" => if(is_boolean(open), do: to_string(not open)),
          "deps" => deps,
          "due" => due,
          "assignee" => assignee,
          "tag" => tag,
          "q" => q,
          "archived" => archived
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, filters}
    end
  end

  defp archived(args) do
    with {:ok, value} <- Args.optional(args, "archived") do
      case Map.fetch(@archived, value || "exclude") do
        {:ok, filter} -> {:ok, filter}
        :error -> {:error, "archived must be one of: exclude, include, only"}
      end
    end
  end

  # A value that isn't one of the buckets would be quietly ignored by
  # `Boards.list_cards/2`, handing back everything as if it were the answer.
  defp bucket(args, key, allowed) do
    with {:ok, value} <- Args.optional(args, key) do
      cond do
        is_nil(value) -> {:ok, nil}
        value in keys(allowed) -> {:ok, value}
        true -> {:error, "#{key} must be one of: #{Enum.join(keys(allowed), ", ")}"}
      end
    end
  end

  defp keys(buckets), do: buckets |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))
end
