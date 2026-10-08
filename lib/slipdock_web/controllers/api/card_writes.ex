defmodule SlipdockWeb.API.CardWrites do
  @moduledoc """
  Creating and changing cards on somebody's behalf, shared by the HTTP API
  (`SlipdockWeb.API.CardController`) and the MCP tools (`SlipdockWeb.MCP`),
  so a card written either way goes through the same checks.

  `auth` is a conn, or anything with the same `assigns` — `current_user` and
  `api_token` — which is all `SlipdockWeb.API.Authorize` reads. Failures are
  the API's `{:error, status, message}` shapes, which the API's fallback
  controller answers and MCP turns into tool errors.
  """
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card}

  @card_fields ~w(title description priority flags start_date due_date date_precision completed percent_complete time_spent time_estimate time_unit log_time color)

  @doc "The card fields a create or update takes as they are."
  def card_fields, do: @card_fields

  @doc """
  A new card on `board`, which the caller has already been checked to write.
  `params` are the API's: `column`, `tags`, `assignee`/`assignees`, and the
  plain fields.
  """
  def create(auth, board, params) do
    user = auth.assigns.current_user

    with {:ok, column} <- resolve_column(board, params["column"]),
         {:ok, tags} <- resolve_tags(board, params["tags"]),
         {:ok, assignee} <- resolve_assignees(board, params, user),
         {:ok, card} <-
           Boards.create_card(column, params |> Map.take(@card_fields) |> Map.merge(assignee),
             by: user
           ),
         {:ok, _} <- maybe_set_tags(card, tags) do
      {:ok, Boards.get_card!(card.id)}
    end
  end

  @doc """
  Changes `card`, which the caller has already been checked to write: the
  plain fields, `add_flags`/`remove_flags`, `tags`/`add_tags`/`remove_tags`,
  the assignee keys, `column` (to the bottom of it) and custom `fields`.
  """
  def update(auth, card, params) do
    user = auth.assigns.current_user
    board = Boards.get_board!(card.board_id)

    with {:ok, tags} <- resolve_tags(board, params["tags"]),
         {:ok, add} <- resolve_tags(board, params["add_tags"]),
         {:ok, remove} <- resolve_tags(board, params["remove_tags"]),
         {:ok, assignee} <- resolve_assignees(card, params, user),
         {:ok, card} <-
           Boards.update_card(card, Map.merge(card_attrs(card, params), assignee), by: user),
         {:ok, _} <- maybe_set_tags(card, tags),
         {:ok, _} <- maybe_adjust_tags(card, add, remove),
         {:ok, _} <- maybe_move(board, card, params["column"]),
         :ok <- maybe_set_fields(board, card, params["fields"]) do
      {:ok, Boards.get_card!(card.id)}
    end
  end

  ## The pieces, which the controller's other actions use too ---------------

  # `fields` is a map of field key (or name/id) to value; "" clears.
  def maybe_set_fields(_board, _card, nil), do: :ok

  def maybe_set_fields(board, card, values) when is_map(values) do
    Enum.reduce_while(values, :ok, fn {ref, value}, :ok ->
      case Slipdock.Fields.find_field(
             Slipdock.Fields.list_fields(Slipdock.Boards.Board.root_id(board)),
             ref
           ) do
        nil ->
          {:halt, {:error, :not_found, "field #{ref}"}}

        field ->
          case Slipdock.Fields.set_value(Boards.get_card!(card.id), field, value) do
            {:ok, _} -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, :unprocessable_entity, message}}
          end
      end
    end)
  end

  def maybe_set_fields(_, _, _), do: {:error, :unprocessable_entity, "fields must be an object"}

  def card_attrs(%Card{} = card, params) do
    attrs = Map.take(params, @card_fields)

    flags =
      card.flags
      |> then(fn flags ->
        if params["add_flags"],
          do: Enum.uniq(flags ++ List.wrap(params["add_flags"])),
          else: flags
      end)
      |> then(fn flags ->
        if params["remove_flags"], do: flags -- List.wrap(params["remove_flags"]), else: flags
      end)

    if params["add_flags"] || params["remove_flags"],
      do: Map.put(attrs, "flags", flags),
      else: attrs
  end

  @doc "The card with this id, whoever may read it — check that next."
  def fetch_card(id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Card{} = card <- Boards.get_card(int) do
      {:ok, card}
    else
      _ -> {:error, :not_found, "card"}
    end
  end

  # Default column: the first one on the board.
  def resolve_column(board, nil) do
    case Boards.get_board!(board.id).columns do
      [first | _] -> {:ok, first}
      [] -> {:error, :bad_request, "board has no columns"}
    end
  end

  def resolve_column(board, ref) do
    case Boards.find_column(board, ref) do
      {:ok, col} -> {:ok, col}
      _ -> {:error, :not_found, "column #{inspect(ref)}"}
    end
  end

  def resolve_tags(_board, nil), do: {:ok, nil}

  def resolve_tags(board, names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Boards.find_tag(board, name) do
        {:ok, tag} -> {:cont, {:ok, acc ++ [tag]}}
        _ -> {:halt, {:error, :unprocessable_entity, unknown_tag(board, name)}}
      end
    end)
  end

  def resolve_tags(board, name) when is_binary(name), do: resolve_tags(board, [name])

  # Tags are made on the board, never by naming one on a card, so the way out
  # of a typo is to know which there are.
  defp unknown_tag(board, name) do
    on = "no tag #{inspect(to_string(name))} on board #{board.code || board.id}"

    case board |> Board.root_id() |> Boards.list_tags() do
      [] -> on <> "; it has no tags (they are made on the board, not by naming one here)"
      tags -> on <> "; its tags are: " <> Enum.map_join(tags, ", ", & &1.name)
    end
  end

  def maybe_set_tags(_card, nil), do: {:ok, nil}
  def maybe_set_tags(card, tags), do: Boards.set_card_tags(card, tags)

  def maybe_adjust_tags(_card, nil, nil), do: {:ok, nil}

  def maybe_adjust_tags(card, add, remove) do
    current = Boards.get_card!(card.id).tags
    remove_ids = Enum.map(remove || [], & &1.id)
    kept = Enum.reject(current, &(&1.id in remove_ids))
    added = Enum.reject(add || [], fn t -> Enum.any?(kept, &(&1.id == t.id)) end)
    Boards.set_card_tags(card, kept ++ added)
  end

  def maybe_move(_board, _card, nil), do: {:ok, nil}

  def maybe_move(board, card, ref) do
    with {:ok, column} <- resolve_column(board, ref) do
      if column.id == card.column_id,
        do: {:ok, nil},
        else: {Boards.move_card_to_index(card, column, :bottom), nil}
    end
  end

  def parse_index(nil), do: :bottom
  def parse_index("top"), do: :top
  def parse_index("bottom"), do: :bottom
  def parse_index(i) when is_integer(i), do: i

  def parse_index(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> :bottom
    end
  end

  def parse_index(_), do: :bottom

  # Who the card is assigned to, as people's emails ("me" is whoever is
  # asking). `assignees` is the whole set and `assignee` one person — both
  # replace who is on it, and "" / null / [] unassigns. `add_assignees` and
  # `remove_assignees` change the set without restating it. Absent leaves it
  # alone. `target` is the card, or the board a new one is going on.
  #
  # Only people the caller can see and who can read the card can be put on it
  # (`Boards.resolve_assignees/3`), and anybody else is the same 404 whether
  # or not the address has an account, so this is not a way to find out who
  # does. Taking somebody off looks only at who is on the card already.
  def resolve_assignees(target, params, me) do
    [
      {"assignees", "assignee_ids"},
      {"assignee", "assignee_ids"},
      {"add_assignees", "add_assignee_ids"},
      {"remove_assignees", "remove_assignee_ids"}
    ]
    |> Enum.filter(fn {key, _} -> Map.has_key?(params, key) end)
    # `assignees` wins over `assignee` when a caller sends both.
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.reduce_while({:ok, %{}}, fn {key, attr}, {:ok, acc} ->
      case user_ids(target, attr, emails(params[key]), me) do
        {:ok, ids} -> {:cont, {:ok, Map.put(acc, attr, ids)}}
        {:error, {:not_found, ref}} -> {:halt, {:error, :not_found, "user #{ref}"}}
      end
    end)
  end

  def emails(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(&if(is_binary(&1), do: String.split(&1, ","), else: [&1]))
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  def user_ids(%Card{} = card, "remove_assignee_ids", emails, me) do
    on_it = Card.assignees(Boards.get_card!(card.id))

    Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, ids} ->
      wanted =
        if Enum.member?(~w(me myself mine), email), do: me.email, else: String.downcase(email)

      case Enum.find(on_it, &(&1.email == wanted)) do
        nil -> {:halt, {:error, {:not_found, email}}}
        user -> {:cont, {:ok, ids ++ [user.id]}}
      end
    end)
  end

  def user_ids(target, _attr, emails, me), do: Boards.resolve_assignees(target, me, emails)
end
