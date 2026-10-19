defmodule SlipdockWeb.API.CardController do
  use SlipdockWeb, :controller

  alias Slipdock.{Boards, Repo}
  alias Slipdock.Boards.Comment
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.Uploads
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  import SlipdockWeb.API.CardWrites
  alias SlipdockWeb.API.CardWrites

  def index(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read),
         {:ok, params} <- check_bucket(params, "due", Config.dues()),
         {:ok, params} <- check_bucket(params, "deps", Config.deps()),
         {:ok, params} <- check_bucket(params, "kind", Slipdock.Kinds.card_kinds()),
         {:ok, params} <-
           check_bucket(params, "snoozed", [{"exclude", ""}, {"include", ""}, {"only", ""}]),
         {:ok, params} <- check_bucket(params, "driver", Config.drivers()),
         {:ok, params} <- check_bucket(params, "stuck", [{"true", ""}, {"false", ""}]),
         {:ok, params} <- check_column(board, params) do
      params = resolve_me(params, conn.assigns.current_user)

      json(
        conn,
        %{cards: Enum.map(Authorize.visible(conn, Boards.list_cards(board, params)), &V.card/1)}
        |> Map.merge(V.paused(board))
      )
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

  defp check_column(board, params) do
    params = if params["column"] == "", do: Map.delete(params, "column"), else: params

    case Boards.check_column(board, params["column"]) do
      :ok -> {:ok, params}
      {:error, message} -> {:error, :bad_request, message}
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

      json(conn, %{
        card:
          conn
          |> Authorize.visible(Boards.with_state(card))
          |> V.card()
          |> Map.put(:docs, docs)
          |> Map.put(:wait, V.wait(Boards.current_wait(card)))
          |> Map.put(:last_wait, V.wait(Boards.last_wait(card)))
          |> V.put_delivery(card)
      })
    end
  end

  def create(conn, %{"board" => ref} = params) do
    with :ok <- CardWrites.check_create_keys(params, ["board"]),
         {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
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
           Slipdock.Votes.set(
             card,
             conn.assigns.current_user,
             count,
             vote_comment(conn, card, params)
           ) do
      json(conn, %{
        card: V.card(Authorize.visible(conn, card)),
        my_votes: Slipdock.Votes.mine(card, conn.assigns.current_user)
      })
    else
      {:error, message} when is_binary(message) -> {:error, :unprocessable_entity, message}
      other -> other
    end
  end

  # Anyone who can read a card can vote on it, but a vote's comment is text
  # left on the card, so only someone who may comment on it may leave one.
  defp vote_comment(conn, card, params) do
    if Authorize.card(conn, card, :comment) == :ok, do: params["comment"]
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
         :ok <- Authorize.card(conn, card, :comment),
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
         {:ok, summary} <- move_to_board(card, column, Slipdock.Actor.from_conn(conn)) do
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
         :ok <-
           Boards.move_card_to_index(card, column, parse_index(params["index"]),
             actor: Slipdock.Actor.from_conn(conn)
           ) do
      json(conn, %{card: V.card(Authorize.visible(conn, Boards.get_card!(card.id)))})
    end
  end

  defp move_to_board(card, column, actor) do
    case Boards.move_card_to_board(card, column, actor: actor) do
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

  @doc """
  `POST /api/cards/:id/copy` — a copy of the card as it is now (see
  `Slipdock.Boards.Copy`): checklist unticked, subcards reopened, no
  attachments, comments or dates. Optional `board` and `column` say where
  (default: straight after the original, in its list), `title` renames the
  copy, and `at` is `top`, `bottom` or `after`. Reading the card is enough to
  copy it; the list it lands in must be one you can write to.
  """
  def copy(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read),
         {:ok, board} <- Authorize.fetch_board(conn, params["board"] || card.board_id, :write),
         {:ok, column} <- copy_column(board, card, params["column"]),
         {:ok, at} <- copy_at(params["at"]),
         {:ok, copy} <-
           Boards.copy_card(card, column,
             by: conn.assigns.current_user,
             at: at,
             attrs: Map.take(params, ["title"])
           ) do
      conn
      |> put_status(:created)
      |> json(%{card: V.card(Authorize.visible(conn, copy)), copied_from: card.id})
    end
  end

  defp copy_column(%{id: board_id}, %{board_id: board_id, column_id: column_id}, ref)
       when ref in [nil, ""],
       do: {:ok, Repo.get!(Slipdock.Boards.Column, column_id)}

  defp copy_column(board, _card, ref),
    do: resolve_column(board, if(ref == "", do: nil, else: ref))

  defp copy_at(nil), do: {:ok, :after}
  defp copy_at(at) when at in ~w(top bottom after), do: {:ok, String.to_existing_atom(at)}
  defp copy_at(_), do: {:error, :bad_request, "at must be one of: top, bottom, after"}

  # Body: {"template": id-or-name}. Gives the card a sub-board for subcards.
  def create_sub_board(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, template} <- fetch_template(conn, params["template"]),
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

  defp fetch_template(_conn, nil),
    do: {:error, :bad_request, "pass template (id or name); see GET /api/templates"}

  defp fetch_template(conn, ref) do
    case Boards.find_template(conn.assigns.current_user, ref) do
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

  @doc """
  The card's timeline (#1131): the lists it has sat in, its waits and its
  runner jobs, as spans of time (`Slipdock.CardTimeline`).
  """
  def timeline(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      json(conn, %{card: card.id, timeline: V.timeline(Slipdock.CardTimeline.for_card(card))})
    end
  end

  @doc """
  The card's handoff and its history, newest first (W-1804). `handoff` is
  nil when there is none or it was cleared.
  """
  # An incident card's link to the deploy that caused it (#1134): makes that
  # deploy a failed change. `deployment` names it; DELETE unlinks.
  def incident_of(conn, %{"id" => id} = params) do
    deployment = if conn.method == "DELETE", do: nil, else: params["deployment"]

    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         :ok <- deployment_given(conn.method, deployment),
         {:ok, card} <- incident_link(card, deployment) do
      json(conn, %{card: card.id, incident_of: card.caused_by_deployment_id})
    end
  end

  defp deployment_given("POST", blank) when blank in [nil, ""],
    do: {:error, :bad_request, "pass deployment: the id of the deploy that caused it"}

  defp deployment_given(_method, _deployment), do: :ok

  defp incident_link(card, deployment) do
    case Slipdock.Deployments.Incidents.link(card, deployment) do
      {:error, :not_found} -> {:error, :not_found, "deployment on this card's board"}
      result -> result
    end
  end

  def handoff(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      history = Boards.handoff_history(card)

      json(conn, %{
        card: card.id,
        handoff: current(history),
        history: Enum.map(history, &V.handoff/1)
      })
    end
  end

  defp current([newest | _]),
    do: unless(Slipdock.Boards.Handoff.cleared?(newest), do: V.handoff(newest))

  defp current([]), do: nil

  @doc """
  Leaves a handoff on the card: `next_step` (one line, required) and `body`,
  or `clear: true`. Anyone who may comment on the card may write one. `via`
  is `cli` from the command line and `api` otherwise.
  """
  def leave_handoff(conn, %{"id" => id} = params) do
    via = if params["via"] == "cli", do: "cli", else: "api"

    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :comment),
         {:ok, handoff} <-
           CardWrites.write_handoff(card, conn.assigns.current_user, params, via) do
      conn |> put_status(:created) |> json(%{card: card.id, handoff: V.handoff(handoff)})
    end
  end

  @doc """
  Opens a wait on the card (#1114): `needs` (required), `on` (a person, or
  nothing for anyone), `choices` and `job_id`. Needs write on the card.
  """
  def open_wait(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         {:ok, wait} <- CardWrites.open_wait(conn, card, params) do
      conn |> put_status(:created) |> json(%{card: card.id, wait: V.wait(wait)})
    end
  end

  @doc "Answers the card's open wait: `answer`, `choice` (from 1), or both."
  def answer_wait(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         {:ok, wait} <- CardWrites.answer_wait(conn, card, params) do
      json(conn, %{card: card.id, wait: V.wait(wait)})
    end
  end

  @doc "Withdraws the card's open wait."
  def withdraw_wait(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         {:ok, wait} <- CardWrites.withdraw_wait(conn, card) do
      json(conn, %{card: card.id, wait: V.wait(wait)})
    end
  end

  def add_comment(conn, %{"id" => id, "body" => body}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :comment),
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

  @doc "The files attached to the card, oldest first."
  def attachments(conn, %{"id" => id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :read) do
      card = Slipdock.Repo.preload(card, :attachments, force: true)
      json(conn, %{attachments: Enum.map(card.attachments, &Uploads.json/1)})
    end
  end

  @doc """
  Attaches a file to the card: the multipart field `file`, and an optional
  `filename` to store it under instead of the one it was sent with.
  `replace=true` deletes the card's older files of that name once it is
  stored, and `replaced` lists their ids (#1017).
  """
  def add_attachment(conn, %{"id" => id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         {:ok, meta, path} <- Uploads.take(params),
         {:ok, replace?} <- Uploads.replace(params),
         {:ok, attachment} <- Boards.add_attachment(card, meta, path) do
      conn |> put_status(:created) |> json(Uploads.stored(attachment, replace?))
    end
  end

  @doc """
  Changes how a file shows: `hide_on_card: true` keeps an image off the
  card's front, `false` lets it be the thumbnail again.
  """
  def update_attachment(conn, %{"id" => id, "attachment_id" => attachment_id} = params) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         %{} = attachment <- attachment_of(card, attachment_id),
         {:ok, hide?} <- Uploads.hide_on_card(params, attachment.hide_on_card),
         {:ok, attachment} <- Boards.hide_attachment_on_card(attachment, hide?) do
      json(conn, %{attachment: Uploads.json(attachment)})
    else
      nil -> {:error, :not_found, "attachment"}
      other -> other
    end
  end

  @doc """
  Sends a recording to the transcription server. It runs in the background:
  the 202 carries the attachment marked `running`, and reading it again
  (`GET /api/cards/:id/attachments`) shows the `transcript` once it is done.
  """
  def transcribe_attachment(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         %{} = attachment <- attachment_of(card, attachment_id) do
      case Slipdock.Transcription.transcribe_attachment(attachment) do
        {:ok, _} ->
          # Inline in the tests, so read it back rather than trust the copy
          # that set off.
          attachment = Boards.get_attachment!(attachment.id)
          conn |> put_status(:accepted) |> json(%{attachment: Uploads.json(attachment)})

        {:error, :running} ->
          {:error, :conflict, Slipdock.Transcription.describe(:running)}

        {:error, reason} ->
          {:error, :unprocessable_entity, Slipdock.Transcription.describe(reason)}
      end
    else
      nil -> {:error, :not_found, "attachment"}
      other -> other
    end
  end

  def remove_attachment(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with {:ok, card} <- fetch_card(id),
         :ok <- Authorize.card(conn, card, :write),
         %{} = attachment <- attachment_of(card, attachment_id),
         {:ok, _} <- Boards.delete_attachment(attachment) do
      json(conn, %{ok: true})
    else
      nil -> {:error, :not_found, "attachment"}
      other -> other
    end
  end

  # A file is only this card's to remove.
  defp attachment_of(card, attachment_id) do
    with {int, ""} <- Integer.parse(to_string(attachment_id)),
         %Slipdock.Boards.Attachment{card_id: card_id} = attachment <-
           Slipdock.Repo.get(Slipdock.Boards.Attachment, int),
         true <- card_id == card.id do
      attachment
    else
      _ -> nil
    end
  end

  # A writer deletes any comment; a commenter only their own (#863).
  def delete_comment(conn, %{"comment_id" => comment_id}) do
    with :ok <- authorize_comment_delete(conn, comment_id),
         do: do_delete_comment(conn, comment_id)
  end

  defp authorize_comment_delete(conn, comment_id) do
    with {:error, :forbidden, _} = refused <- authorize_item(conn, Comment, comment_id) do
      own? =
        Repo.get(Comment, String.to_integer(comment_id)).user_id == conn.assigns.current_user.id

      if own? and authorize_item(conn, Comment, comment_id, :comment) == :ok,
        do: :ok,
        else: refused
    end
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
  defp authorize_item(conn, schema, id, need \\ :write) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %{} = row <- Slipdock.Repo.get(schema, int) do
      case Slipdock.Boards.Owned.owner_ref(row) do
        {:card, card_id} ->
          with {:ok, card} <- fetch_card(card_id), do: Authorize.card(conn, card, need)

        {:page, page_id} ->
          with %Slipdock.Wiki.Page{} = page <- Slipdock.Wiki.get_page(page_id),
               do: Authorize.page(conn, page, need),
               else: (_ -> {:error, :not_found, "item"})
      end
    else
      _ -> {:error, :not_found, "item"}
    end
  end
end
