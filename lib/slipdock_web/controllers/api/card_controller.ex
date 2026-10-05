defmodule SlipdockWeb.API.CardController do
  use SlipdockWeb, :controller

  alias Slipdock.Boards
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  import SlipdockWeb.API.CardWrites
  alias SlipdockWeb.API.CardWrites

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
         {:ok, card} <- CardWrites.create(conn, board, params) do
      conn
      |> put_status(:created)
      |> json(%{card: V.card(Authorize.visible(conn, card))})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, card} <- CardWrites.update(conn, card, params) do
      json(conn, %{card: V.card(Authorize.visible(conn, card))})
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
end
