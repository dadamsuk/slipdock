defmodule SlipdockWeb.WikiLive.Drafts do
  @moduledoc """
  The page editor's form, its auto-save and its image uploads, for
  `WikiLive.Index`: the form goes to the server on every pause for the
  preview, and a timer writes the latest of a burst as an autosave.
  """
  use SlipdockWeb, :html
  import Phoenix.LiveView

  alias Slipdock.{Boards, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Wiki.{Autosave, AutosaveFile, Autosaves, Page}
  alias SlipdockWeb.Wiki.Renderer

  ## Auto-save ----------------------------------------------------------------
  #
  # The form goes to the server on every pause anyway, for the preview. Each
  # one is noted here, and a timer writes the latest, so a long burst of typing
  # is a write every few seconds. Nothing is written for a form that still says
  # what the page says. See `Slipdock.Wiki.Autosaves`.

  @autosave_after_ms Application.compile_env(:slipdock, :wiki_autosave_after_ms, 3000)

  def assign_form(socket, %Page{} = page, attrs) do
    assign(socket, form: to_form(Wiki.change_page(page, attrs)), editing: page)
  end

  def assign_autosave(socket, autosave) do
    assign(socket,
      autosave: autosave,
      autosave_pending: nil,
      autosaved?: false,
      restored_from: autosave && autosave.updated_at
    )
  end

  def queue_autosave(%{assigns: %{can_write: false}} = socket, _params), do: socket

  def queue_autosave(socket, params) do
    socket = assign(socket, autosave_pending: params)

    if socket.assigns.autosave_timer do
      socket
    else
      Process.send_after(self(), :autosave, @autosave_after_ms)
      assign(socket, autosave_timer: true)
    end
  end

  def flush_autosave(%{assigns: %{autosave_pending: nil}} = socket), do: socket

  def flush_autosave(socket) do
    %{autosave_pending: params, autosave: autosave, editing: editing, page: page} = socket.assigns
    socket = assign(socket, autosave_pending: nil)

    cond do
      not Autosaves.unchanged?(editing, params) -> write_autosave(socket, params)
      # Back to what the page says: there is nothing left to keep.
      page && autosave -> clear_autosave(socket)
      autosave -> write_autosave(socket, params)
      true -> socket
    end
  end

  defp write_autosave(socket, params) do
    %{current_user: user, board: board, page: page, autosave: autosave} = socket.assigns

    case Autosaves.save(
           user,
           board,
           page,
           autosave,
           autosave_attrs(socket, params),
           socket.assigns.base_hash
         ) do
      {:ok, saved} -> assign(socket, autosave: saved, autosaved?: true)
      {:error, _} -> socket
    end
  end

  defp autosave_attrs(socket, params) do
    attrs = Map.take(params, Autosaves.fields())

    case socket.assigns do
      %{page: nil, new_parent: parent, new_column: column} ->
        Map.merge(attrs, %{"parent" => parent && parent.slug, "column" => column && column.id})

      _ ->
        attrs
    end
  end

  # The save or the Cancel it was waiting for: nothing more to write.
  def clear_autosave(socket) do
    Autosaves.discard(socket.assigns.autosave)
    assign(socket, autosave: nil, autosave_pending: nil, autosaved?: false, restored_from: nil)
  end

  # What is waiting to be picked up again, where a writer would look for it:
  # the wiki's front page, and the page they would otherwise start afresh.
  def assign_unsaved(%{assigns: assigns} = socket) do
    assign(socket,
      unsaved:
        if(
          assigns.can_write and Enum.member?([:index, :new], assigns.live_action) and
            is_nil(assigns.autosave),
          do: Autosaves.on_board(assigns.current_user, assigns.board),
          else: []
        )
    )
  end

  # Rendering needs the page (for `[[!toc]]` and friends), the board (to read
  # unqualified references against) and the reader (so a chip for a card they
  # cannot open degrades to plain text).
  # A drawing's page (the Excalidraw plugin's `.excalidraw.md`) shows the
  # drawing, not the plugin's wrapping of it (W-103 R5.1); a body that does
  # not hold a readable scene falls back to its Markdown.
  def render_body(socket, %Page{} = page, body)
      when is_binary(body) and body == page.body do
    if Slipdock.Wiki.Excalidraw.page?(page) and
         match?({:ok, _}, Slipdock.Wiki.Excalidraw.parse_markdown(body)),
       do: drawing_body(page),
       else: markdown_body(socket, page, body)
  end

  def render_body(socket, page, body), do: markdown_body(socket, page, body)

  defp drawing_body(page) do
    ~s|<figure class="wiki-drawing-page"><img class="wiki-drawing-preview" src="| <>
      Phoenix.HTML.Engine.html_escape(Slipdock.Wiki.Drawings.preview_url(page)) <>
      ~s|" alt="| <> Phoenix.HTML.Engine.html_escape(page.title) <> ~s|"></figure>|
  end

  defp markdown_body(socket, page, body) do
    Renderer.to_html(body,
      page: page,
      board: socket.assigns.board,
      as: socket.assigns.current_user
    )
  end

  ## Uploads ------------------------------------------------------------------
  #
  # Pasting an image into the editor is the same flow a card description has:
  # the hook drops a placeholder at the cursor, the file goes up, and the
  # server sends back the Markdown to put in its place.

  def handle_upload(name, entry, socket) do
    page = socket.assigns.page

    cond do
      not entry.done? ->
        {:noreply, socket}

      not socket.assigns.can_write ->
        {:noreply,
         socket
         |> cancel_upload(name, entry.ref)
         |> push_event("image_failed", %{upload: "page_image"})
         |> put_flash(:error, "You can't write on this board.")}

      is_nil(page) ->
        # A brand-new page has nowhere to hang a file yet, so its auto-save
        # holds it until the page exists.
        {:noreply, hold_image(socket, entry)}

      true ->
        meta = upload_meta(entry)

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Wiki.add_attachment(page, meta, path)}
          end)

        {:noreply, uploaded(socket, result)}
    end
  end

  defp upload_meta(entry) do
    %{filename: entry.client_name, content_type: entry.client_type, size: entry.client_size}
  end

  defp hold_image(socket, entry) do
    socket =
      case socket.assigns do
        %{autosave: %Autosave{}} -> socket
        %{autosave_pending: nil, form: form} -> write_autosave(socket, form.params || %{})
        %{autosave_pending: params} -> write_autosave(socket, params)
      end

    case socket.assigns.autosave do
      %Autosave{} = autosave ->
        user = socket.assigns.current_user

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Autosaves.add_file(autosave, user, upload_meta(entry), path)}
          end)

        held(socket, result)

      nil ->
        held(socket, {:error, "That image could not be stored."})
    end
  end

  defp held(socket, {:ok, %AutosaveFile{} = file}) do
    push_event(socket, "image_uploaded", %{
      upload: "page_image",
      markdown: "![#{file.filename}](#{Autosaves.file_url(file)})"
    })
  end

  defp held(socket, {:error, message}) do
    socket
    |> put_flash(:error, message)
    |> push_event("image_failed", %{upload: "page_image"})
  end

  defp uploaded(socket, {:ok, %Attachment{} = attachment}) do
    push_event(socket, "image_uploaded", %{
      upload: "page_image",
      markdown: "![#{attachment.filename}](#{Boards.attachment_url(attachment)})"
    })
  end

  defp uploaded(socket, _other) do
    socket
    |> put_flash(:error, "That image could not be stored.")
    |> push_event("image_failed", %{upload: "page_image"})
  end
end
