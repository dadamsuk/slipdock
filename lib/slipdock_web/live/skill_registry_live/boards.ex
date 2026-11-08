defmodule SlipdockWeb.SkillRegistryLive.Boards do
  @moduledoc """
  The registry page's board parts (#2062, spec W-2513 §Enabling per board,
  §Which stages name it), drawn by `SlipdockWeb.SkillRegistryLive.Index`:

  - `entry_boards/1`, on an entry's page: where it is enabled, pinned to
    which text, whether a refresh has changed it since (with the lines that
    differ, and a re-pin for a writer), the form that enables it on another
    board, and the Playbook stages that name it.
  - `stages/1`, on the list: every board whose Playbook names a skill, each
    stage with what it gets, and a stage that names a skill neither enabled
    there nor shipped by Slipdock flagged.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents, only: [timestamp: 1]

  alias Slipdock.SkillRegistry

  attr :entry, :map, required: true
  attr :where, :list, required: true, doc: "`SkillRegistry.enabled_where/2`"
  attr :writable, :list, required: true, doc: "boards it could be enabled on"
  attr :naming, :list, required: true, doc: "`SkillRegistry.naming/2`"
  attr :form, :any, required: true
  attr :notice, :any, default: nil

  def entry_boards(assigns) do
    ~H"""
    <section
      id="skill-entry-boards"
      class="space-y-4 rounded-2xl bg-base-100 p-5 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="section-title">On boards</h2>
      <.callout :if={@notice} id="skill-entry-notice" kind={elem(@notice, 0)}>
        {elem(@notice, 1)}
      </.callout>
      <p class="text-sm text-base-content/60">
        Enabling it on a board pins the text above: that board's agents get exactly
        this, even after a refresh changes it, until somebody who can write to the
        board reads the change and re-pins it.
      </p>

      <ul :if={@where != []} class="divide-y divide-base-content/10">
        <li
          :for={%{enablement: e, writer: writer} <- @where}
          id={"skill-enabled-#{e.id}"}
          class="space-y-2 py-3"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <p>
              <span class="font-medium">{e.board.name}</span>
              <span class="ml-2 text-xs text-base-content/60">
                pinned <.timestamp at={e.pinned_at} />
              </span>
              <span
                :if={SkillRegistry.status(e) == :changed}
                id={"skill-enabled-#{e.id}-changed"}
                class="badge badge-warning badge-sm ml-2"
              >
                Changed upstream
              </span>
            </p>
            <div :if={writer} class="flex gap-2">
              <.button
                :if={SkillRegistry.status(e) == :changed}
                id={"skill-enabled-#{e.id}-repin"}
                phx-click="repin"
                phx-value-id={e.id}
                phx-value-hash={e.entry.content_hash}
                class="btn btn-primary btn-sm"
              >
                Re-pin to the new text
              </.button>
              <.button
                id={"skill-enabled-#{e.id}-disable"}
                phx-click="disable"
                phx-value-id={e.id}
                variant="danger"
                data-confirm={"Disable #{e.name} on #{e.board.name}?"}
              >
                Disable
              </.button>
            </div>
          </div>
          <div :if={SkillRegistry.status(e) == :changed}>
            <p class="text-sm text-base-content/60">
              A refresh changed it. Agents on {e.board.name} still get the pinned text;
              these are the lines that differ (− pinned, + now).
            </p>
            <pre
              id={"skill-enabled-#{e.id}-diff"}
              class="mt-2 whitespace-pre-wrap break-words rounded-xl bg-base-200 p-3 text-sm"
            ><span
              :for={{kind, line} <- diff_lines(e)}
              class={diff_class(kind)}
            >{diff_mark(kind)} {line}
    </span></pre>
          </div>
        </li>
      </ul>
      <.empty_state
        :if={@where == []}
        id="skill-entry-boards-empty"
        icon="hero-squares-2x2"
        title="Not enabled on any board you can see"
        compact
      >
        Enable it on a board below, once you've read it.
      </.empty_state>

      <.form
        :if={@writable != []}
        for={@form}
        id="skill-enable-form"
        phx-submit="enable"
        class="field-row gap-2"
      >
        <div class="min-w-0 flex-1">
          <.input
            field={@form[:board_id]}
            id="skill-enable-board"
            type="select"
            label="Enable on"
            options={Enum.map(@writable, &{&1.name, &1.id})}
          />
        </div>
        <input type="hidden" name="hash" value={@entry.content_hash} />
        <.button class="btn btn-primary btn-sm">Enable this text</.button>
      </.form>

      <div id="skill-entry-stages">
        <h3 class="text-sm font-semibold">Named by Playbook stages</h3>
        <ul :if={@naming != []} class="mt-1 space-y-1 text-sm">
          <li :for={{board, stage} <- for(row <- @naming, s <- row.stages, do: {row.board, s})}>
            {board.name} · {stage.stage}
            <span :if={stage.enabled} class="text-success">· enabled</span>
            <span :if={!stage.enabled} class="text-base-content/60">· not enabled there</span>
          </li>
        </ul>
        <.empty_state
          :if={@naming == []}
          id="skill-entry-stages-empty"
          icon="hero-map"
          title="No stage names it"
          class="mt-1"
          compact
        >
          No Playbook on a board you can see has <code>skill: {@entry.name}</code>.
        </.empty_state>
      </div>
    </section>
    """
  end

  attr :naming, :list, required: true, doc: "`SkillRegistry.naming/1`"

  def stages(assigns) do
    ~H"""
    <section id="skills-stages">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
        Named by Playbook stages
      </h2>
      <p class="mt-1 text-sm text-base-content/60">
        A stage on a board's Playbook names a skill with a <code>skill: &lt;name&gt;</code>
        line. Here is what each gets.
      </p>
      <.empty_state
        :if={@naming == []}
        id="skills-stages-empty"
        icon="hero-map"
        title="No Playbook names a skill"
        class="mt-2"
        compact
      >
        Add a <code>skill:</code> line to a stage on a board's Playbook page.
      </.empty_state>
      <article
        :for={%{board: board, stages: stages} <- @naming}
        id={"skills-stages-board-#{board.id}"}
        class="mt-3 rounded-2xl bg-base-100 p-4 shadow-sm ring-1 ring-base-content/10"
      >
        <h3 class="font-semibold">
          <.link navigate={~p"/boards/#{board.id}"} class="link">{board.name}</.link>
        </h3>
        <ul class="mt-2 space-y-1 text-sm">
          <li
            :for={stage <- stages}
            id={"skills-stage-#{board.id}-#{slug(stage.stage)}-#{stage.skill}"}
          >
            <span class="font-medium">{stage.stage}</span>
            · <code>{stage.skill}</code>
            <span :if={stage.enabled} class="text-success">
              · enabled, from {stage.enabled.source_name}
            </span>
            <span :if={stage.enabled && SkillRegistry.status(stage.enabled) == :changed}>
              <span class="badge badge-warning badge-sm">Changed upstream</span>
            </span>
            <span :if={!stage.enabled && stage.shipped} class="text-base-content/60">
              · a skill Slipdock ships
            </span>
            <span :if={stage.flagged} class="badge badge-warning badge-sm" data-flagged>
              Not enabled here, and not a skill Slipdock ships
            </span>
          </li>
        </ul>
      </article>
    </section>
    """
  end

  # One line of the pinned-vs-now diff each, unchanged runs kept for context.
  defp diff_lines(enablement) do
    for {kind, lines} <- SkillRegistry.diff(enablement), line <- lines, do: {kind, line}
  end

  defp diff_mark(:del), do: "−"
  defp diff_mark(:ins), do: "+"
  defp diff_mark(:eq), do: " "

  defp diff_class(:del), do: "block bg-error/10"
  defp diff_class(:ins), do: "block bg-success/10"
  defp diff_class(:eq), do: "block text-base-content/60"

  defp slug(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
end
