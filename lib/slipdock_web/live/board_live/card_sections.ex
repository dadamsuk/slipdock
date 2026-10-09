defmodule SlipdockWeb.BoardLive.CardSections do
  @moduledoc """
  The card panel's markup, part two: subcards, dependencies, docs and links.
  The panel is `BoardLive.CardComponent`; these draw what it holds, and send
  their events to it (`target`). Part one is `BoardLive.CardPanel`.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.Palette
  alias Slipdock.Boards.{Board, Card, CardLink}

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :form_key, :integer, required: true
  attr :picking_template, :boolean, required: true
  attr :target, :any, required: true
  attr :templates, :list, required: true

  @doc "The card's subcards board: progress, its lists and adding to them, or making one."
  def subcards_section(assigns) do
    ~H"""
    <section class="space-y-2 px-1" data-section-key="s">
      <div class="flex items-center justify-between">
        <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          <.icon name="hero-squares-2x2" class="size-3.5" />
          <.keyed_label key="s" label="Subcards" />
        </h3>
        <div class="flex items-center gap-1.5">
          <button
            :if={@can_write and Board.sprints?(@board)}
            id="card-sprint-add-cards"
            type="button"
            class="btn btn-xs"
            phx-click="open_sprint_picker"
            phx-target="#board-sprints"
            phx-value-id={@card.id}
            title="Pick cards from your boards to add to this sprint"
          >
            <.icon name="hero-queue-list" class="size-3.5" /> Add cards…
          </button>
          <.link
            :if={@card.sub_board}
            navigate={~p"/boards/#{@card.sub_board.id}"}
            class="btn btn-xs btn-primary"
          >
            Open board <.icon name="hero-arrow-right" class="size-3.5" />
          </.link>
        </div>
      </div>

      <%= if @card.sub_board do %>
        <div
          :for={{done, total} <- [Card.progress(@card)]}
          class="flex items-center gap-2 text-xs text-base-content/60"
        >
          <progress
            class={[
              "progress h-1.5 flex-1",
              if(total > 0 and done == total,
                do: "progress-success",
                else: "progress-primary"
              )
            ]}
            value={done}
            max={max(total, 1)}
          ></progress>
          <span>{done}/{total} done</span>
          <span
            :if={@card.rollup && @card.rollup.depth > 1}
            title="Counting every level beneath this card"
          >
            · {@card.rollup.depth} levels
          </span>
          <.health_pill health={Card.health(@card)} />
        </div>
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div :for={col <- @card.sub_board.columns} class="rounded-xl bg-base-200/60 p-2">
            <p class="mb-1 flex items-center gap-1.5 px-1 text-xs font-semibold">
              <span :if={col.color} class={["size-2 rounded-full", Palette.dot(col.color)]}></span>
              {col.name}
              <span class="ml-auto font-mono text-2xs text-base-content/50">{Enum.count(
                @card.sub_board.cards,
                &(&1.column_id == col.id)
              )}</span>
            </p>
            <ul class="space-y-0.5">
              <li
                :for={sub <- Enum.filter(@card.sub_board.cards, &(&1.column_id == col.id))}
                id={"subcard-#{sub.id}"}
                class="flex items-center gap-1.5 rounded px-1 py-0.5 text-sm hover:bg-base-100/60"
              >
                <button
                  phx-target={@target}
                  type="button"
                  phx-click="toggle_subcard"
                  phx-value-id={sub.id}
                  class={
                    if(sub.completed,
                      do: "text-success",
                      else: "text-base-content/30 hover:text-success"
                    )
                  }
                  title="Toggle complete"
                >
                  <.icon
                    name={
                      if sub.completed,
                        do: "hero-check-circle-solid",
                        else: "hero-check-circle"
                    }
                    class="size-4"
                  />
                </button>
                <.link
                  navigate={~p"/boards/#{@card.sub_board.id}/cards/#{sub.id}"}
                  class={[
                    "truncate hover:underline",
                    sub.completed && "text-base-content/50"
                  ]}
                >
                  {sub.title}
                </.link>
              </li>
            </ul>
            <form
              phx-target={@target}
              id={"add-subcard-#{col.id}-#{@form_key}"}
              phx-submit="quick_add_subcard"
              class="mt-1"
            >
              <input type="hidden" name="column_id" value={col.id} />
              <input
                type="text"
                name="title"
                placeholder="Add a subcard…"
                class="input input-xs w-full"
                autocomplete="off"
                required
              />
            </form>
          </div>
        </div>
        <button
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-xs text-error"
          phx-click="delete_sub_board"
          data-confirm="Remove all subcards of this card? This deletes them permanently."
        >
          <.icon name="hero-trash" class="size-3.5" /> Remove subcards
        </button>
      <% else %>
        <p class="text-xs text-base-content/50">
          Turn this card into a board of its own. Pick a template for its lists.
        </p>
        <button
          :if={!@picking_template}
          phx-target={@target}
          type="button"
          class="btn btn-sm"
          phx-click="pick_template"
        >
          <.icon name="hero-squares-plus" class="size-4" /> Add subcards
        </button>
        <div
          :if={@picking_template}
          class="kanban-pop space-y-1 rounded-xl bg-base-200/60 p-2"
        >
          <button
            :for={t <- @templates}
            phx-target={@target}
            type="button"
            class="flex w-full items-start gap-2 rounded-lg px-2 py-1.5 text-left hover:bg-base-100"
            phx-click="create_sub_board"
            phx-value-template={t.id}
          >
            <.icon name="hero-view-columns" class="mt-0.5 size-4 shrink-0 text-primary" />
            <span class="min-w-0">
              <span class="block text-sm font-medium">{t.name}</span>
              <span class="block truncate text-xs text-base-content/50">{Enum.map_join(
                t.columns,
                " · ",
                & &1["name"]
              )}</span>
            </span>
          </button>
          <p :if={@templates == []} class="px-2 text-xs text-base-content/50">
            No templates yet.
          </p>
          <div class="flex items-center justify-between px-1 pt-1">
            <.link navigate={~p"/templates"} class="text-xs text-primary hover:underline">Manage templates</.link>
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="pick_template"
            >Cancel</button>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :card_link, :any, required: true
  attr :dep_direction, :string, required: true
  attr :dep_query, :string, required: true
  attr :dep_results, :list, required: true
  attr :form_key, :integer, required: true
  attr :target, :any, required: true

  @doc "What the card waits for and what waits for it, and finding more."
  def dependencies_section(assigns) do
    ~H"""
    <section :if={not @board.simple} class="space-y-2 px-1" data-section-key="p">
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        <.icon name="hero-link" class="size-3.5" />
        <.keyed_label key="p" label="Dependencies" />
      </h3>
      <div
        :for={
          {label, cards, icon} <- [
            {"Blocked by", @card.blocked_by, "hero-lock-closed"},
            {"Blocks", @card.blocks, "hero-arrow-right-circle"}
          ]
        }
        :if={cards != []}
        class="space-y-1"
      >
        <p class="text-xs text-base-content/60">{label}</p>
        <ul class="space-y-1">
          <li
            :for={dep <- cards}
            id={"dep-#{label == "Blocks" && "blocks" || "by"}-#{dep.id}"}
            class="group flex items-center gap-2 rounded-lg px-1 py-1 hover:bg-base-200/60"
          >
            <.icon
              name={if dep.completed, do: "hero-check-circle-solid", else: icon}
              class={[
                "size-4 shrink-0",
                if(dep.completed, do: "text-success", else: "text-error")
              ]}
            />
            <span
              :if={dep.hidden}
              class="min-w-0 flex-1 truncate text-sm italic text-base-content/50"
              title="It is on a board you can't see"
            >
              {dep.title}
            </span>
            <.link
              :if={not dep.hidden}
              patch={if dep.board_id == @board.id, do: @card_link.(dep.id)}
              navigate={if dep.board_id != @board.id, do: ~p"/boards/#{dep.board_id}/cards/#{dep.id}"}
              class={[
                "min-w-0 flex-1 truncate text-sm hover:underline",
                dep.completed && "text-base-content/50"
              ]}
            >
              {dep.title}
            </.link>
            <span
              :if={not dep.hidden and dep.board_id != @board.id and match?(%{code: _}, dep.board)}
              class="max-w-32 shrink-0 truncate text-2xs text-base-content/50"
              title={"On board #{dep.board.name}"}
            >
              {dep.board.code}
            </span>
            <span :if={dep.archived_at} class="badge badge-ghost badge-xs">archived</span>
            <button
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100 no-hover:opacity-100"
              phx-click="remove_dependency"
              phx-value-id={dep.id}
              title="Remove dependency"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </li>
        </ul>
      </div>
      <form
        phx-target={@target}
        id={"dep-search-#{@form_key}"}
        phx-change="dep_search"
        phx-submit="dep_search"
        class="space-y-1.5"
      >
        <div class="flex items-center gap-1">
          <div class="join">
            <button
              :for={{value, label} <- [{"blocked_by", "Blocked by"}, {"blocks", "Blocks"}]}
              phx-target={@target}
              type="button"
              class={[
                "btn btn-xs join-item",
                if(@dep_direction == value, do: "btn-neutral", else: "btn-ghost")
              ]}
              phx-click="dep_direction"
              phx-value-direction={value}
            >
              {label}
            </button>
          </div>
          <input
            type="search"
            name="q"
            value={@dep_query}
            placeholder={
              if @dep_direction == "blocked_by",
                do: "Find the card this one waits for…",
                else: "Find the card this one holds up…"
            }
            class="input input-sm flex-1"
            phx-debounce="200"
            autocomplete="off"
          />
        </div>
        <ul :if={@dep_results != []} class="menu menu-sm rounded-xl bg-base-200/70 p-1">
          <li :for={result <- @dep_results}>
            <button
              phx-target={@target}
              type="button"
              phx-click="add_dependency"
              phx-value-id={result.id}
            >
              <.icon name="hero-plus" class="size-3.5" />
              <span class={result.completed && "opacity-60"}>{result.title}</span>
              <span :if={result.board_id == @board.id} class="ml-auto text-xs opacity-50">
                {column_name(@board, result.column_id)}
              </span>
              <span
                :if={result.board_id != @board.id}
                class="ml-auto shrink-0 text-2xs opacity-50"
                title={"On board #{result.board.name}"}
              >
                {result.board.code}
              </span>
            </button>
          </li>
        </ul>
        <p
          :if={@dep_query != "" and @dep_results == []}
          class="px-1 text-xs text-base-content/50"
        >
          No other cards match.
        </p>
      </form>
    </section>
    """
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :doc_query, :string, default: ""
  attr :doc_results, :list, default: []
  attr :pages, :list, default: []
  attr :target, :any, required: true

  @doc "The wiki pages that talk about the card, pinned first, and attaching more."
  def docs_section(assigns) do
    ~H"""
    <%!-- Docs: the wiki pages that talk about this card. A pinned page
          is *the* spec, runbook or retro for it, which is a person's
          judgement rather than something the prose says — so it leads,
          and it survives whoever next edits the page. --%>
    <section class="space-y-2 px-1" id="card-docs" data-section-key="o">
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        <.icon name="hero-document-text" class="size-3.5" />
        <.keyed_label key="o" label="Docs" />
      </h3>
      <ul :if={@pages != []} class="space-y-1">
        <li
          :for={link <- @pages}
          id={"card-doc-#{link.id}"}
          class="group flex items-center gap-2 text-sm"
        >
          <.icon
            name={if link.pinned, do: "hero-bookmark-solid", else: "hero-document-text"}
            class={[
              "size-4 shrink-0",
              if(link.pinned, do: "text-primary", else: "text-base-content/40")
            ]}
          />
          <.link
            navigate={~p"/boards/#{link.page.board_id}/wiki/#{link.page.slug}"}
            class="min-w-0 flex-1 truncate hover:underline"
            title={link.page.summary || link.page.title}
          >
            {link.page.title}
          </.link>
          <span class="shrink-0 font-mono text-2xs text-base-content/40">{link.page.code}</span>
          <button
            :if={@can_write}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="toggle_pin_doc"
            phx-value-page={link.page.id}
            title={if link.pinned, do: "Unpin this doc", else: "Pin: this is the doc for this card"}
          >
            <.icon
              name={if link.pinned, do: "hero-bookmark-slash", else: "hero-bookmark"}
              class="size-3.5"
            />
          </button>
          <%!-- Only a link the prose does not make can be taken off
                here: a page that really names this card keeps saying
                so (see `Slipdock.Wiki.Links.unlink/2`). --%>
          <button
            :if={@can_write and link.count == 0}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="detach_doc"
            phx-value-page={link.page.id}
            title="Detach this doc"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </li>
      </ul>
      <p :if={@pages == []} class="text-xs text-base-content/50">
        Nothing written about this card yet.
      </p>
      <div :if={@can_write} class="flex flex-wrap items-center gap-1">
        <button
          phx-target={@target}
          type="button"
          class="btn btn-ghost btn-xs gap-1"
          phx-click="write_up"
        >
          <.icon name="hero-pencil-square" class="size-3.5" /> Write it up
        </button>
        <.link navigate={~p"/boards/#{@board}/wiki"} class="btn btn-ghost btn-xs">
          Open the wiki
        </.link>
      </div>
      <%!-- Most of the time the document already exists and what is
            missing is the link to it. --%>
      <form
        :if={@can_write}
        phx-target={@target}
        id="card-doc-search"
        phx-change="doc_search"
        phx-submit="doc_search"
        class="relative"
      >
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-base-content/40"
        />
        <input
          type="search"
          name="q"
          value={@doc_query}
          placeholder="Attach a page already written…"
          phx-debounce="200"
          autocomplete="off"
          class="input input-xs w-full rounded-full pl-7"
        />
      </form>
      <ul :if={@doc_results != []} class="space-y-0.5">
        <li :for={page <- @doc_results}>
          <button
            phx-target={@target}
            type="button"
            phx-click="attach_doc"
            phx-value-page={page.id}
            class="flex w-full items-center gap-1.5 rounded-lg px-1.5 py-1 text-left text-xs hover:bg-base-200"
          >
            <.icon name="hero-plus" class="size-3 shrink-0 text-base-content/40" />
            <span class="min-w-0 flex-1 truncate">{page.title}</span>
            <span class="shrink-0 font-mono text-2xs text-base-content/40">{page.code}</span>
          </button>
        </li>
      </ul>
    </section>
    """
  end

  attr :can_write, :boolean, required: true
  attr :jobs, :list, required: true
  attr :target, :any, required: true

  @doc """
  The runner jobs automation rules have sent this card on, newest first:
  where each stands, who took it, the end of its log, and a way to stop it.
  """
  def jobs_section(assigns) do
    ~H"""
    <section class="space-y-2 px-1" id="card-jobs">
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        <.icon name="hero-cpu-chip" class="size-3.5" /> Runner jobs
      </h3>
      <ul class="space-y-1.5">
        <li
          :for={job <- @jobs}
          id={"card-job-#{job.id}"}
          class="rounded-lg border border-base-300 px-2 py-1.5 text-xs"
        >
          <div class="flex items-center gap-2">
            <span class={["badge badge-xs", job_badge(job.status)]}>{job.status}</span>
            <span class="font-mono text-base-content/50">#{job.id}</span>
            <span class="min-w-0 flex-1 truncate text-base-content/70">
              {job.pool} · {job.kind}{if job.runner_name, do: " · #{job.runner_name}"}
            </span>
            <span class="shrink-0 text-base-content/50" title={to_string(job.inserted_at)}>
              {job_time(job)}
            </span>
            <button
              :if={@can_write and Slipdock.Runners.Job.open?(job) and is_nil(job.cancel_requested_at)}
              phx-target={@target}
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="cancel_job"
              phx-value-job={job.id}
              title="Stop this job"
            >
              Cancel
            </button>
            <span
              :if={job.cancel_requested_at && Slipdock.Runners.Job.open?(job)}
              class="text-warning"
            >
              stopping…
            </span>
          </div>
          <p :if={job.error} class="mt-1 text-error">{job.error}</p>
          <pre
            :if={tail = job_log(job)}
            class="mt-1 max-h-32 overflow-auto whitespace-pre-wrap rounded bg-base-200 p-1.5 font-mono text-2xs"
          >{tail}</pre>
        </li>
      </ul>
    </section>
    """
  end

  defp job_badge("done"), do: "badge-success"
  defp job_badge(status) when status in ~w(failed timeout), do: "badge-error"
  defp job_badge(status) when status in ~w(claimed running), do: "badge-info"
  defp job_badge(_), do: "badge-ghost"

  defp job_time(job) do
    at = job.finished_at || job.started_at || job.claimed_at || job.inserted_at
    Calendar.strftime(at, "%d %b %H:%M")
  end

  # The last few lines are what say how it went.
  defp job_log(job) do
    case job.output || job.log_tail do
      text when text in [nil, ""] -> nil
      text -> text |> String.split("\n") |> Enum.take(-12) |> Enum.join("\n")
    end
  end

  attr :provenance, :list, required: true

  @doc """
  *From a meeting* (G11): the meeting a card, or a change to it, came from —
  when in it, who said what, how it was read and who committed it. Kept on
  the card, so it reads the same after the capture is gone.
  """
  def provenance_section(assigns) do
    ~H"""
    <section class="space-y-2 px-1" id="card-provenance">
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/50">
        <.icon name="hero-microphone" class="size-3.5" /> From a meeting
      </h3>
      <div
        :for={p <- @provenance}
        id={"provenance-#{p.id}"}
        class="rounded-lg bg-base-200/60 px-3 py-2 text-sm"
      >
        <p class="text-xs text-base-content/60">
          {if p.kind == "created", do: "Made", else: "Changed"} from “{p.meeting}”<span :if={p.met_at}>, {Calendar.strftime(
            p.met_at,
            "%-d %b %Y"
          )}</span><span :if={p.at_ms}> at {provenance_clock(p.at_ms)}</span>
        </p>
        <blockquote :if={p.quote} class="mt-1 border-l-2 border-base-content/20 pl-2 italic">
          “{p.quote}”
          <span class="not-italic text-xs text-base-content/60">— {p.speaker || "unnamed"}</span>
        </blockquote>
        <p :if={p.read not in [nil, ""]} class="mt-1 text-xs text-base-content/60">
          Read as: {p.read}
        </p>
        <p :if={p.committed_by} class="text-xs text-base-content/60">Committed by {p.committed_by}</p>
      </div>
    </section>
    """
  end

  defp provenance_clock(ms) do
    s = div(ms, 1000)
    "#{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :form_key, :integer, required: true
  attr :link_kind, :string, default: "relates"
  attr :link_query, :string, default: ""
  attr :link_results, :list, default: []
  attr :target, :any, required: true

  @doc "Links to cards on any board, and how much the card's contributions have done."
  def links_section(assigns) do
    ~H"""
    <section class="space-y-2 px-1" id="card-links" data-section-key="n">
      <h3 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        <.icon name="hero-arrows-right-left" class="size-3.5" />
        <.keyed_label key="n" label="Links" />
      </h3>
      <ul :if={@card.links_out != [] or @card.links_in != []} class="space-y-1">
        <li
          :for={
            {link, other, dir} <-
              Enum.map(@card.links_out, &{&1, &1.to, :out}) ++
                Enum.map(@card.links_in, &{&1, &1.from, :in})
          }
          id={"link-#{link.id}"}
          class="flex items-center gap-2 text-xs"
        >
          <span class="chip chip-line shrink-0 text-2xs">{CardLink.label(link.kind, dir)}</span>
          <.link
            navigate={~p"/boards/#{other.board_id}/cards/#{other.id}"}
            class={[
              "min-w-0 flex-1 truncate hover:underline",
              other.completed && "text-base-content/60"
            ]}
            title={other.title}
          >
            {other.title}
          </.link>
          <span
            :if={other.board_id != @board.id and match?(%{name: _}, other.board)}
            class="max-w-32 shrink-0 truncate text-2xs text-base-content/50"
            title={"On board #{other.board.name}"}
          >
            {other.board.name}
          </span>
          <button
            :if={@can_write}
            phx-target={@target}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="remove_link"
            phx-value-id={link.id}
            title="Remove link"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </li>
      </ul>
      <.contributions_bar card={@card} />
      <form
        :if={@can_write}
        phx-target={@target}
        id={"link-form-#{@form_key}"}
        phx-change="link_search"
        phx-submit="link_search"
        class="space-y-1.5"
      >
        <div class="flex gap-1">
          <select name="kind" class="select select-xs w-36" title="Kind of link">
            <option
              :for={{key, label, _} <- CardLink.kinds()}
              value={key}
              selected={key == @link_kind}
            >
              {label}
            </option>
          </select>
          <input
            type="search"
            name="q"
            value={@link_query}
            placeholder="Search cards on any board…"
            class="input input-xs min-w-0 flex-1"
            autocomplete="off"
            phx-debounce="250"
          />
        </div>
        <ul :if={@link_results != []} class="menu menu-sm rounded-xl bg-base-200/70 p-1">
          <li :for={result <- @link_results}>
            <button
              phx-target={@target}
              type="button"
              phx-click="add_link"
              phx-value-id={result.id}
              class="flex items-center gap-2"
            >
              <span class="truncate">{result.title}</span>
              <span class="ml-auto shrink-0 text-2xs text-base-content/50">{result.board.name}</span>
            </button>
          </li>
        </ul>
        <p
          :if={@link_query != "" and @link_results == []}
          class="px-1 text-xs text-base-content/50"
        >
          No cards match.
        </p>
      </form>
    </section>
    """
  end

  attr :card, :map, required: true

  @doc "How many of the cards that contribute to this one are done."
  def contributions_bar(assigns) do
    contributions = Card.contributions(assigns.card)

    assigns =
      assign(assigns,
        total: length(contributions),
        done: Enum.count(contributions, & &1.completed)
      )

    ~H"""
    <div :if={@total > 0} class="flex items-center gap-2 text-xs" id="card-contributions">
      <progress class="progress progress-primary h-1.5 w-24" value={@done} max={@total}></progress>
      <span class="font-mono text-base-content/70">{@done}/{@total}</span>
      <span class="text-base-content/50">contributions done</span>
    </div>
    """
  end
end
