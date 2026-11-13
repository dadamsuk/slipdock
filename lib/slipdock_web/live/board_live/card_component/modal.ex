defmodule SlipdockWeb.BoardLive.CardComponent.Modal do
  @moduledoc """
  The card panel's modal: its toolbar, notices, the sections of the card in
  the order they are read, the sidebar, and what sits under them (the
  timeline, sharing, the assistant).

  Function components: they draw what `BoardLive.CardComponent` holds and
  send their events to it.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents
  import SlipdockWeb.ItemComponents
  import SlipdockWeb.ShareComponents
  import SlipdockWeb.BoardLive.Helpers
  import SlipdockWeb.BoardLive.CardPanel
  import SlipdockWeb.BoardLive.CardSections
  import SlipdockWeb.BoardLive.WaitComponents
  import SlipdockWeb.BoardLive.CardComponent.Glance

  alias Slipdock.Boards.Card
  alias Slipdock.Palette

  attr :card, Card, required: true
  attr :users, :list, required: true
  attr :form, :any, required: true
  attr :board, :any, required: true
  attr :form_key, :integer, required: true
  attr :close_path, :string, required: true
  attr :tags_path, :string, required: true
  attr :card_link, :any, required: true, doc: "fn card_id -> path"
  attr :target, :any, required: true
  attr :link_kind, :string, default: "relates"
  attr :link_query, :string, default: ""
  attr :link_results, :list, default: []
  attr :dep_direction, :string, required: true
  attr :dep_query, :string, required: true
  attr :dep_results, :list, required: true
  attr :templates, :list, required: true
  attr :picking_template, :boolean, required: true
  attr :mention_people, :string, default: nil
  attr :can_write, :boolean, required: true
  attr :can_comment, :boolean, default: false, doc: "may join the discussion (#863)"
  attr :can_share, :boolean, required: true
  attr :grants, :list, required: true
  attr :pages, :list, default: [], doc: "the wiki pages that talk about this card"
  attr :jobs, :list, default: [], doc: "the card's latest runner jobs"
  attr :loop, :map, default: nil, doc: "`Slipdock.CardState.loop_of/2`: the runner loop on it"
  attr :authors, :map, default: nil, doc: "`Slipdock.CardAuthors.for_card/1` (#2028)"
  attr :findings, :integer, default: 0, doc: "how many open findings the card has"
  attr :timeline, :any, default: nil, doc: "the card's timeline (#1131)"
  attr :lead_time, :any, default: nil, doc: "its lead time and cost (#1954)"
  attr :doc_query, :string, default: "", doc: "what is typed into the Docs picker"
  attr :doc_results, :list, default: [], doc: "pages the Docs picker is offering"
  attr :groups, :list, required: true
  attr :share_key, :integer, required: true
  attr :uploads, :map, required: true
  attr :editing_description, :boolean, required: true
  attr :handoff_history, :list, default: [], doc: "every handoff written, newest first"
  attr :shipped, :list, default: [], doc: "`Slipdock.Deployments.shipped/1`: where it has shipped"
  attr :release, :map, default: nil, doc: "`Slipdock.Releases.state/1`: its batched release"

  attr :deploy_failed, :list,
    default: [],
    doc: "`Slipdock.Deployments.deploy_failed/1`: where its latest deploy attempt failed"

  attr :not_shipped, :any,
    default: nil,
    doc: "`Slipdock.Deployments.NotShipped.for_card/2`: merged, and no deploy names it"

  attr :incident, :map,
    default: nil,
    doc: "both ends of an incident (#1946), as the reader may see"

  attr :panel_notice, :any,
    default: nil,
    doc: "what the panel's last action said, `{kind, message}`, at its top (UX-29)"

  attr :incident_error, :string,
    default: nil,
    doc: "why the Incident line refused its last change, shown in it (UX-29)"

  attr :wait_count, :integer, default: 0, doc: "how many waits the card has had (#1114)"
  attr :wait_history, :list, default: [], doc: "the closed waits, newest first (#1220)"
  attr :wait_answers, :map, default: %{}, doc: "what is typed into the answer boxes"
  attr :wait_suggest, :map, default: %{}, doc: "suggested answers running or failed"
  attr :asking, :map, default: nil, doc: "the Ask questions form, while it is open"
  attr :editing_handoff, :boolean, default: false
  attr :handoff_form, :any, default: nil

  attr :handoff_draft, :any,
    default: nil,
    doc: "Auto generate: nil, :running, :done or {:error, why}"

  attr :repeat, :map, default: nil, doc: "the Repeat… form while it is open (W-1802)"
  attr :close_navigate, :boolean, default: false
  attr :parent, :any, default: nil
  attr :ai?, :boolean, default: false, doc: "offer the AI assistant on the card"
  attr :at, :string, default: nil, doc: "where in the card a search result points"
  attr :narrow?, :boolean, default: false, doc: "a phone: the properties come first (#1729)"

  attr :current_user, :any, default: nil

  attr :favourites, :any,
    default: nil,
    doc: "the reader's favourites (`Slipdock.Favourites.marks/1`)"

  attr :hidden_by_view, :list,
    default: [],
    doc: "sections the card view hides that need attention on this card (#2031)"

  attr :card_view, :any,
    default: nil,
    doc: "the reader's resolved card views (#2031); nil shows every section"

  attr :waiting, :map,
    default: %{mine: [], others: [], rows: %{}},
    doc: "what in the epic's tree waits on the reader, by subcard row (#2126)"

  def card_modal(assigns) do
    {done, total, pct} = checklist_progress(assigns.card.checklist_items)
    # Which sections and sidebar groups the reader's card view keeps (#2031).
    # The board's own conditions on each still apply: a card view only hides.
    panel = Slipdock.CardViews.panel_shown(assigns.card_view, assigns.card.column_id)
    assigns = assign(assigns, done: done, total: total, pct: pct, panel: panel)

    ~H"""
    <.modal
      id="card-modal"
      on_close={if @close_navigate, do: JS.navigate(@close_path), else: JS.patch(@close_path)}
      size="wide"
      keys
    >
      <%!-- Outside the fieldsets below, which are disabled for a read-only
            card: a favourite is the reader's own, not a change to the card.
            The heart's weight is in its top half, so in the same box as the
            close x it reads high: a pixel down lines the two up by eye. --%>
      <:actions>
        <.favourite_toggle
          kind="card"
          id={@card.id}
          name={@card.title}
          marks={@favourites}
          class="btn btn-ghost btn-sm btn-circle"
          size="size-5 translate-y-px"
        />
      </:actions>
      <%!-- The cover strip lies over the top of the toolbar row, as it lies
            under the heart and close button, so the toolbar and they share
            one row whether the card has a cover or not. --%>
      <div
        :if={@card.color}
        class={[
          "pointer-events-none absolute inset-x-0 top-0 h-3 bg-gradient-to-r sm:rounded-t-2xl",
          Palette.gradient(@card.color)
        ]}
      >
      </div>
      <%!-- The actions (#1725), left of the heart and close button, which the
            modal draws in its corner: `pr-24` keeps the row clear of them. --%>
      <div class="flex h-14 items-center justify-end pl-6 pr-24">
        <.card_toolbar
          board={@board}
          can_write={@can_write}
          card={@card}
          handoff_link={@can_comment and is_nil(current_handoff(@card)) and not @editing_handoff}
          ask_link={@can_write and is_nil(Card.open_wait(@card)) and is_nil(@asking)}
          target={@target}
        />
      </div>
      <p
        :if={!@can_write}
        id="card-access-note"
        class="flex items-center gap-2 bg-base-200 px-6 py-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-lock-closed" class="size-3.5" />
        {if @can_comment,
          do: "You can comment on this card, but not change it.",
          else: "You have read-only access to this card."}
      </p>
      <.panel_notice notice={@panel_notice} class="mx-6 mt-2" />
      <%!-- A hidden section that needs attention stays findable (#2031). --%>
      <.callout
        :if={@hidden_by_view != []}
        kind={:warning}
        id="card-view-hidden-attention"
        class="mx-6 mt-2"
      >
        Your card view hides {Enum.join(@hidden_by_view, " and ")} on this card.
        <button
          type="button"
          id="reveal-hidden-sections"
          class="btn btn-ghost btn-xs"
          phx-click="reveal_sections"
          phx-target={@target}
        >
          Show them
        </button>
      </.callout>
      <.parent_links :if={@parent} parent={@parent} />
      <%!-- Two kinds of control, two fieldsets: the card's own fields need
            write, the discussion (comments, status, votes) only comment. --%>
      <div class="grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_260px]">
        <div class="min-w-0 space-y-7 px-6 pb-6 pt-1">
          <div class="space-y-3">
            <fieldset disabled={!@can_write} class="min-w-0">
              <.card_title_form
                board={@board}
                can_write={@can_write}
                card={@card}
                form={@form}
                target={@target}
              />
            </fieldset>
            <%!-- At a glance (#2022), just beneath the title: the step it is
                at, where it was left (W-1804) or, once finished, how it
                ended, where it has shipped, then the note. Only once there
                is something to say or the note is being written: until
                then the meta line's link opens the form. Its own fieldset,
                since a commenter may write it. --%>
            <fieldset
              :if={
                (glance?(@card, @shipped ++ @deploy_failed) and on?(@panel, "open.glance")) ||
                  @editing_handoff
              }
              disabled={!@can_comment}
              class="min-w-0"
            >
              <.handoff_panel
                card={@card}
                label={Slipdock.Boards.Board.handoff_label(@board)}
                board={@board}
                history={@handoff_history}
                editing={@editing_handoff}
                form={@handoff_form}
                draft={@handoff_draft}
                ai?={@ai?}
                can_comment={@can_comment}
                can_write={@can_write}
                current_user={@current_user}
                users={@users}
                shipped={@shipped}
                deploy_failed={@deploy_failed}
                release={@release}
                not_shipped={@not_shipped}
                target={@target}
              />
            </fieldset>
            <%!-- Waiting on a person (#1114): only while it is, its
                  questions numbered with a box each (#1220). Otherwise
                  the Ask questions form, while it is open. --%>
            <fieldset
              :if={Card.open_wait(@card) && on?(@panel, "open.wait")}
              disabled={!@can_write}
              class="min-w-0"
            >
              <.wait_panel
                wait={Card.open_wait(@card)}
                count={@wait_count}
                can_write={@can_write}
                answers={@wait_answers}
                suggesting={@wait_suggest}
                ai?={@ai?}
                target={@target}
              />
            </fieldset>
            <fieldset
              :if={@asking && @can_write && !Card.open_wait(@card)}
              class="min-w-0"
            >
              <.ask_form asking={@asking} users={@users} target={@target} />
            </fieldset>
            <.wait_history :if={@wait_history != []} waits={@wait_history} />
            <%!-- On a phone (#1729) the properties come first: a summary
                  under the title that opens onto their rows, which the
                  sidebar, far below, then leaves out. --%>
            <fieldset :if={@narrow?} disabled={!@can_write} class="min-w-0">
              <.phone_properties
                board={@board}
                card={@card}
                loop={@loop}
                authors={@authors}
                form={@form}
                target={@target}
                users={@users}
                panel={@panel}
              />
            </fieldset>
            <fieldset disabled={!@can_write} class="min-w-0 space-y-7">
              <.open_sections
                board={@board}
                can_write={@can_write}
                card={@card}
                current_user={@current_user}
                editing_description={@editing_description}
                form={@form}
                mention_people={@mention_people}
                tags_path={@tags_path}
                target={@target}
                uploads={@uploads}
                panel={@panel}
                form_key={@form_key}
                at={@at}
                picking_template={@picking_template}
                templates={@templates}
                waiting={@waiting}
                card_link={@card_link}
                dep_direction={@dep_direction}
                dep_query={@dep_query}
                dep_results={@dep_results}
                incident={@incident}
                incident_error={@incident_error}
                doc_query={@doc_query}
                doc_results={@doc_results}
                pages={@pages}
                findings={@findings}
                jobs={@jobs}
                lead_time={@lead_time}
                link_kind={@link_kind}
                link_query={@link_query}
                link_results={@link_results}
              />
            </fieldset>
          </div>

          <fieldset :if={on?(@panel, "open.comments")} disabled={!@can_comment} class="min-w-0">
            <%!-- Pasting an image attaches it to the card, so that is a writer's. --%>
            <.comments_section
              target={@target}
              item={@card}
              board={@board}
              current_user={@current_user}
              can_write={@can_write}
              can_comment={@can_comment}
              form_key={@form_key}
              uploads={@can_write && @uploads}
              mention_people={@mention_people}
              section_key="c"
            />
          </fieldset>
        </div>

        <.card_sidebar
          narrow?={@narrow?}
          loop={@loop}
          authors={@authors}
          repeat={@repeat}
          board={@board}
          can_write={@can_write}
          can_comment={@can_comment}
          card={@card}
          current_user={@current_user}
          form={@form}
          form_key={@form_key}
          target={@target}
          users={@users}
          panel={@panel}
        />
      </div>
      <div
        :if={@timeline && not Slipdock.CardTimeline.empty?(@timeline) && on?(@panel, "open.timeline")}
        class="border-t border-base-content/10 px-6 py-4"
      >
        <.timeline_section
          timeline={@timeline}
          zone={Slipdock.Timezones.of(@current_user)}
        />
      </div>
      <div
        :if={@can_share && on?(@panel, "open.sharing")}
        class="border-t border-base-content/10 px-6 py-4"
      >
        <p class="mb-2 section-label">
          Sharing this card
        </p>
        <.share_panel
          target={@target}
          resource="card"
          grants={@grants}
          groups={@groups}
          can_manage={@can_share}
          form_key={@share_key}
          compact
        />
      </div>
      <.live_component
        :if={@ai? && on?(@panel, "open.ai")}
        module={SlipdockWeb.AIChatComponent}
        id={"card-ai-#{@card.id}"}
        layout="inline"
        title="Ask AI about this card"
        placeholder="Ask about this card…"
        source={%{kind: :card, board: @board, card: @card, users: @users}}
        current_user={@current_user}
        can_write={@can_write}
      />
    </.modal>
    """
  end

  attr :parent, :any, required: true

  # Back to the card this one is a subcard of, and to the board that holds it.
  defp parent_links(assigns) do
    ~H"""
    <div
      id="card-parent"
      class="flex min-w-0 items-center gap-3 bg-base-200/60 px-6 py-1.5 text-xs text-base-content/60"
    >
      <.link
        navigate={~p"/boards/#{@parent.board}/cards/#{@parent.card.id}"}
        class="flex min-w-0 items-center gap-1.5 hover:text-base-content"
        title={"Back to parent card: #{@parent.card.title}"}
      >
        <.icon name="hero-arrow-uturn-left" class="size-3.5 shrink-0" />
        <span class="shrink-0">Parent card</span>
        <span class="truncate font-medium">{@parent.card.title}</span>
      </.link>
      <.link
        navigate={~p"/boards/#{@parent.board}"}
        class="flex min-w-0 shrink items-center gap-1.5 hover:text-base-content"
        title={"Open the board that holds the parent card: #{@parent.board.name}"}
      >
        <.icon name="hero-squares-2x2" class="size-3.5 shrink-0" />
        <span class="shrink-0">Parent board</span>
        <span class="truncate font-medium">{@parent.board.name}</span>
      </.link>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :can_write, :boolean, required: true
  attr :card, Card, required: true
  attr :current_user, :any, default: nil
  attr :editing_description, :boolean, required: true
  attr :form, :any, required: true
  attr :mention_people, :string, default: nil
  attr :tags_path, :string, required: true
  attr :target, :any, required: true
  attr :uploads, :map, required: true
  attr :panel, :any, required: true, doc: "the sections the reader's card view keeps"
  attr :form_key, :integer, required: true
  attr :at, :string, default: nil, doc: "where in the card a search result points"
  attr :picking_template, :boolean, required: true
  attr :templates, :list, required: true

  attr :waiting, :map,
    default: %{mine: [], others: [], rows: %{}},
    doc: "what in the epic's tree waits on the reader, by subcard row (#2126)"

  attr :card_link, :any, required: true, doc: "fn card_id -> path"
  attr :dep_direction, :string, required: true
  attr :dep_query, :string, required: true
  attr :dep_results, :list, required: true

  attr :incident, :map,
    default: nil,
    doc: "both ends of an incident (#1946), as the reader may see"

  attr :incident_error, :string,
    default: nil,
    doc: "why the Incident line refused its last change, shown in it (UX-29)"

  attr :doc_query, :string, default: "", doc: "what is typed into the Docs picker"
  attr :doc_results, :list, default: [], doc: "pages the Docs picker is offering"
  attr :pages, :list, default: [], doc: "the wiki pages that talk about this card"
  attr :findings, :integer, default: 0, doc: "how many open findings the card has"
  attr :jobs, :list, default: [], doc: "the card's latest runner jobs"
  attr :lead_time, :any, default: nil, doc: "its lead time and cost (#1954)"
  attr :link_kind, :string, default: "relates"
  attr :link_query, :string, default: ""
  attr :link_results, :list, default: []

  # The card's own sections, in the order they are read, inside the fieldset
  # that needs write: each drawn when the board has a use for it and the
  # reader's card view keeps it.
  defp open_sections(assigns) do
    ~H"""
    <.card_header_form
      board={@board}
      can_write={@can_write}
      card={@card}
      current_user={@current_user}
      editing_description={@editing_description}
      form={@form}
      mention_people={@mention_people}
      tags_path={@tags_path}
      target={@target}
      uploads={@uploads}
      description?={on?(@panel, "open.description")}
    />

    <%!-- The agent work (#2018): profile, bar, paths and evidence
          together, apart from the general fields. --%>
    <.profile_section
      :if={(@board.profiles || @card.profile) && on?(@panel, "open.profile")}
      board={@board}
      card={@card}
      form={@form}
      target={@target}
    />

    <.bar_section
      :if={(@board.bar_required || @card.bar) && on?(@panel, "open.bar")}
      card={@card}
      form={@form}
      target={@target}
    />

    <.paths_section
      :if={(@card.paths != [] || Slipdock.Lanes.on?(@board)) && on?(@panel, "open.paths")}
      board={@board}
      card={@card}
      form={@form}
      target={@target}
    />

    <.evidence_section
      :if={Slipdock.Verified.evidence?(@card) && on?(@panel, "open.evidence")}
      card={@card}
    />

    <.verify_section
      :if={@card.verify_state && on?(@panel, "open.verification")}
      card={@card}
      can_write={@can_write}
      target={@target}
      form_key={@form_key}
    />

    <.attachments_section
      :if={on?(@panel, "open.attachments")}
      at={@at}
      can_write={@can_write}
      transcribe={Slipdock.Transcription.available_to?(@current_user)}
      card={@card}
      target={@target}
      uploads={@uploads}
    />

    <.checklist_section
      :if={on?(@panel, "open.checklist")}
      target={@target}
      item={@card}
      can_write={@can_write}
      form_key={@form_key}
      section_key="e"
    />
    <.subcards_section
      :if={on?(@panel, "open.subcards")}
      board={@board}
      can_write={@can_write}
      card={@card}
      form_key={@form_key}
      picking_template={@picking_template}
      target={@target}
      templates={@templates}
      waiting={@waiting}
    />

    <.dependencies_section
      :if={on?(@panel, "open.dependencies")}
      board={@board}
      card={@card}
      card_link={@card_link}
      dep_direction={@dep_direction}
      dep_query={@dep_query}
      dep_results={@dep_results}
      form_key={@form_key}
      target={@target}
    />

    <.incident_section
      :if={on?(@panel, "open.incident")}
      board={@board}
      card={@card}
      card_link={@card_link}
      can_write={@can_write}
      incident={@incident}
      error={@incident_error}
      target={@target}
    />

    <.docs_section
      :if={on?(@panel, "open.docs")}
      board={@board}
      can_write={@can_write}
      doc_query={@doc_query}
      doc_results={@doc_results}
      pages={@pages}
      target={@target}
    />

    <.findings_line
      :if={@findings > 0 && on?(@panel, "open.findings")}
      board={@board}
      card={@card}
      count={@findings}
    />

    <.jobs_section
      :if={@jobs != [] && on?(@panel, "open.jobs")}
      can_write={@can_write}
      jobs={@jobs}
      target={@target}
      user={@current_user}
    />

    <.lead_time_line
      :if={@lead_time && on?(@panel, "open.lead_time")}
      lead_time={@lead_time}
    />

    <.links_section
      :if={on?(@panel, "open.links")}
      board={@board}
      can_write={@can_write}
      card={@card}
      form_key={@form_key}
      link_kind={@link_kind}
      link_query={@link_query}
      link_results={@link_results}
      target={@target}
    />

    <.urls_section
      :if={on?(@panel, "open.urls")}
      target={@target}
      item={@card}
      can_write={@can_write}
      form_key={@form_key}
      section_key="w"
    />
    """
  end

  defp on?(panel, key), do: MapSet.member?(panel, key)

  # The hidden sections with something waiting on the reader (#2031): a
  # rejected verification, an open wait. Hiding them is a display choice,
  # but these shouldn't vanish without a word.
  @doc false
  def hidden_attention(_card, _view, true), do: []

  def hidden_attention(card, view, false) do
    panel = Slipdock.CardViews.panel_shown(view, card.column_id)

    [
      {"open.verification", card.verify_state == "rejected", "a rejected verification"},
      {"open.wait", not is_nil(Card.open_wait(card)), "a question waiting on a person"}
    ]
    |> Enum.filter(fn {key, attention?, _} -> attention? and not MapSet.member?(panel, key) end)
    |> Enum.map(&elem(&1, 2))
  end
end
