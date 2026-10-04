defmodule SlipdockWeb.API.BoardController do
  use SlipdockWeb, :controller

  alias Slipdock.{Access, Boards, Favourites, Onboarding}
  alias Slipdock.Boards.Board
  alias Slipdock.Swimlanes
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  # A board the current user can at least read; view-only access doesn't count here.
  defp fetch_board(conn, ref, need) do
    with {:ok, board} <- find(Boards.find_board(ref), "board"),
         :ok <- Authorize.board(conn, board, need) do
      # The owner is named in every board response, so load it once here
      # rather than in each action that answers with a board.
      {:ok, Slipdock.Repo.preload(board, :owner)}
    end
  end

  action_fallback SlipdockWeb.API.FallbackController

  # `archived`: leave it out for the boards in play, "true" for the archived
  # ones alone, "all" for both. `sort` is one of the orders the board index
  # offers (see `Slipdock.Boards.sort_boards/2`), and defaults to the reader's
  # own — the order they put their boards in on the web.
  def index(conn, params) do
    user = conn.assigns.current_user
    sort = params["sort"] || user.board_sort || "manual"

    boards =
      user
      |> Access.list_boards(
        archived: archived_filter(params["archived"]),
        activity: true,
        token: conn.assigns[:api_token]
      )
      |> Boards.sort_boards(sort)

    json(conn, %{boards: Enum.map(boards, &V.board_summary(&1, user))})
  end

  defp archived_filter(value) when value in ["all", "both"], do: :all
  defp archived_filter(value) when value in [true, "true", "1", "yes", "only"], do: true
  defp archived_filter(_), do: false

  def archive(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :owner),
         {:ok, board} <- archivable(Boards.archive_board(board)) do
      json(conn, %{board: V.board_summary(board, conn.assigns.current_user)})
    end
  end

  # A sub-board belongs to the card it hangs off, and goes away with it.
  defp archivable({:error, :sub_board}) do
    {:error, :unprocessable_entity,
     "a subcard board cannot be archived on its own — archive or delete its card instead"}
  end

  defp archivable(result), do: result

  def restore(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :owner),
         {:ok, board} <- Boards.unarchive_board(board) do
      json(conn, %{board: V.board_summary(board, conn.assigns.current_user)})
    end
  end

  @doc """
  Sets the order the caller lists boards in: `boards` is the refs they want,
  first to last. The order is theirs alone, and boards they leave out fall to
  the end, oldest first.
  """
  def order(conn, %{"boards" => refs}) when is_list(refs) do
    user = conn.assigns.current_user

    visible =
      user
      |> Access.list_boards(archived: :all, token: conn.assigns[:api_token])
      |> MapSet.new(& &1.id)

    with {:ok, boards} <- resolve_all(refs),
         {:ok, ids} <- all_visible(boards, visible) do
      :ok = Boards.reorder_boards(user, ids)

      boards =
        user
        |> Access.list_boards(token: conn.assigns[:api_token])
        |> Boards.sort_boards("manual")

      json(conn, %{boards: Enum.map(boards, &V.board_summary(&1, user))})
    end
  end

  def order(_conn, _params), do: {:error, :bad_request, "order needs a list of boards"}

  defp all_visible(boards, visible) do
    case Enum.find(boards, &(not MapSet.member?(visible, &1.id))) do
      nil -> {:ok, Enum.map(boards, & &1.id)}
      board -> {:error, :forbidden, "you cannot see the board “#{board.name}”"}
    end
  end

  defp resolve_all(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case find(Boards.find_board(to_string(ref)), "board") do
        {:ok, board} -> {:cont, {:ok, acc ++ [board]}}
        error -> {:halt, error}
      end
    end)
  end

  def show(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :read) do
      json(conn, %{board: V.board(Boards.get_board!(board.id))})
    end
  end

  def create(conn, params) do
    attrs =
      params
      |> Map.take(~w(name code shortcut description color kind simple))

    with {:ok, template} <- optional_template(params["template"]),
         {:ok, board} <-
           Boards.create_board(attrs,
             template: template,
             owner_id: conn.assigns.current_user.id
           ) do
      conn |> put_status(:created) |> json(%{board: V.board(Boards.get_board!(board.id))})
    end
  end

  @doc """
  Builds the “Getting Started” tour board for the caller — the same board a
  first sign-in makes (see `Slipdock.Onboarding`), for an account that
  archived it or that predates the feature.

  Refuses with 409 when the caller already has one, unless `force` is true:
  two identical tours is nobody's intention.
  """
  def welcome(conn, params) do
    user = conn.assigns.current_user

    if Onboarding.exists_for?(user) and not truthy?(params["force"]) do
      conn
      |> put_status(:conflict)
      |> json(%{
        error:
          "You already have a “#{Onboarding.board_name()}” board. Pass force=true for another."
      })
    else
      case Onboarding.build(user) do
        {:ok, board} ->
          conn |> put_status(:created) |> json(%{board: V.board(Boards.get_board!(board.id))})

        {:error, reason} ->
          {:error, :payment_required, Atom.to_string(reason),
           Onboarding.refusal_message(user, reason)}
      end
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes"]

  def update(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :owner),
         {:ok, board} <-
           Boards.update_board(
             board,
             Map.take(
               params,
               ~w(name code shortcut description color vote_budget vote_max
                  add_card add_page add_document simple kind)
             )
           ) do
      json(conn, %{board: V.board_summary(board, conn.assigns.current_user)})
    end
  end

  def delete(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :owner),
         {:ok, _} <- Boards.delete_board(board) do
      json(conn, %{ok: true})
    end
  end

  def columns(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :read) do
      board = Boards.get_board!(board.id)

      json(conn, %{
        columns:
          Enum.map(board.columns, fn c -> c |> V.column() |> Map.put(:cards, length(c.cards)) end)
      })
    end
  end

  def create_column(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, column} <- Boards.create_column(board, Map.take(params, ~w(name wip_limit color))) do
      conn |> put_status(:created) |> json(%{column: V.column(column)})
    end
  end

  def update_column(conn, %{"board" => ref, "id" => id} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, column} <- find(Boards.find_column(board, id), "column"),
         {:ok, column} <- Boards.update_column(column, Map.take(params, ~w(name wip_limit color))) do
      json(conn, %{column: V.column(column)})
    end
  end

  def delete_column(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, column} <- find(Boards.find_column(board, id), "column"),
         {:ok, _} <- Boards.delete_column(column) do
      json(conn, %{ok: true})
    end
  end

  def fields(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :read) do
      json(conn, %{fields: Enum.map(root_fields(board), &V.field_definition/1)})
    end
  end

  def create_field(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, field} <-
           Slipdock.Fields.create_field(
             board,
             Map.take(params, ~w(name key kind options config sum))
           ) do
      conn |> put_status(:created) |> json(%{field: V.field_definition(field)})
    end
  end

  def update_field(conn, %{"board" => ref, "id" => id} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, field} <- find_field(board, id),
         {:ok, field} <-
           Slipdock.Fields.update_field(
             field,
             Map.take(params, ~w(name key options config sum position))
           ) do
      json(conn, %{field: V.field_definition(field)})
    end
  end

  def delete_field(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, field} <- find_field(board, id),
         {:ok, _} <- Slipdock.Fields.delete_field(field) do
      json(conn, %{ok: true})
    end
  end

  def install_preset(conn, %{"board" => ref, "key" => key}) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, field} <- Slipdock.Fields.install_preset(board, key) do
      json(conn, %{
        field: V.field_definition(field),
        fields: Enum.map(Slipdock.Fields.list_fields(field.board_id), &V.field_definition/1)
      })
    else
      {:error, :unknown_preset} -> {:error, :not_found, "preset"}
      other -> other
    end
  end

  def milestones(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :read) do
      json(conn, %{
        milestones: Enum.map(Boards.list_milestones(Board.root_id(board)), &V.milestone/1)
      })
    end
  end

  def create_milestone(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, m} <- Boards.create_milestone(board, Map.take(params, ~w(name date color card_id))) do
      conn |> put_status(:created) |> json(%{milestone: V.milestone(m)})
    end
  end

  def delete_milestone(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         %{} = m <-
           Enum.find(Boards.list_milestones(Board.root_id(board)), &(to_string(&1.id) == id)) ||
             {:error, :not_found, "milestone"},
         {:ok, _} <- Boards.delete_milestone(m) do
      json(conn, %{ok: true})
    end
  end

  defp root_fields(board), do: Slipdock.Fields.list_fields(Board.root_id(board))

  defp find_field(board, ref) do
    case Slipdock.Fields.find_field(root_fields(board), ref) do
      nil -> {:error, :not_found, "field"}
      field -> {:ok, field}
    end
  end

  def tags(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :read) do
      json(conn, %{tags: Enum.map(Boards.get_board!(board.id).tags, &V.tag/1)})
    end
  end

  def create_tag(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, tag} <- Boards.create_tag(board, Map.take(params, ~w(name color))) do
      conn |> put_status(:created) |> json(%{tag: V.tag(tag)})
    end
  end

  def delete_tag(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, tag} <- find(Boards.find_tag(board, id), "tag"),
         {:ok, _} <- Boards.delete_tag(tag) do
      json(conn, %{ok: true})
    end
  end

  def activity(conn, %{"board" => ref} = params) do
    limit = params |> Map.get("limit", "30") |> to_string() |> Integer.parse() |> elem(0)

    with {:ok, board} <- fetch_board(conn, ref, :read) do
      json(conn, %{activity: Enum.map(Boards.list_activities(board.id, limit), &V.activity/1)})
    end
  end

  ## Swimlanes & saved views

  @config_keys ~w(rows cols unit sort dir q due done empty density kinds tags priorities flags columns colors)

  def swimlanes(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :read),
         board = Boards.get_board!(board.id),
         {:ok, view} <- optional_view(board, params["view"]),
         {:ok, config} <- build_config(board, params, view) do
      favourite? =
        view != nil and
          Favourites.favourite?(Favourites.marks(conn.assigns.current_user), :view, view.id)

      json(conn, V.grid(board, Swimlanes.grid(board, config), config, view, favourite?))
    end
  end

  def views(conn, %{"board" => ref}) do
    with {:ok, board} <- fetch_board(conn, ref, :read) do
      marks = Favourites.marks(conn.assigns.current_user)

      views =
        for v <- Boards.list_saved_views(board.id),
            do: V.saved_view(v, Favourites.favourite?(marks, :view, v.id))

      json(conn, %{views: views})
    end
  end

  def view(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- fetch_board(conn, ref, :read),
         {:ok, view} <- find(Boards.find_saved_view(board, id), "view") do
      marks = Favourites.marks(conn.assigns.current_user)
      json(conn, %{view: V.saved_view(view, Favourites.favourite?(marks, :view, view.id))})
    end
  end

  def create_view(conn, %{"board" => ref} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         board = Boards.get_board!(board.id),
         {:ok, config} <- build_config(board, params, nil),
         {:ok, view} <-
           Boards.create_saved_view(board, %{
             "name" => params["name"],
             "config" => Config.to_map(config)
           }) do
      conn |> put_status(:created) |> json(%{view: V.saved_view(view)})
    end
  end

  def update_view(conn, %{"board" => ref, "id" => id} = params) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         board = Boards.get_board!(board.id),
         {:ok, view} <- find(Boards.find_saved_view(board, id), "view"),
         {:ok, config} <- build_config(board, params, view),
         attrs = %{"config" => Config.to_map(config)} |> put_present("name", params["name"]),
         {:ok, view} <- Boards.update_saved_view(view, attrs) do
      json(conn, %{view: V.saved_view(view)})
    end
  end

  def delete_view(conn, %{"board" => ref, "id" => id}) do
    with {:ok, board} <- fetch_board(conn, ref, :write),
         {:ok, view} <- find(Boards.find_saved_view(board, id), "view"),
         {:ok, _} <- Boards.delete_saved_view(view) do
      json(conn, %{ok: true})
    end
  end

  defp optional_template(nil), do: {:ok, nil}
  defp optional_template(""), do: {:ok, nil}

  defp optional_template(ref) do
    case Boards.find_template(ref) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :not_found, "template"}
    end
  end

  defp optional_view(_board, nil), do: {:ok, nil}
  defp optional_view(board, ref), do: find(Boards.find_saved_view(board, ref), "view")

  # Config params sit either flat on the request (`rows=tag&tags=bug,docs`) or
  # under a "config" key. Tags and lists may be given by name or id.
  defp build_config(board, params, view) do
    params =
      Map.merge(Map.take(params, @config_keys), Map.take(params["config"] || %{}, @config_keys))

    with {:ok, tags} <- resolve_refs(params["tags"], &Boards.find_tag(board, &1), "tag"),
         {:ok, columns} <- resolve_refs(params["columns"], &Boards.find_column(board, &1), "list") do
      base = if view, do: Config.from_map(view.config), else: %Config{}
      params = params |> put_present("tags", tags) |> put_present("columns", columns)
      {:ok, params |> Config.from_query(base) |> Config.sanitize(board)}
    end
  end

  defp resolve_refs(nil, _finder, _what), do: {:ok, nil}

  defp resolve_refs(refs, finder, what) do
    refs = if is_list(refs), do: refs, else: String.split(to_string(refs), ",", trim: true)

    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case finder.(ref) do
        {:ok, found} -> {:cont, {:ok, acc ++ [found.id]}}
        _ -> {:halt, {:error, :bad_request, "#{what} not found: #{ref}"}}
      end
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp find({:ok, x}, _), do: {:ok, x}
  defp find({:error, :not_found}, what), do: {:error, :not_found, what}
end
