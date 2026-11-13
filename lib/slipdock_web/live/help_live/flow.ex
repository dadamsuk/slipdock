defmodule SlipdockWeb.HelpLive.Flow do
  @moduledoc """
  Help › Agents › How work flows (`/help/agents/flow`, #1885): one card on a
  board worked by runners, from being written to being deployed, with who
  acts at each stage and where a person has to.

  The facts are the manual's (*Verified work*, *Lanes*, *Waiting on a
  person*, *Tidying up*, *Findings*), `docs/agents.md` and the API guide;
  this page joins them up and links out rather than repeating every option.
  Every `slipdock …` command it shows is checked against `cli/help.txt`, and
  every setting in `settings/0` against the board's Agentic Building page, by
  `SlipdockWeb.HelpLive.FlowTest`, so a rename breaks a test, not the page.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.HelpLive.Components

  alias SlipdockWeb.HelpLive.Agents

  # The stages, in order: the diagram and the sections below are both drawn
  # from this. `person` is true where a person has to act at that stage;
  # `steps` are the step statuses the server posts there (#2022,
  # `Slipdock.StepStatus`).
  @stages_file Path.join(__DIR__, "flow/stages.exs")
  @external_resource @stages_file
  @stages @stages_file |> Code.eval_file() |> elem(0)

  # The board settings this page names: the label on the board's Agentic
  # Building page (#2011), and the CLI that sets it. FlowTest checks both still exist.
  @settings_file Path.join(__DIR__, "flow/settings.exs")
  @external_resource @settings_file
  @settings @settings_file |> Code.eval_file() |> elem(0)

  def stages, do: @stages
  def settings, do: @settings

  # `flow_page/1`, the page's frame, and a `<id>_stage/1` for each stage.
  embed_templates "flow/*.html"
  embed_templates "flow/stages/*.html", suffix: "_stage"

  attr :topics, :list, required: true

  def page(assigns) do
    assigns
    |> assign(stages: @stages, settings: @settings)
    |> flow_page()
  end

  defp stage_heading(stage, stages) do
    n = Enum.find_index(stages, &(&1.id == stage.id)) + 1
    "#{n}. #{stage.title}"
  end

  # ── The diagram ───────────────────────────────────────────────────────────
  # A column of stages joined by arrows, so it never needs to scroll
  # sideways: each says who acts, and the ones where a person must act are
  # ringed in the warning colour with a hand. The two ways back (a
  # rejection, a wait) hang off the stages they leave from.

  attr :stages, :list, required: true

  defp diagram(assigns) do
    ~H"""
    <section
      id="flow-diagram"
      aria-labelledby="flow-diagram-title"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 id="flow-diagram-title" class="section-title">The flow at a glance</h2>
      <p class="mt-1 text-sm text-base-content/70">
        Who acts at each stage.
        <.icon name="hero-hand-raised" class="size-4 align-text-bottom text-warning" />
        <strong class="text-base-content">Ringed</strong>
        stages are where a person has to act.
      </p>
      <.legend />
      <ol class="mt-4 space-y-0">
        <li :for={{s, i} <- Enum.with_index(@stages, 1)} id={"flow-node-#{s.id}"}>
          <div
            class={[
              "flex min-w-0 items-start gap-3 rounded-xl p-3",
              (s.person && "bg-warning/10 ring-2 ring-warning") || "bg-base-200/60"
            ]}
            data-person={s.person && "true"}
          >
            <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-100 text-sm font-semibold tabular-nums ring-1 ring-base-content/15">
              {i}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <a href={"#flow-#{s.id}"} class="link font-semibold">{s.title}</a>
                <span :for={a <- s.actors} class={["badge badge-sm", actor_class(a)]}>
                  {actor_label(a)}
                </span>
                <span
                  :if={s.person}
                  class="inline-flex items-center gap-1 text-xs font-medium text-base-content"
                >
                  <.icon name="hero-hand-raised" class="size-4 text-warning" /> You act here
                </span>
              </div>
              <p class="mt-1 text-sm text-base-content/70">{s.gist}</p>
              <.branch :if={s.id == "building"} icon="hero-pause-circle">
                Stuck on something only you can give: a <strong>wait</strong>
                on you. Your answer sends it back to work.
              </.branch>
              <.branch :if={s.id == "verifying"} icon="hero-arrow-uturn-left">
                <strong>Rejected:</strong> back to 2, the reason as its next brief.
              </.branch>
              <.branch :if={s.id == "verifying"} icon="hero-hand-raised">
                <strong>Rejected past the limit:</strong>
                a wait on you: rework it, or accept it as is.
              </.branch>
            </div>
          </div>
          <div
            :if={i < length(@stages)}
            class="flex justify-start py-1 pl-5 text-base-content/40"
            aria-hidden="true"
          >
            <.icon name="hero-arrow-down" class="size-4" />
          </div>
        </li>
      </ol>
    </section>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp branch(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-start gap-1.5 text-xs text-base-content/70">
      <.icon name={@icon} class="mt-px size-4 shrink-0 text-warning" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  defp legend(assigns) do
    ~H"""
    <p class="mt-3 flex flex-wrap gap-2 text-xs text-base-content/70">
      <span :for={a <- [:person, :builder, :verifier, :ci, :board]} class="flex items-center gap-1">
        <span class={["badge badge-sm", actor_class(a)]}>{actor_label(a)}</span>
        {actor_note(a)}
      </span>
    </p>
    """
  end

  attr :actors, :list, required: true

  defp actors(assigns) do
    ~H"""
    <p class="flex flex-wrap items-center gap-1.5">
      <span class="font-medium text-base-content">Who acts:</span>
      <span :for={a <- @actors} class={["badge badge-sm", actor_class(a)]}>{actor_label(a)}</span>
    </p>
    """
  end

  attr :id, :string, required: true
  attr :steps, :list, required: true

  # The step statuses the server posts at a stage (#2022): On track, by
  # Slipdock, on the card's status updates and at the top of the card.
  defp steps(assigns) do
    ~H"""
    <div :if={@steps != []} id={"flow-#{@id}-steps"} class="flex flex-wrap items-center gap-1.5">
      <span class="font-medium text-base-content">Step status:</span>
      <span :for={step <- @steps} class="badge badge-sm badge-success badge-soft">{step}</span>
    </div>
    """
  end

  defp actor_label(:person), do: "Person"
  defp actor_label(:builder), do: "Builder"
  defp actor_label(:verifier), do: "Verifier"
  defp actor_label(:ci), do: "CI"
  defp actor_label(:board), do: "The board"

  defp actor_note(:person), do: "you, or whoever owns the board"
  defp actor_note(:builder), do: "the agent doing the card"
  defp actor_note(:verifier), do: "a second agent"
  defp actor_note(:ci), do: "your repository's checks"
  defp actor_note(:board), do: "its rules and checks"

  defp actor_class(:person), do: "badge-warning"
  defp actor_class(:builder), do: "badge-info badge-soft"
  defp actor_class(:verifier), do: "badge-success badge-soft"
  defp actor_class(:ci), do: "badge-ghost"
  defp actor_class(:board), do: "badge-ghost italic"

  @doc """
  The completion example the page shows (#2699): evidence as lines, not a
  paragraph, on stdin.
  """
  def evidence_example do
    """
    slipdock done 12 --evidence-commit abc1234 --suite passed:412:0 --evidence - <<'EOF'
    Built and tested; CI green.

    - the export keeps archived cards (`Export.run/1`)
    - Handbook: updated W-3 §Exports
    EOF\
    """
  end

  @doc """
  The rejection example the page shows (#2699): a reason as lines, its parts
  in `--check`, on stdin.
  """
  def reason_example do
    """
    slipdock verify 12 reject --check bar:2=fail:"no test" --reason - <<'EOF'
    bar 2: the export drops archived cards

    - `Export.run/1` filters on `archived_at`
    - no test exports an archived card
    EOF\
    """
  end

  # ── The stages ────────────────────────────────────────────────────────────

  attr :id, :string, required: true

  # One clause a stage, calling its template.
  for %{id: id} <- @stages do
    defp stage(%{id: unquote(id)} = assigns),
      do: unquote(String.to_existing_atom(id <> "_stage"))(assigns)
  end

  slot :inner_block, required: true

  defp person_note(assigns) do
    ~H"""
    <div data-person="true" class="flex gap-2 rounded-xl bg-warning/10 p-3 ring-1 ring-warning">
      <.icon name="hero-hand-raised" class="mt-0.5 size-4 shrink-0 text-warning" />
      <div class="min-w-0 text-base-content">
        <span class="sr-only">A person acts here: </span>{render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
