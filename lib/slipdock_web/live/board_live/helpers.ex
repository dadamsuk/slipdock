defmodule SlipdockWeb.BoardLive.Helpers do
  @moduledoc """
  Small pure helpers shared by the board LiveView and its components:
  formatting, parsing what a form posted, and turning a changeset into words.
  """

  import Phoenix.Component, only: [upload_errors: 2]
  alias SlipdockWeb.Dates
  import Phoenix.LiveView, only: [cancel_upload: 3, push_event: 3]

  alias Slipdock.Boards.Attachment

  # Images pasted or dropped into a card's description, a comment or a wiki
  # page: the PasteImage hook is told when one fails, so it can take its
  # placeholder out again.
  @image_uploads [:desc_image, :comment_image, :page_image]

  @doc """
  A flash from one of the board's LiveComponents. A component's own
  `put_flash/3` only reaches the page when it also redirects, so the board's
  components hand theirs to the LiveView they run in, which shows it.
  """
  def flash(socket, kind, message) do
    send(self(), {:put_flash, kind, message})
    socket
  end

  @doc """
  What a panel action says (a refusal, a result), for the panel that ran it
  to show at its top as a `<.callout>` (`SlipdockWeb.ItemComponents.panel_notice/1`),
  never a flash: a toast's dismissal reads as a click-away and closes the
  modal (UX-29). The card and page panels clear it at the next event.
  """
  def notice(socket, kind, message) when kind in [:info, :error],
    do: Phoenix.Component.assign(socket, panel_notice: {kind, message})

  @doc "Takes the last action's notice off the panel, before the next action runs."
  def clear_notice(socket), do: Phoenix.Component.assign(socket, panel_notice: nil)

  # The marker the PasteImage hook leaves while an image is still uploading;
  # never worth keeping if the text is saved before the upload finishes.
  @upload_placeholder "![Uploading image…]()"

  def changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"
    end)
  end

  def strip_upload_placeholder(nil), do: nil

  def strip_upload_placeholder(text),
    do:
      text
      |> String.replace(@upload_placeholder <> "\n", "")
      |> String.replace(@upload_placeholder, "")

  def human_size(bytes) when bytes < 1024, do: "#{bytes} B"

  def human_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  def human_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  def attachment_icon(%Attachment{} = a) do
    case Attachment.kind(a) do
      :pdf -> "hero-document-text"
      :audio -> "hero-musical-note"
      :text -> "hero-document-text"
      :archive -> "hero-archive-box"
      :sheet -> "hero-table-cells"
      :doc -> "hero-document"
      _ -> "hero-paper-clip"
    end
  end

  # "Small=1, Large=3" → option maps; a bare label has no weight.
  def parse_options(nil), do: []

  def parse_options(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(fn item ->
      case String.split(item, "=", parts: 2) do
        [label, weight] -> %{"label" => String.trim(label), "weight" => String.trim(weight)}
        [label] -> %{"label" => String.trim(label)}
      end
    end)
    |> Enum.reject(&(&1["label"] == ""))
  end

  def field_errors(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {k, msgs} -> "#{k} #{Enum.join(List.wrap(msgs), ", ")}" end)
  end

  def view_error(%Ecto.Changeset{} = cs) do
    case cs.errors[:name] do
      {msg, _} -> "View name #{msg}."
      nil -> "Couldn't save that view."
    end
  end

  def toggle(current, value), do: if(current == value, do: nil, else: value)

  def assignee_options(users, nil), do: users

  def assignee_options(users, id) do
    if Enum.any?(users, &(&1.id == id)),
      do: users,
      else: users ++ List.wrap(Slipdock.Accounts.get_user(id))
  end

  @doc "`value` as an integer, or nil: `SlipdockWeb.Params.int/1`, so `\"12abc\"` is nil."
  defdelegate to_int(value), to: SlipdockWeb.Params, as: :int

  def tag_by_id(board, id), do: Enum.find(board.tags, &(&1.id == id))

  def column_options(board), do: Enum.map(board.columns, &{&1.name, &1.id})

  def column_name(board, id) do
    case Enum.find(board.columns, &(&1.id == id)) do
      nil -> ""
      col -> col.name
    end
  end

  # One icon set for the kinds of change in the activity log (#1735): the
  # entry's kind when it says enough, else the verb its message opens with.
  @activity_kind_icons %{
    "comment" => "hero-chat-bubble-left",
    "vote" => "hero-hand-thumb-up",
    "checklist" => "hero-list-bullet",
    "link" => "hero-link",
    "wait" => "hero-clock",
    "handoff" => "hero-arrow-path-rounded-square",
    "milestone" => "hero-flag",
    "view" => "hero-bookmark",
    "automation" => "hero-bolt",
    "release" => "hero-rocket-launch",
    "column" => "hero-view-columns",
    "page_created" => "hero-document-plus",
    "page_updated" => "hero-pencil-square",
    "page_moved" => "hero-arrows-right-left",
    "folder_moved" => "hero-arrows-right-left",
    "page_archived" => "hero-archive-box",
    "page_restored" => "hero-arrow-uturn-left",
    "page_deleted" => "hero-trash",
    "page_published" => "hero-globe-alt",
    "page_unpublished" => "hero-eye-slash",
    "page_placed" => "hero-document-text",
    "page_unplaced" => "hero-document-text"
  }

  @activity_verb_icons %{
    "moved" => "hero-arrows-right-left",
    "added" => "hero-plus",
    "created" => "hero-plus",
    "wrote" => "hero-document-plus",
    "edited" => "hero-pencil-square",
    "renamed" => "hero-pencil-square",
    "changed" => "hero-pencil-square",
    "set" => "hero-pencil-square",
    "updated" => "hero-pencil-square",
    "archived" => "hero-archive-box",
    "restored" => "hero-arrow-uturn-left",
    "deleted" => "hero-trash",
    "removed" => "hero-trash",
    "finished" => "hero-check-circle",
    "completed" => "hero-check-circle",
    "commented" => "hero-chat-bubble-left",
    "voted" => "hero-hand-thumb-up",
    "snoozed" => "hero-moon",
    "started" => "hero-clock",
    "logged" => "hero-clock"
  }

  @activity_fallback_icons %{
    "card" => "hero-rectangle-stack",
    "board" => "hero-squares-2x2",
    "page" => "hero-document-text"
  }

  @doc "The icon for an activity entry of `kind` whose message is `message`."
  def activity_icon(kind, message \\ nil) do
    @activity_kind_icons[kind] || verb_icon(message) || @activity_fallback_icons[kind] ||
      "hero-sparkles"
  end

  defp verb_icon(message) when is_binary(message) do
    case String.split(message, " ", parts: 2) do
      [verb | _] -> @activity_verb_icons[verb]
      _ -> nil
    end
  end

  defp verb_icon(_), do: nil

  def fmt_date(nil), do: "—"

  def fmt_date(%Date{} = d), do: Dates.long(d)

  def checklist_progress(items) do
    total = length(items)
    done = Enum.count(items, & &1.done)
    {done, total, if(total == 0, do: 0, else: round(done / total * 100))}
  end

  def url_error(changeset) do
    case changeset.errors do
      [{_field, {message, _}} | _] -> message
      [] -> "could not be added"
    end
  end

  @doc """
  Drops the entries of upload `name` that can't be taken (too big, wrong
  type) straight away, and says so once, instead of leaving them in the list.
  Works in the board LiveView and in its components alike.
  """
  def drop_invalid_uploads(socket, name) do
    upload = socket.assigns.uploads[name]

    Enum.reduce(upload.entries, socket, fn entry, socket ->
      case upload_errors(upload, entry) do
        [] ->
          socket

        [err | _] ->
          socket
          |> cancel_upload(name, entry.ref)
          |> flash(:error, "#{entry.client_name} #{upload_error(err)}.")
          |> image_failed(name)
      end
    end)
  end

  @doc "Tells the PasteImage hook an image upload came to nothing."
  def image_failed(socket, name) when name in @image_uploads,
    do: push_event(socket, "image_failed", %{upload: Atom.to_string(name)})

  def image_failed(socket, _name), do: socket

  defp upload_error(:too_large), do: "is too large"
  defp upload_error(:not_accepted), do: "isn't an image (PNG, JPEG, GIF or WebP)"
  defp upload_error(:too_many_files), do: "couldn't be added: too many files at once"
  defp upload_error(:external_client_failure), do: "failed to upload"
  defp upload_error(other), do: "couldn't be uploaded (#{other})"
end
