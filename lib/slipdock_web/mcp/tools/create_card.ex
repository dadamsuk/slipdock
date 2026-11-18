defmodule SlipdockWeb.MCP.Tools.CreateCard do
  @moduledoc "A new card on a board, or a subcard under an epic."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}
  alias SlipdockWeb.Ops

  # The params it shares with `POST /api/boards/:board/cards` (`Ops.AddCard`).
  # Its own: parent (a subcard, making the sub-board), top and
  # subcard_template.
  @shared ~w(board title description column short_name priority tags assignees start_date
             due_date bar paths profile caused_by missed_by archived origin)

  @doc false
  def shared, do: @shared

  @impl true
  def name, do: "create_card"

  @impl true
  def title, do: "Create a card"

  @impl true
  def description,
    do:
      "Adds a card to a board, or with parent a subcard under that card (making its " <>
        "sub-board if needed). Search first: don't add what is already there."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        parent: %{
          type: "integer",
          description: "Make it a subcard of this card, in place of board."
        },
        top: %{type: "boolean", description: "Put it at the top of the list (default bottom)."},
        subcard_template: %{
          type: "string",
          description: "Lists for a new sub-board (default \"Simple\")."
        }
      },
      required: ["title"],
      additionalProperties: false
    }
    # The params it shares with POST /api/boards/:board/cards, from its
    # definition (#3361).
    |> Map.update!(:properties, &Map.merge(&1, Ops.params_from(Ops.AddCard, @shared)))
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, title} <- Args.required(args, "title"),
         {:ok, top} <- Args.boolean(args, "top", false),
         {:ok, archived} <- Args.boolean(args, "archived", false),
         {:ok, tags} <- Args.strings(args, "tags"),
         {:ok, assignees} <- Args.strings(args, "assignees"),
         {:ok, board} <- target(args, auth),
         {:ok, column} <- column(args, board),
         params = params(args, title, column, tags, assignees) |> Map.put("archived", archived),
         {:ok, card} <- Args.refusal(CardWrites.create(auth, board, params)),
         :ok <- if(top, do: Boards.Cards.move_card_to_index(card, card.column, :top), else: :ok) do
      {:ok, Tools.card_written(Boards.Cards.get_card!(card.id), context.base_url)}
    end
  end

  defp params(args, title, column, tags, assignees) do
    args
    |> Map.take(
      ~w(short_name description priority start_date due_date bar paths profile caused_by missed_by
         origin)
    )
    |> Map.merge(%{"title" => title, "column" => column})
    |> then(&if(tags, do: Map.put(&1, "tags", tags), else: &1))
    |> then(&if(assignees, do: Map.put(&1, "assignees", assignees), else: &1))
  end

  # The board named, or the parent card's sub-board — made now if it has none.
  defp target(%{"parent" => parent} = args, auth) when not is_nil(parent) do
    with {:ok, id} <- Args.id(args, "parent"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)) do
      case card.sub_board do
        %Boards.Board{} = sub -> {:ok, sub}
        _ -> make_sub_board(auth, card, args["subcard_template"] || "Simple")
      end
    end
  end

  defp target(args, auth) do
    with {:ok, ref} <- Args.required(args, "board") |> board_or_parent() do
      Args.refusal(Authorize.fetch_board(auth, ref, :write))
    end
  end

  defp board_or_parent({:error, "board is required"}),
    do: {:error, "give board, or parent for a subcard"}

  defp board_or_parent(other), do: other

  # A template's tags go on the tree's root, so they come only when this
  # caller may change the root's tags (#2990).
  defp make_sub_board(auth, card, template_ref) do
    user = auth.assigns.current_user
    make_tags? = Authorize.tags(auth, Boards.get_board_record!(card.board_id)) == :ok

    with {:ok, template} <- template(user, template_ref),
         {:ok, board} <-
           Args.refusal(Boards.create_sub_board(card, template, by: user, make_tags: make_tags?)) do
      {:ok, board}
    end
  end

  defp template(user, ref) do
    case Boards.Templates.find_template(user, ref) do
      {:ok, t} ->
        {:ok, t}

      _ ->
        names = Enum.map_join(Boards.Templates.list_templates(user), ", ", & &1.name)
        {:error, "no template called #{inspect(ref)}; there are: #{names}"}
    end
  end

  # The list named, else the ready list rather than whichever list is first:
  # a new card is work to be picked up, not something for the backlog.
  defp column(args, board) do
    with {:ok, ref} <- Args.optional(args, "column") do
      case ref do
        nil ->
          roles = SlipdockWeb.APIGuide.list_roles(Boards.get_board!(board.id).columns)
          {:ok, roles.ready && roles.ready.id}

        name ->
          {:ok, name}
      end
    end
  end
end
