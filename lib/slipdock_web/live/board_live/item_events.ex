defmodule SlipdockWeb.BoardLive.ItemEvents do
  @moduledoc """
  The events behind the sections a card and a placed wiki page both have
  (`SlipdockWeb.ItemComponents`): checklist, comments, status updates, web
  links, custom field values and votes.

  `BoardLive.CardComponent` and `BoardLive.PageComponent` hand these over
  once they have decided the reader may write to what they show. The socket
  is the component's, with the card or page in `item`, the board in `board`
  and the reader in `current_user`; `reload` puts a fresh copy of the item
  back. Anything named by id is looked up through the item, so it is only
  ever the item's own.
  """
  import Phoenix.Component, only: [update: 3]
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.{Boards, Fields, Votes}
  alias Slipdock.Boards.{Card, Owned}
  alias SlipdockWeb.Params

  @events ~w(add_check toggle_check delete_check add_comment delete_comment add_status_update
    delete_status_update add_card_url remove_card_url set_field vote)

  @doc "The events handled here."
  def events, do: @events

  @doc "Handles one of `events/0` for the item in the socket."
  def handle("add_check", %{"text" => text}, socket, reload) do
    if String.trim(text) != "" do
      {:ok, _} = Boards.add_checklist_item(socket.assigns.item, String.trim(text))
    end

    {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload.()}
  end

  def handle("toggle_check", %{"id" => id}, socket, reload) do
    if item = Boards.get_checklist_item(socket.assigns.item, id),
      do: Boards.toggle_checklist_item(item)

    {:noreply, reload.(socket)}
  end

  def handle("delete_check", %{"id" => id}, socket, reload) do
    if item = Boards.get_checklist_item(socket.assigns.item, id),
      do: Boards.delete_checklist_item(item)

    {:noreply, reload.(socket)}
  end

  def handle("add_status_update", %{"health" => health} = params, socket, reload) do
    %{current_user: user, item: subject} = socket.assigns

    case Boards.add_status_update(subject, user, %{"health" => health, "body" => params["body"]}) do
      {:ok, _} ->
        {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload.()}

      {:error, _} ->
        {:noreply, flash(socket, :error, "Pick a health to report.")}
    end
  end

  def handle("delete_status_update", %{"id" => id}, socket, reload) do
    if Enum.any?(socket.assigns.item.status_updates, &(to_string(&1.id) == to_string(id))) do
      {:ok, _} = Boards.delete_status_update(Params.id(id))
      {:noreply, reload.(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle("add_comment", %{"body" => body}, socket, reload) do
    body = body |> strip_upload_placeholder() |> String.trim()

    if body != "" do
      {:ok, _} = Boards.add_comment(socket.assigns.item, body, by: socket.assigns.current_user)
    end

    {:noreply, socket |> update(:form_key, &(&1 + 1)) |> reload.()}
  end

  def handle("delete_comment", %{"id" => id}, socket, _reload) do
    if comment = Boards.get_comment(socket.assigns.item, id), do: Boards.delete_comment(comment)
    {:noreply, socket}
  end

  def handle("add_card_url", params, socket, reload) do
    case Boards.add_card_url(socket.assigns.item, Map.take(params, ["url", "title"])) do
      {:ok, _} ->
        {:noreply, socket |> reload.() |> update(:form_key, &(&1 + 1))}

      {:error, changeset} ->
        {:noreply, flash(socket, :error, "That link #{url_error(changeset)}.")}
    end
  end

  def handle("remove_card_url", %{"id" => id}, socket, reload) do
    url = Boards.get_card_url!(id)

    if Owned.owner_ref(url) == item_ref_of(socket.assigns.item) do
      {:ok, _} = Boards.delete_card_url(url)
      {:noreply, reload.(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle("set_field", %{"field_id" => id, "value" => value}, socket, reload) do
    case Enum.find(socket.assigns.board.fields, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, socket}

      field ->
        case Fields.set_value(socket.assigns.item, field, value) do
          {:ok, _} -> {:noreply, reload.(socket)}
          {:error, message} -> {:noreply, flash(socket, :error, message)}
        end
    end
  end

  def handle("vote", %{"count" => count}, socket, reload) do
    case socket.assigns.item do
      nil ->
        {:noreply, socket}

      subject ->
        with count when is_integer(count) <- Params.int(count),
             {:ok, _} <- Votes.set(subject, socket.assigns.current_user, count) do
          {:noreply, reload.(socket)}
        else
          nil -> {:noreply, socket}
          {:error, message} -> {:noreply, flash(socket, :error, message)}
        end
    end
  end

  defp item_ref_of(%Slipdock.Wiki.Page{id: id}), do: {:page, id}
  defp item_ref_of(%Card{id: id}), do: {:card, id}
end
