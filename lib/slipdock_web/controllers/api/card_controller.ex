defmodule SlipdockWeb.API.CardController do
  use SlipdockWeb, :controller

  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  @card_fields ~w(title description priority flags start_date due_date date_precision completed percent_complete time_spent time_estimate time_unit log_time color)

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, params} <- check_bucket(params, "due", Config.dues()),
         {:ok, params} <- check_bucket(params, "deps", Config.deps()),
         {:ok, params} <- check_bucket(params, "kind", Slipdock.Kinds.card_kinds()) do
      params = resolve_me(params, conn.assigns.current_user)

      json(conn, %{
        cards: Enum.map(Authorize.visible(conn, Boards.list_cards(board, params)), &V.card/1)
      })
    end
  end

  # A filter value that isn't one of the buckets is a mistake worth saying
  # out loud: `Boards.list_cards/2` would quietly ignore it and hand back
  # everything, which reads as an answer.
  defp check_bucket(params, key, allowed) do
    case params[key] do
      value when value in [nil, ""] ->
        {:ok, Map.delete(params, key)}

      value ->
        keys = allowed |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))

        if value in keys,
          do: {:ok, params},
          else: {:error, :bad_request, "#{key} must be one of: #{Enum.join(keys, ", ")}"}
    end
  end

  defp resolve_me(%{"assignee" => me} = params, user)
       when me in ~w(me myself mine) and user != nil,
       do: Map.put(params, "assignee", user.email)

  defp resolve_me(params, _user), do: params

  def show(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      # The wiki pages that talk about this card, pinned first. Only here and
      # not in listings: it is one query per card, and a board listing would
      # pay it hundreds of times for something nobody reads in a table.
      docs =
        card
        |> Slipdock.Wiki.pages_for_card(conn.assigns.current_user)
        |> Enum.map(
          &%{
            code: &1.page.code,
            title: &1.page.title,
            pinned: &1.pinned,
            url: V.page_url(&1.page)
          }
        )

      json(conn, %{card: Map.put(V.card(Authorize.visible(conn, card)), :docs, docs)})
    end
  end

  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, column} <- resolve_column(board, params["column"]),
         {:ok, tags} <- resolve_tags(board, params["tags"]),
         {:ok, assignee} <- resolve_assignees(board, params, conn.assigns.current_user),
         {:ok, card} <-
           Boards.create_card(column, params |> Map.take(@card_fields) |> Map.merge(assignee),
             by: conn.assigns.current_user
           ),
         {:ok, _} <- maybe_set_tags(card, tags) do
      conn
      |> put_status(:created)
      |> json(%{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         board <- Boards.get_board!(card.board_id),
         {:ok, tags} <- resolve_tags(board, params["tags"]),
         {:ok, add} <- resolve_tags(board, params["add_tags"]),
         {:ok, remove} <- resolve_tags(board, params["remove_tags"]),
         {:ok, assignee} <- resolve_assignees(card, params, conn.assigns.current_user),
         {:ok, card} <-
           Boards.update_card(card, Map.merge(card_attrs(card, params), assignee),
             by: conn.assigns.current_user
           ),
         {:ok, _} <- maybe_set_tags(card, tags),
         {:ok, _} <- maybe_adjust_tags(card, add, remove),
         {:ok, _} <- maybe_move(board, card, params["column"]),
         :ok <- maybe_set_fields(board, card, params["fields"]) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  # `POST /api/cards/:id/timer {"action": "start" | "stop"}`. Stopping adds
  # the minutes it ran to the card's time spent.
  def timer(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, _} <- timer_action(card, params["action"]) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  defp timer_action(card, "start"), do: Boards.start_timer(card)
  defp timer_action(card, "stop"), do: Boards.stop_timer(card)

  defp timer_action(_card, _),
    do: {:error, :unprocessable_entity, "action must be start or stop"}

  def vote(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read),
         {:ok, count} <- integer(params["count"]),
         {:ok, card} <-
           Slipdock.Votes.set(card, conn.assigns.current_user, count, params["comment"]) do
      json(conn, %{
        card: V.card(Authorize.visible(conn, card)),
        my_votes: Slipdock.Votes.mine(card, conn.assigns.current_user)
      })
    else
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      other -> other
    end
  end

  def add_link(conn, %{"id" => id, "to" => to, "kind" => kind}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, other} <- fetch_card(to),
         :ok <- Authorize.card(conn, other, :read),
         {:ok, _} <- link_result(Boards.add_link(card, other, kind)) do
      conn
      |> put_status(:created)
      |> json(%{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  def remove_link(conn, %{"id" => id, "link_id" => link_id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         %{} = link <- find_link(card, link_id),
         {:ok, _} <- Boards.remove_link(link) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    else
      nil -> {:error, :not_found, "link"}
      other -> other
    end
  end

  defp link_result({:ok, link}), do: {:ok, link}

  defp link_result({:error, message}) when is_binary(message),
    do: {:error, :unprocessable_entity, message}

  defp find_link(card, link_id) do
    Enum.find(card.links_out ++ card.links_in, &(to_string(&1.id) == to_string(link_id)))
  end

  def add_status_update(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, _} <-
           Boards.add_status_update(
             card,
             conn.assigns.current_user,
             Map.take(params, ~w(health body))
           ) do
      conn
      |> put_status(:created)
      |> json(%{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  defp integer(n) when is_integer(n), do: {:ok, n}

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> {:ok, i}
      _ -> {:error, :unprocessable_entity, "count must be a whole number"}
    end
  end

  defp integer(_), do: {:error, :unprocessable_entity, "count is required"}

  # `fields` is a map of field key (or name/id) to value; "" clears.
  defp maybe_set_fields(_board, _card, nil), do: :ok

  defp maybe_set_fields(board, card, values) when is_map(values) do
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

  defp maybe_set_fields(_, _, _), do: {:error, :unprocessable_entity, "fields must be an object"}

  # `board` moves the card to another board entirely — with its subcards, its
  # tags (by name) and whatever custom fields the destination also has. See
  # `Slipdock.Boards.move_card_to_board/2`; `index` has no meaning there,
  # because the card lands at the end of a list it has never been in.
  def move(conn, %{"id" => id, "board" => ref} = params) when not is_nil(ref) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, column} <- resolve_column(board, params["column"]),
         {:ok, summary} <- move_to_board(card, column) do
      json(conn, %{
        card: V.card(Authorize.visible(conn, Boards.get_card!(card.id))),
        moved: Map.delete(summary, :card)
      })
    end
  end

  def move(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         board <- Boards.get_board!(card.board_id),
         {:ok, column} <- resolve_column(board, params["column"] || card.column_id),
         :ok <- Boards.move_card_to_index(card, column, parse_index(params["index"])) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  defp move_to_board(card, column) do
    case Boards.move_card_to_board(card, column) do
      {:ok, summary} -> {:ok, summary}
      # A limit on the destination: the fallback answers it with its 402.
      {:error, %Ecto.Changeset{}} = refused -> refused
      {:error, message} -> {:error, :unprocessable_entity, message}
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, card} <- Boards.archive_card(card) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  def restore(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, card} <- Boards.unarchive_card(card) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, _} <- Boards.delete_card(card) do
      json(conn, %{ok: true})
    end
  end

  # Body: {"template": id-or-name}. Gives the card a sub-board for subcards.
  def create_sub_board(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, template} <- fetch_template(params["template"]),
         {:ok, board} <- dependency_result(Boards.create_sub_board(card, template)) do
      conn
      |> put_status(:created)
      |> json(%{
        card: V.card(Authorize.visible(conn, Boards.get_card!(card.id))),
        board: V.board(Authorize.visible(conn, Boards.get_board!(board.id)))
      })
    end
  end

  def delete_sub_board(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, card} <- dependency_result(Boards.delete_sub_board(card)) do
      json(conn, %{card: V.card(Authorize.visible(conn, card))})
    end
  end

  defp fetch_template(nil),
    do: {:error, :bad_request, "pass template (id or name); see GET /api/templates"}

  defp fetch_template(ref) do
    case Boards.find_template(ref) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :not_found, "template"}
    end
  end

  # Body: {"blocked_by": other_id} or {"blocks": other_id}. The two cards may
  # be on different boards: the blocked one needs write, the blocker read.
  def add_dependency(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read),
         {:ok, {blocked, blocker}} <- dependency_pair(card, params),
         :ok <- Authorize.card(conn, blocked, :write),
         :ok <- Authorize.card(conn, blocker, :read),
         {:ok, _} <- dependency_result(Boards.add_dependency(blocked, blocker)) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  def remove_dependency(conn, %{"id" => id, "other_id" => other_id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, other} <- fetch_card(other_id),
         {:ok, card} <- Boards.remove_dependency(card, other) do
      json(conn, %{card: V.card(Authorize.visible(conn, card))})
    end
  end

  defp dependency_pair(card, %{"blocked_by" => other}) do
    with {:ok, other} <- fetch_card(other), do: {:ok, {card, other}}
  end

  defp dependency_pair(card, %{"blocks" => other}) do
    with {:ok, other} <- fetch_card(other), do: {:ok, {other, card}}
  end

  defp dependency_pair(_card, _),
    do: {:error, :bad_request, "pass blocked_by or blocks with a card id"}

  defp dependency_result({:ok, card}), do: {:ok, card}

  defp dependency_result({:error, message}) when is_binary(message),
    do: {:error, :bad_request, message}

  def add_checklist_item(conn, %{"id" => id, "text" => text}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, item} <- Boards.add_checklist_item(card, text) do
      conn |> put_status(:created) |> json(%{item: V.checklist_item(item)})
    end
  end

  def toggle_checklist_item(conn, %{"item_id" => item_id}) do
    with :ok <- authorize_item(conn, Slipdock.Boards.ChecklistItem, item_id),
         do: do_toggle_checklist_item(conn, item_id)
  end

  defp do_toggle_checklist_item(conn, item_id) do
    with {:ok, item} <- Boards.toggle_checklist_item(String.to_integer(item_id)) do
      json(conn, %{item: V.checklist_item(item)})
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found, "checklist item"}
  end

  def delete_checklist_item(conn, %{"item_id" => item_id}) do
    with :ok <- authorize_item(conn, Slipdock.Boards.ChecklistItem, item_id),
         do: do_delete_checklist_item(conn, item_id)
  end

  defp do_delete_checklist_item(conn, item_id) do
    with {:ok, _} <- Boards.delete_checklist_item(String.to_integer(item_id)) do
      json(conn, %{ok: true})
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found, "checklist item"}
  end

  def add_comment(conn, %{"id" => id, "body" => body}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, comment} <- Boards.add_comment(card, body, by: conn.assigns.current_user) do
      conn |> put_status(:created) |> json(%{comment: V.comment(comment)})
    end
  end

  @doc """
  Puts a link to somewhere outside the system on the card: `url`, and an
  optional `title` to show instead of the address. The card datestamps it.
  """
  def add_url(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, url} <- Boards.add_card_url(card, Map.take(params, ["url", "title"])) do
      conn |> put_status(:created) |> json(%{url: V.card_url(url)})
    end
  end

  def remove_url(conn, %{"id" => id, "url_id" => url_id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         %{} = url <- card_url_of(card, url_id),
         {:ok, _} <- Boards.delete_card_url(url) do
      json(conn, %{ok: true})
    else
      nil -> {:error, :not_found, "link"}
      other -> other
    end
  end

  # A link is only this card's to remove.
  defp card_url_of(card, url_id) do
    with {int, ""} <- Integer.parse(to_string(url_id)),
         %Slipdock.Boards.CardUrl{card_id: card_id} = url <-
           Slipdock.Repo.get(Slipdock.Boards.CardUrl, int),
         true <- card_id == card.id do
      url
    else
      _ -> nil
    end
  end

  def delete_comment(conn, %{"comment_id" => comment_id}) do
    with :ok <- authorize_item(conn, Slipdock.Boards.Comment, comment_id),
         do: do_delete_comment(conn, comment_id)
  end

  defp do_delete_comment(conn, comment_id) do
    with {:ok, _} <- Boards.delete_comment(String.to_integer(comment_id)) do
      json(conn, %{ok: true})
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found, "comment"}
  end

  ## Helpers ------------------------------------------------------------------

  defp card_attrs(%Card{} = card, params) do
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

  # A checklist item or a comment hangs off a card *or* a wiki page (see
  # `Slipdock.Boards.Owned`), so the delete routes they share authorise
  # against whichever it is.
  defp authorize_item(conn, schema, id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %{} = row <- Slipdock.Repo.get(schema, int) do
      case Slipdock.Boards.Owned.owner_ref(row) do
        {:card, card_id} ->
          with {:ok, card} <- fetch_card(card_id), do: Authorize.card(conn, card, :write)

        {:page, page_id} ->
          with %Slipdock.Wiki.Page{} = page <- Slipdock.Wiki.get_page(page_id),
               do: Authorize.page(conn, page, :write),
               else: (_ -> {:error, :not_found, "item"})
      end
    else
      _ -> {:error, :not_found, "item"}
    end
  end

  defp fetch_card(id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Card{} = card <- Boards.get_card(int) do
      {:ok, card}
    else
      _ -> {:error, :not_found, "card"}
    end
  end

  # Default column: the first one on the board.
  defp resolve_column(board, nil) do
    case Boards.get_board!(board.id).columns do
      [first | _] -> {:ok, first}
      [] -> {:error, :bad_request, "board has no columns"}
    end
  end

  defp resolve_column(board, ref) do
    case Boards.find_column(board, ref) do
      {:ok, col} -> {:ok, col}
      _ -> {:error, :not_found, "column #{inspect(ref)}"}
    end
  end

  defp resolve_tags(_board, nil), do: {:ok, nil}

  defp resolve_tags(board, names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Boards.find_tag(board, name) do
        {:ok, tag} -> {:cont, {:ok, acc ++ [tag]}}
        _ -> {:halt, {:error, :not_found, "tag #{inspect(name)}"}}
      end
    end)
  end

  defp resolve_tags(board, name) when is_binary(name), do: resolve_tags(board, [name])

  defp maybe_set_tags(_card, nil), do: {:ok, nil}
  defp maybe_set_tags(card, tags), do: Boards.set_card_tags(card, tags)

  defp maybe_adjust_tags(_card, nil, nil), do: {:ok, nil}

  defp maybe_adjust_tags(card, add, remove) do
    current = Boards.get_card!(card.id).tags
    remove_ids = Enum.map(remove || [], & &1.id)
    kept = Enum.reject(current, &(&1.id in remove_ids))
    added = Enum.reject(add || [], fn t -> Enum.any?(kept, &(&1.id == t.id)) end)
    Boards.set_card_tags(card, kept ++ added)
  end

  defp maybe_move(_board, _card, nil), do: {:ok, nil}

  defp maybe_move(board, card, ref) do
    with {:ok, column} <- resolve_column(board, ref) do
      if column.id == card.column_id,
        do: {:ok, nil},
        else: {Boards.move_card_to_index(card, column, :bottom), nil}
    end
  end

  defp parse_index(nil), do: :bottom
  defp parse_index("top"), do: :top
  defp parse_index("bottom"), do: :bottom
  defp parse_index(i) when is_integer(i), do: i

  defp parse_index(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> :bottom
    end
  end

  defp parse_index(_), do: :bottom

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
  defp resolve_assignees(target, params, me) do
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

  defp emails(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(&if(is_binary(&1), do: String.split(&1, ","), else: [&1]))
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp user_ids(%Card{} = card, "remove_assignee_ids", emails, me) do
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

  defp user_ids(target, _attr, emails, me), do: Boards.resolve_assignees(target, me, emails)
end
