defmodule SlipdockWeb.WikiLive.HistoryView do
  @moduledoc """
  A wiki page's history (`WikiLive.Index`): its versions, each one's
  preview of what it changed, and one version shown against another.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents,
    only: [timestamp: 1]

  import SlipdockWeb.WikiLive.Format
  alias Slipdock.Wiki.LineChanges

  attr :board, :any, required: true
  attr :page, :any, required: true
  attr :revisions, :list, required: true
  attr :changes, :map, default: %{}, doc: "each revision's `Slipdock.Wiki.LineChanges`, by id"
  attr :previews, :map, default: %{}, doc: "the rows opened to show their lines, by id"

  # Each version links to what it changed; the two columns of radios pick any
  # pair to compare instead, older on the left whichever way they are ticked.
  def history_body(assigns) do
    assigns = assign(assigns, :compare?, length(assigns.revisions) > 1)

    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h1 class="page-title">History of {@page.title}</h1>
      <.link patch={page_path(@board, @page)} class="btn btn-ghost btn-sm">Back to the page</.link>
    </div>

    <form id="compare-form" phx-submit="compare" class="mt-6">
      <div :if={@compare?} class="mb-2 flex flex-wrap items-center justify-between gap-2">
        <p class="text-sm text-base-content/60">
          Tick two versions to see them side by side, or open one to see what it changed.
        </p>
        <button type="submit" class="btn btn-sm">Compare selected versions</button>
      </div>

      <.empty_state
        :if={@revisions == []}
        id="history-empty"
        icon="hero-clock"
        title="No versions yet"
      >
        Each time the page is saved, the version is kept here to compare or put back.
      </.empty_state>

      <ul
        :if={@revisions != []}
        class="divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100"
      >
        <li
          :for={{revision, i} <- Enum.with_index(@revisions)}
          id={"revision-row-#{revision.id}"}
        >
          <div class="flex items-center hover:bg-base-200">
            <%!-- Opens the row onto the lines this version changed (#1745),
                without leaving the list. --%>
            <button
              type="button"
              id={"revision-preview-toggle-#{revision.id}"}
              phx-click="history_preview"
              phx-value-id={revision.id}
              aria-expanded={to_string(Map.has_key?(@previews, revision.id))}
              aria-controls={"revision-preview-#{revision.id}"}
              title="Show the lines this version changed"
              aria-label={"Show the lines changed at #{stamp(revision.inserted_at)}"}
              class="group btn btn-ghost btn-xs btn-square ml-2 shrink-0"
            >
              <.icon
                name="hero-chevron-right"
                class="size-4 transition-transform group-aria-expanded:rotate-90"
              />
            </button>
            <span :if={@compare?} class="flex shrink-0 gap-2 pl-2">
              <input
                type="radio"
                name="from"
                value={revision.id}
                checked={i == 1}
                class="radio"
                aria-label={"Compare from #{stamp(revision.inserted_at)}"}
              />
              <input
                type="radio"
                name="to"
                value={revision.id}
                checked={i == 0}
                class="radio"
                aria-label={"Compare to #{stamp(revision.inserted_at)}"}
              />
            </span>
            <.link
              patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history/#{revision.id}"}
              class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-3 gap-y-1 px-4 py-3"
            >
              <span class="w-40 shrink-0 text-sm text-base-content/60"><.timestamp
                at={revision.inserted_at}
                format={:datetime}
              /></span>
              <span class="font-medium">{author_label(revision)}</span>
              <span :if={revision.via && revision.via != "web"} class="chip chip-line text-2xs">
                {via_label(revision.via)}{if revision.agent, do: " · #{revision.agent}"}
              </span>
              <span
                :if={revision.summary}
                class="min-w-0 flex-1 truncate text-sm text-base-content/60"
              >
                {revision.summary}
              </span>
              <span
                :if={@changes[revision.id]}
                id={"revision-changes-#{revision.id}"}
                class="shrink-0 text-xs text-base-content/50"
              >
                {LineChanges.label(@changes[revision.id])}
              </span>
            </.link>
          </div>
          <.revision_preview
            :if={@previews[revision.id]}
            id={"revision-preview-#{revision.id}"}
            preview={@previews[revision.id]}
            href={~p"/boards/#{@board}/wiki/#{@page.slug}/history/#{revision.id}"}
          />
        </li>
      </ul>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :preview, :map, required: true, doc: "`Slipdock.Wiki.LineChanges.preview/3`"
  attr :href, :string, required: true, doc: "the version's own page, for the rest"

  # The changed lines under a history row: removed in red with a −, added in
  # green with a +, as the revision view marks them.
  defp revision_preview(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="revision-preview"
      class="border-t border-base-300 bg-base-200/40 px-4 py-3"
    >
      <p :if={@preview.too_big?} class="text-sm text-base-content/60">
        Too long to show here. <.link patch={@href} class="link">Open the version</.link>
        to see what changed.
      </p>
      <p :if={!@preview.too_big? and @preview.lines == []} class="text-sm text-base-content/60">
        No lines changed.
      </p>
      <ul
        :if={@preview.lines != []}
        class="space-y-0.5 overflow-hidden rounded-lg font-mono text-xs leading-5"
      >
        <li
          :for={{op, line} <- @preview.lines}
          data-op={op}
          class={[
            "flex gap-2 px-2 whitespace-pre-wrap break-words",
            if(op == :ins, do: "bg-success/10", else: "bg-error/10")
          ]}
        >
          <span aria-hidden="true" class="shrink-0 select-none text-base-content/50">
            {if op == :ins, do: "+", else: "−"}
          </span>
          <span class="sr-only">{if op == :ins, do: "Added:", else: "Removed:"}</span>
          <span class="min-w-0">{line}</span>
        </li>
      </ul>
      <p :if={@preview.more > 0} class="mt-2 text-xs text-base-content/60">
        and {@preview.more} more {if @preview.more == 1, do: "line", else: "lines"}:
        <.link patch={@href} class="link">open the version</.link>
      </p>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :page, :any, required: true
  attr :revision, :any, default: nil
  attr :base, :any, default: nil
  attr :comparing, :boolean, default: false
  attr :latest, :any, default: nil
  attr :diff, :list, default: []
  attr :can_write, :boolean, required: true

  # GitHub's split view: the older version on the left, this one on the
  # right, with long unchanged stretches folded behind a button.
  def revision_body(assigns) do
    assigns =
      assign(assigns,
        changed?: Enum.any?(assigns.diff, &changed_row?/1),
        current?: assigns.latest && assigns.revision && assigns.latest.id == assigns.revision.id
      )

    ~H"""
    <div :if={is_nil(@revision)} class="py-16 text-center text-base-content/60">
      No such revision.
    </div>

    <div :if={@revision}>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 class="page-title">{@revision.title}</h1>
          <p class="mt-1 text-sm text-base-content/60">
            {stamp(@revision.inserted_at)} · {author_label(@revision)} {via_label(@revision.via)}
            <span :if={@revision.summary}>— {@revision.summary}</span>
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.link
            patch={~p"/boards/#{@board}/wiki/#{@page.slug}/history"}
            class="btn btn-ghost btn-sm"
          >
            All versions
          </.link>
          <.link
            :if={@latest && !@current?}
            patch={
              ~p"/boards/#{@board}/wiki/#{@page.slug}/history/#{@latest.id}?against=#{@revision.id}"
            }
            class="btn btn-ghost btn-sm"
          >
            Compare with current
          </.link>
          <button
            :if={@can_write}
            type="button"
            phx-click="revert"
            data-confirm="Put the page back to this version? The current text is kept in history."
            class="btn btn-sm"
          >
            Restore this version
          </button>
        </div>
      </div>

      <div id="split-diff" class="mt-6 overflow-x-auto rounded-xl border border-base-300 bg-base-100">
        <table class="w-full min-w-[40rem] table-fixed border-collapse font-mono text-xs">
          <colgroup>
            <col class="w-12" />
            <col />
            <col class="w-12" />
            <col />
          </colgroup>
          <thead class="border-b border-base-300 bg-base-200/60 font-sans text-left text-xs text-base-content/70">
            <tr>
              <th colspan="2" class="px-3 py-2 font-medium">
                <%= if @base do %>
                  {stamp(@base.inserted_at)} · {author_label(@base)}
                  <span :if={!@comparing} class="font-normal text-base-content/50">(the version before)</span>
                <% else %>
                  <span class="font-normal text-base-content/50">Nothing before this version</span>
                <% end %>
              </th>
              <th colspan="2" class="border-l border-base-300 px-3 py-2 font-medium">
                {stamp(@revision.inserted_at)} · {author_label(@revision)}
                <span :if={@current?} class="font-normal text-base-content/50">(current)</span>
              </th>
            </tr>
          </thead>
          <tbody :if={!@changed?}>
            <tr>
              <td colspan="4" class="px-3 py-2 font-sans text-base-content/60">
                No change between these two versions.
              </td>
            </tr>
          </tbody>
          <%= for {entry, i} <- Enum.with_index(@diff) do %>
            <%= case entry do %>
              <% {:row, left, right} -> %>
                <tbody>
                  <.diff_row left={left} right={right} />
                </tbody>
              <% {:fold, rows} -> %>
                <tbody id={"diff-fold-#{i}"}>
                  <tr>
                    <td colspan="4" class="bg-sky-500/5 p-0">
                      <button
                        type="button"
                        class="w-full px-3 py-1 text-left font-sans text-base-content/60 hover:bg-sky-500/10"
                        phx-click={
                          JS.hide(to: "#diff-fold-#{i}")
                          |> JS.show(to: "#diff-folded-#{i}", display: "table-row-group")
                        }
                      >
                        ⋯ {count(length(rows), "unchanged line")}
                      </button>
                    </td>
                  </tr>
                </tbody>
                <tbody id={"diff-folded-#{i}"} class="hidden">
                  <.diff_row :for={{:row, left, right} <- rows} left={left} right={right} />
                </tbody>
            <% end %>
          <% end %>
        </table>
      </div>
    </div>
    """
  end

  attr :left, :any, required: true
  attr :right, :any, required: true

  defp diff_row(assigns) do
    ~H"""
    <tr>
      <.diff_cell cell={@left} />
      <.diff_cell cell={@right} edge />
    </tr>
    """
  end

  attr :cell, :any, required: true
  attr :edge, :boolean, default: false

  # The text is pre-wrapped, so its cell is kept on one line: any template
  # whitespace inside it would show up in the diff.
  defp diff_cell(assigns) do
    ~H"""
    <td class={[
      "select-none px-2 py-0.5 text-right align-top text-base-content/40",
      @edge && "border-l border-base-300",
      @cell && @cell.op == :del && "bg-rose-500/15",
      @cell && @cell.op == :ins && "bg-emerald-500/15",
      is_nil(@cell) && "bg-base-200/60"
    ]}>
      {@cell && @cell.n}
    </td>
    <td
      data-op={@cell && @cell.op}
      class={[
        "whitespace-pre-wrap break-words px-2 py-0.5 align-top",
        @cell && @cell.op == :del && "bg-rose-500/10 text-rose-950 dark:text-rose-100",
        @cell && @cell.op == :ins && "bg-emerald-500/10 text-emerald-950 dark:text-emerald-100",
        @cell && @cell.op == :eq && "text-base-content/70",
        is_nil(@cell) && "bg-base-200/60"
      ]}
      phx-no-format
    ><span :if={@cell && @cell.op != :eq} class="sr-only">{if @cell.op == :del, do: "removed: ", else: "added: "}</span><%= if @cell do %><span :for={{kind, text} <- @cell.parts} class={kind == :chg && diff_word(@cell.op)}>{text}</span><% end %></td>
    """
  end

  defp changed_row?({:row, %{op: :eq}, %{op: :eq}}), do: false
  defp changed_row?({:row, _, _}), do: true
  defp changed_row?(_), do: false

  defp diff_word(:del), do: "diff-word rounded-sm bg-rose-500/30"
  defp diff_word(_), do: "diff-word rounded-sm bg-emerald-500/30"
end
