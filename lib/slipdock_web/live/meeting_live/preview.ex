defmodule SlipdockWeb.MeetingLive.Preview do
  @moduledoc """
  The commit preview (screen 7): exactly what committing will write, grouped
  by where it lands — new cards by list, changes to cards as before → after,
  comments, the lines added to and struck on decisions pages — and what
  follows from it (who is told, what slips), what is left out, and whether
  anything has moved since the review read it.

  It renders the change set `Slipdock.Meetings.Commit.build/1` makes, and
  commits with that change set's digest, so the commit refuses if the
  review has changed since this page was drawn (G6).
  """
  use SlipdockWeb, :live_view

  import SlipdockWeb.MeetingLive.Components

  alias Slipdock.Meetings
  alias Slipdock.Meetings.{Commit, Describe}
  alias SlipdockWeb.MeetingLive.Access

  on_mount {SlipdockWeb.MeetingsHook, :require_enabled}

  @impl true
  def mount(%{"id" => id, "capture_id" => capture_id}, _session, socket) do
    with {:ok, socket} <- Access.mount_board(socket, id, :write),
         %Meetings.Capture{} = capture <- capture(capture_id, socket.assigns.board) do
      if connected?(socket), do: Meetings.subscribe(capture)

      {:ok,
       socket |> assign(page_title: "Commit · #{capture.title}", error: nil) |> load(capture)}
    else
      {:error, socket} ->
        {:ok, socket}

      nil ->
        {:ok, push_navigate(socket, to: ~p"/boards/#{socket.assigns.board}/meetings")}
    end
  end

  defp capture(id, board) do
    with id when is_integer(id) <- SlipdockWeb.Params.id(id),
         %Meetings.Capture{board_id: board_id} = c when board_id == board.id <-
           Meetings.get_capture(id) do
      c
    else
      _ -> nil
    end
  end

  defp load(socket, capture) do
    set = Commit.build(capture)

    assign(socket,
      capture: capture,
      set: Slipdock.Meetings.Visibility.change_set(set, socket.assigns.current_user),
      stale: Commit.stale(set)
    )
  end

  @impl true
  def handle_info({:capture_changed, id}, socket),
    do: {:noreply, load(socket, Meetings.get_capture!(id))}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("commit", %{"digest" => digest}, socket) do
    %{capture: capture, board: board, current_user: user} = socket.assigns

    case Commit.commit(capture, user, digest: digest, via: "web") do
      {:ok, capture} ->
        {:noreply,
         socket
         |> put_flash(:info, "Committed. Everything it wrote can be undone from here.")
         |> push_navigate(to: ~p"/boards/#{board}/meetings/#{capture.id}")}

      {:error, :stale, targets} ->
        {:noreply,
         socket
         |> assign(error: "Something moved since the review read it. Nothing was written.")
         |> load(capture)}
        |> then(fn {:noreply, s} -> {:noreply, assign(s, stale: targets)} end)

      {:error, _kind, message} ->
        {:noreply, socket |> assign(error: message) |> load(Meetings.get_capture!(capture.id))}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  defp by_op(set, op), do: Enum.filter(set["changes"], &(&1["op"] == op))

  defp value(nil), do: "—"
  defp value(true), do: "yes"
  defp value(false), do: "no"

  defp value(list) when is_list(list),
    do: if(list == [], do: "nobody", else: Enum.join(list, ", "))

  defp value(v) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, _} -> Describe.date(v)
      _ -> v
    end
  end

  defp value(v), do: to_string(v)

  defp field_label("due_date"), do: "Due"
  defp field_label("start_date"), do: "Starts"
  defp field_label("assignee_ids"), do: "Assigned"
  defp field_label("completed"), do: "Done"
  defp field_label("list"), do: "List"
  defp field_label(f), do: f |> String.replace("_", " ") |> String.capitalize()

  # Assignees are shown by name, not id.
  defp shown("assignee_ids", ids) when is_list(ids) do
    Commit.names(ids)
  end

  defp shown(_field, v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:boards}
      page_jumps={@page_jumps}
    >
      <:subnav><.meeting_nav board={@board} capture={@capture} /></:subnav>

      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-5 p-4 sm:p-6">
          <header class="flex flex-wrap items-center gap-3">
            <h1 class="flex-1 text-xl font-semibold">What committing will write</h1>
            <.link
              navigate={~p"/boards/#{@board}/meetings/#{@capture.id}"}
              class="btn btn-ghost btn-sm"
            >
              Back to the review
            </.link>
          </header>

          <p
            :if={@error}
            id="commit-error"
            role="alert"
            class="rounded-xl bg-error/10 px-4 py-2 text-sm text-error"
          >
            {@error}
          </p>

          <section
            id="stale-check"
            class={[
              "rounded-xl px-4 py-3 text-sm",
              @stale == [] && "bg-success/10",
              @stale != [] && "bg-error/10"
            ]}
          >
            <p :if={@stale == []}>
              <.icon name="hero-check-circle" class="size-4 text-success" />
              Everything is as the review read it.
            </p>
            <div :if={@stale != []}>
              <p class="font-medium">
                These changed since the review read them, so nothing will be written over them:
              </p>
              <ul class="mt-1 list-disc pl-5">
                <li :for={t <- @stale} data-stale={t["ref"] || t["title"]}>
                  {t["ref"]} “{t["title"]}”: {t["why"]}
                </li>
              </ul>
            </div>
          </section>

          <section
            :if={by_op(@set, "create_card") != []}
            id="preview-new-cards"
            class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
          >
            <h2 class="text-sm font-medium">New cards</h2>
            <ul class="mt-2 space-y-1 text-sm">
              <li :for={c <- by_op(@set, "create_card")} id={"change-#{c["id"]}"}>
                <span class="badge badge-ghost badge-xs">{c["list"]}</span>
                <span class="font-medium">{c["title"]}</span>
                <span :if={c["assignees"] != []} class="text-base-content/60">· {Enum.join(
                  c["assignees"],
                  ", "
                )}</span>
                <span :if={c["due_date"]} class="text-base-content/60">· due {Describe.date(
                  c["due_date"]
                )}</span>
              </li>
            </ul>
          </section>

          <section
            :if={by_op(@set, "update_card") != []}
            id="preview-changes"
            class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
          >
            <h2 class="text-sm font-medium">Changes to cards</h2>
            <div :for={c <- by_op(@set, "update_card")} id={"change-#{c["id"]}"} class="mt-2 text-sm">
              <p class="font-medium">{c["ref"]} {c["title"]}</p>
              <table class="table table-xs mt-1">
                <tbody>
                  <tr :for={{field, d} <- c["fields"]} :if={field != "column_id"}>
                    <td class="w-24 text-base-content/60">{field_label(field)}</td>
                    <td class="text-base-content/60 line-through">
                      {value(shown(field, d["from"]))}
                    </td>
                    <td>→ {value(shown(field, d["to"]))}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section
            :if={by_op(@set, "comment") != []}
            id="preview-comments"
            class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
          >
            <h2 class="text-sm font-medium">Comments</h2>
            <div :for={c <- by_op(@set, "comment")} id={"change-#{c["id"]}"} class="mt-2 text-sm">
              <p class="text-base-content/60">on {c["ref"]} {c["title"]}</p>
              <p class="whitespace-pre-line">{c["body"]}</p>
            </div>
          </section>

          <section
            :if={by_op(@set, "decision_entry") != []}
            id="preview-wiki"
            class="rounded-xl bg-base-100 p-4 ring-1 ring-base-content/10"
          >
            <h2 class="text-sm font-medium">The meeting's page</h2>
            <div
              :for={c <- by_op(@set, "decision_entry")}
              id={"change-#{c["id"]}"}
              class="mt-2 text-sm"
            >
              <p class="font-medium">
                {c["page_title"]}
                <span :if={is_nil(c["page_id"])} class="badge badge-ghost badge-xs">new page</span>
              </p>
              <%!-- A new page is shown whole, exactly as it will be written
                   (header, summary, topics, headings); a page already there
                   as the lines it gains and loses. --%>
              <pre
                :if={is_nil(c["page_id"])}
                id={"page-#{c["id"]}"}
                class="mt-1 overflow-x-auto whitespace-pre-wrap rounded bg-base-200 p-2 font-mono text-xs"
              >{c["body_after"]}</pre>
              <pre
                :if={c["page_id"]}
                class="mt-1 overflow-x-auto whitespace-pre-wrap rounded bg-base-200 p-2 font-mono text-xs"
              ><span :for={l <- c["lines_struck"]} class="block text-error">- {l}</span><span :for={l <- c["lines_added"]} class="block text-success">+ {l}</span></pre>
            </div>
          </section>

          <section
            :if={@set["knock_on"] != []}
            id="preview-knock-on"
            class="rounded-xl bg-warning/10 p-4 text-sm"
          >
            <h2 class="font-medium">Knock-on</h2>
            <ul class="mt-1 list-disc pl-5">
              <li :for={k <- @set["knock_on"]}>{k["ref"]} “{k["title"]}” {k["why"]}</li>
            </ul>
          </section>

          <section :if={@set["notify"] != []} id="preview-notify" class="text-sm text-base-content/70">
            <h2 class="font-medium text-base-content">Who hears about it</h2>
            <ul class="mt-1 list-disc pl-5">
              <li :for={n <- @set["notify"]}>{n["who"]}: {n["why"]} (as their board's rules say)</li>
            </ul>
          </section>

          <section
            :if={@set["left_out"] != []}
            id="preview-left-out"
            class="text-sm text-base-content/60"
          >
            <h2 class="font-medium text-base-content/80">Left out</h2>
            <ul class="mt-1 list-disc pl-5">
              <li :for={l <- @set["left_out"]}>{l["title"]} — {l["why"]}</li>
            </ul>
          </section>

          <form
            :if={@capture.state == "ready"}
            id="commit-form"
            phx-submit="commit"
            class="flex items-center justify-end gap-3"
          >
            <input type="hidden" name="digest" value={@set["digest"]} />
            <span class="text-xs text-base-content/50">One write, which can be undone as a whole.</span>
            <button
              type="submit"
              id="commit-now"
              class="btn btn-primary"
              disabled={@stale != [] or @set["changes"] == []}
            >
              Commit {length(@set["changes"])} {if length(@set["changes"]) == 1,
                do: "change",
                else: "changes"}
            </button>
          </form>
          <p :if={not Commit.committable?(@capture)} class="text-sm text-base-content/60">
            This capture is {state_label(@capture.state)}, so it can't be committed from here.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
