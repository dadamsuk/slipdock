defmodule SlipdockWeb.TableComponents do
  @moduledoc "The table view of a board: one row per card, grouped, sortable, with inline edits."
  use SlipdockWeb, :html
  alias SlipdockWeb.Dates

  import SlipdockWeb.SlipdockComponents
  alias Slipdock.Palette
  alias Slipdock.Swimlanes.Config
  alias Slipdock.Table

  # How many tag chips a row shows before "+N".
  @tags_shown 2

  attr :board, :any, required: true
  attr :config, Config, required: true
  attr :rows, :map, required: true, doc: "from Slipdock.Table.rows/2"
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :can_write, :boolean, default: true
  attr :quick_preview, :map, default: %{}, doc: "quick-add previews by form id"
  attr :narrow, :boolean, default: false, doc: "stack each row instead of laying out columns"

  def table_view(%{narrow: true} = assigns), do: table_stack(assigns)

  def table_view(assigns) do
    assigns =
      assign(assigns,
        fields: Table.visible_fields(assigns.config, assigns.board),
        first_column: List.first(assigns.board.columns),
        # Each group gets its own add row when what it stands for can be set on a new card.
        group_add?:
          assigns.can_write and assigns.rows.grouped and
            not Enum.member?(~w(none created updated dependencies goal), assigns.config.rows)
      )

    ~H"""
    <div id="table-scroll" class="kanban-scroll h-full overflow-auto">
      <.view_empty
        :if={@rows.groups == []}
        icon="hero-table-cells"
        hidden={@rows.hidden}
        config={@config}
      >
        <.quick_add_row
          :if={@can_write and not is_nil(@first_column) and not Config.filtering?(@config)}
          id="table-add"
          placeholder={"Add a card to #{@first_column.name}…"}
          preview={@quick_preview["table-add"]}
          class="justify-center text-sm text-base-content"
        />
      </.view_empty>

      <fieldset :if={@rows.groups != []} disabled={!@can_write} class="contents">
        <table
          id="card-table"
          class={[
            "table table-pin-rows w-full",
            if(@config.density == "compact", do: "table-xs", else: "table-sm")
          ]}
        >
          <thead>
            <tr class="bg-base-100 text-xs uppercase tracking-wide text-base-content/60">
              <th
                :for={{key, label, sort} <- @fields}
                class={[
                  key == "title" && "w-[40%] min-w-64",
                  Enum.member?(~w(completed id), key) && "w-16"
                ]}
              >
                <span
                  :if={sort}
                  role="button"
                  tabindex="0"
                  class={[
                    "inline-flex cursor-pointer items-center gap-1 uppercase hover:text-base-content",
                    @config.sort == sort && "text-primary"
                  ]}
                  phx-click="table_sort"
                  phx-value-sort={sort}
                  title={"Sort by #{label}"}
                >
                  {label}
                  <.icon
                    :if={@config.sort == sort}
                    name={if @config.dir == "asc", do: "hero-arrow-up", else: "hero-arrow-down"}
                    class="size-3"
                  />
                </span>
                <span :if={!sort}>{label}</span>
              </th>
            </tr>
          </thead>
          <tbody :for={group <- @rows.groups} id={"group-#{group.key}"}>
            <tr
              :if={@rows.grouped}
              class={[
                "bg-base-200/70",
                group.tone == :current && "text-primary",
                group.tone == :past && "text-error/80"
              ]}
            >
              <td colspan={length(@fields)} class="p-0">
                <span
                  role="button"
                  tabindex="0"
                  class="flex w-full cursor-pointer items-center gap-2 px-3 py-1.5 text-left text-sm font-semibold hover:bg-base-200"
                  phx-click="swim_toggle_row"
                  phx-value-key={group.key}
                >
                  <.icon
                    name={
                      if MapSet.member?(@collapsed, group.key),
                        do: "hero-chevron-right",
                        else: "hero-chevron-down"
                    }
                    class="size-3.5 text-base-content/50"
                  />
                  <span :if={group.color} class={["size-2.5 rounded-full", Palette.dot(group.color)]}></span>
                  {group.label}
                  <span :if={group.tone == :current} class="badge badge-primary badge-xs">now</span>
                  <span class="badge badge-ghost badge-sm ml-1 font-mono">{group.count}</span>
                  <span
                    :for={{field, total} <- Table.group_sums(group.cards, @board)}
                    class="badge badge-ghost badge-sm font-mono font-normal"
                    title={"Total #{field.name} in this group"}
                  >
                    Σ {field.name} {Slipdock.Fields.format(field, total)}
                  </span>
                </span>
              </td>
            </tr>
            <tr
              :for={card <- if(MapSet.member?(@collapsed, group.key), do: [], else: group.cards)}
              id={"row-#{group.key}-#{SlipdockWeb.SlipdockComponents.item_id(card)}"}
              class={[
                "hover:bg-base-200/40",
                (card.completed or Slipdock.Boards.Card.snoozed?(card)) && "opacity-60"
              ]}
            >
              <%!-- max-w-0 stops a long title's nowrap text from widening
                    the column past its 40%: the cell takes its share and
                    the title truncates (full title on hover). --%>
              <td
                :for={{key, _label, _} <- @fields}
                class={["align-middle", key == "title" && "max-w-0"]}
              >
                <.cell field={key} card={card} board={@board} />
              </td>
            </tr>
            <tr :if={@group_add? and not MapSet.member?(@collapsed, group.key)}>
              <td colspan={length(@fields)} class="py-0.5">
                <.quick_add_row
                  id={"table-add-#{group.key}"}
                  params={%{"group" => group.key}}
                  placeholder={"Add a card to #{group.label}…"}
                  preview={@quick_preview["table-add-#{group.key}"]}
                />
              </td>
            </tr>
          </tbody>
          <tbody :if={@can_write and not @group_add? and not is_nil(@first_column)}>
            <tr>
              <td colspan={length(@fields)} class="py-1">
                <.quick_add_row
                  id="table-add"
                  placeholder={"Add a card to #{@first_column.name}…"}
                  preview={@quick_preview["table-add"]}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </fieldset>
    </div>
    """
  end

  # The table as a phone reads it: a card per row, not a row of columns.
  #
  # The desktop table gives the title 40% and every other field a fixed
  # width; on 390 points that is one column of titles and everything else
  # past the right edge — which is what a phone showed before this: a list
  # of names and nothing to do with them. Stacked, each card gets its title
  # and then its fields as labelled lines, and every one of them is the
  # same editable `cell/1` the table uses, so the inline edits still work.
  defp table_stack(assigns) do
    fields = Table.visible_fields(assigns.config, assigns.board)

    assigns =
      assign(assigns,
        fields: fields,
        title_field: Enum.find(fields, &(elem(&1, 0) == "title")),
        done_field: Enum.find(fields, &(elem(&1, 0) == "completed")),
        detail_fields: Enum.reject(fields, &Enum.member?(~w(title completed), elem(&1, 0))),
        first_column: List.first(assigns.board.columns),
        group_add?:
          assigns.can_write and assigns.rows.grouped and
            not Enum.member?(~w(none created updated dependencies goal), assigns.config.rows)
      )

    ~H"""
    <div id="table-scroll" class="kanban-scroll h-full overflow-y-auto">
      <.view_empty
        :if={@rows.groups == []}
        icon="hero-table-cells"
        hidden={@rows.hidden}
        config={@config}
      >
        <.quick_add_row
          :if={@can_write and not is_nil(@first_column) and not Config.filtering?(@config)}
          id="table-add"
          placeholder={"Add a card to #{@first_column.name}…"}
          preview={@quick_preview["table-add"]}
          class="justify-center text-sm text-base-content"
        />
      </.view_empty>

      <fieldset :if={@rows.groups != []} disabled={!@can_write} class="contents">
        <div id="card-table">
          <section :for={group <- @rows.groups} id={"group-#{group.key}"}>
            <% collapsed = MapSet.member?(@collapsed, group.key) %>
            <button
              :if={@rows.grouped}
              type="button"
              class={[
                "sticky top-0 z-20 flex w-full items-center gap-2 border-y border-base-300 bg-base-100 px-3 py-2 text-left text-sm font-semibold",
                group.tone == :current && "text-primary",
                group.tone == :past && "text-error/80"
              ]}
              phx-click="swim_toggle_row"
              phx-value-key={group.key}
              aria-expanded={to_string(!collapsed)}
            >
              <.icon
                name={if collapsed, do: "hero-chevron-right", else: "hero-chevron-down"}
                class="size-4 shrink-0 text-base-content/50"
              />
              <span
                :if={group.color}
                class={["size-2.5 shrink-0 rounded-full", Palette.dot(group.color)]}
              ></span>
              <span class="truncate">{group.label}</span>
              <span :if={group.tone == :current} class="badge badge-primary badge-xs">now</span>
              <span class="badge badge-ghost badge-sm ml-auto font-mono">{group.count}</span>
            </button>

            <ul :if={not collapsed} class="divide-y divide-base-300/60">
              <li
                :for={card <- group.cards}
                id={"row-#{group.key}-#{SlipdockWeb.SlipdockComponents.item_id(card)}"}
                class={[
                  "space-y-1.5 px-3 py-2.5",
                  (card.completed or Slipdock.Boards.Card.snoozed?(card)) && "opacity-60"
                ]}
              >
                <div class="flex items-start gap-2">
                  <span :if={@done_field} class="pt-0.5">
                    <.cell field="completed" card={card} board={@board} />
                  </span>
                  <span :if={@title_field} class="min-w-0 flex-1">
                    <.cell field="title" card={card} board={@board} />
                  </span>
                </div>
                <dl
                  :if={@detail_fields != []}
                  class="grid grid-cols-[5.5rem_minmax(0,1fr)] items-center gap-x-2 gap-y-1"
                >
                  <div :for={{key, label, _} <- @detail_fields} class="contents">
                    <dt class="truncate text-2xs uppercase tracking-wide text-base-content/45">
                      {label}
                    </dt>
                    <dd class="min-w-0"><.cell field={key} card={card} board={@board} /></dd>
                  </div>
                </dl>
              </li>
              <li :if={@group_add?} class="px-3 py-1">
                <.quick_add_row
                  id={"table-add-#{group.key}"}
                  params={%{"group" => group.key}}
                  placeholder={"Add a card to #{group.label}…"}
                  preview={@quick_preview["table-add-#{group.key}"]}
                />
              </li>
            </ul>
          </section>

          <div :if={@can_write and not @group_add? and not is_nil(@first_column)} class="px-3 py-2">
            <.quick_add_row
              id="table-add"
              placeholder={"Add a card to #{@first_column.name}…"}
              preview={@quick_preview["table-add"]}
            />
          </div>
        </div>
      </fieldset>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :card, :map, required: true
  attr :board, :any, required: true

  defp cell(%{field: "title"} = assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-2">
      <span :if={@card.color} class={["size-2 shrink-0 rounded-full", Palette.dot(@card.color)]}></span>
      <%!-- A placed wiki page's icon opens the document; its title opens the
            panel, exactly as it does on the board. --%>
      <SlipdockWeb.SlipdockComponents.doc_link
        :if={SlipdockWeb.SlipdockComponents.page?(@card)}
        path={"/boards/#{@card.board_id}/wiki/#{@card.slug}"}
        class="size-3.5"
      />
      <span
        role="link"
        tabindex="0"
        class={[
          "cursor-pointer truncate text-left font-medium hover:underline",
          @card.completed && "text-base-content/50"
        ]}
        phx-click={if SlipdockWeb.SlipdockComponents.page?(@card), do: "open_page", else: "open_card"}
        phx-value-id={@card.id}
        title={@card.title}
      >
        {@card.title}
      </span>
      <span
        :if={(@card.description || "") != ""}
        class="shrink-0 text-base-content/40"
        title="Has description"
      >
        <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
      </span>
    </div>
    """
  end

  defp cell(%{field: "column"} = assigns) do
    ~H"""
    <form
      phx-change="table_update"
      phx-submit="table_update"
      id={"col-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
    >
      <input type="hidden" name="card_id" value={SlipdockWeb.SlipdockComponents.item_id(@card)} />
      <input type="hidden" name="field" value="column_id" />
      <select name="value" class="select field-bare w-40">
        <option :for={col <- @board.columns} value={col.id} selected={col.id == @card.column_id}>
          {col.name}
        </option>
      </select>
    </form>
    """
  end

  defp cell(%{field: "priority"} = assigns) do
    ~H"""
    <form
      phx-change="table_update"
      phx-submit="table_update"
      id={"prio-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
    >
      <input type="hidden" name="card_id" value={SlipdockWeb.SlipdockComponents.item_id(@card)} />
      <input type="hidden" name="field" value="priority" />
      <div class="flex items-center gap-1">
        <.priority_badge priority={@card.priority} />
        <select name="value" class="select field-bare w-28" aria-label="Priority">
          <option
            :for={{label, value} <- priority_options()}
            value={value}
            selected={value == @card.priority}
          >
            {label}
          </option>
        </select>
      </div>
    </form>
    """
  end

  defp cell(%{field: "assignee"} = assigns) do
    ~H"""
    <div class="flex min-w-0 max-w-48 flex-nowrap items-center gap-1">
      <%!-- The runner loop holding the card (#2027), beside the people. --%>
      <SlipdockWeb.LoopComponents.loop_chip
        id={"table-loop-#{@card.id}"}
        loop={Slipdock.CardState.loop(@card)}
        href={SlipdockWeb.LoopComponents.job_href(@card, Slipdock.CardState.loop(@card))}
      />
      <.assignee_chips users={Slipdock.Boards.Card.assignees(@card)} size="xs" with_name />
    </div>
    """
  end

  defp cell(%{field: "start_date"} = assigns) do
    ~H"""
    <form
      phx-change="table_update"
      phx-submit="table_update"
      id={"start-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
    >
      <input type="hidden" name="card_id" value={SlipdockWeb.SlipdockComponents.item_id(@card)} />
      <input type="hidden" name="field" value="start_date" />
      <.date_field
        id={"start-date-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
        name="value"
        value={@card.start_date}
        bare
        aria-label="Start date"
      />
    </form>
    """
  end

  # One due value per row (#1731): the card's own date in a `date_field`,
  # coloured by its state, or, when it has none, the date rolled up from its
  # subcards as the field's muted placeholder. A slip past the card's own
  # date is an icon with the sentence on hover, so the cell stays one line.
  defp cell(%{field: "due_date"} = assigns) do
    card = assigns.card
    due = Slipdock.Boards.Card.effective_due(card)
    derived = is_nil(card.due_date) and Slipdock.Boards.Card.due_derived?(card)
    rollup = Map.get(card, :rollup)

    slips =
      if card.completed,
        do: [],
        else:
          for(
            {which, days, on} <- [
              {:start, Slipdock.Boards.Card.start_slip(card), rollup && rollup.derived_start},
              {:due, Slipdock.Boards.Card.due_slip(card), rollup && rollup.derived_due}
            ],
            days > 0,
            do: past_date_detail(which, days, on)
          )

    assigns =
      assign(assigns,
        state: due_state(due, card.completed),
        derived: derived,
        placeholder: if(derived, do: Dates.short(due), else: "Add date"),
        slips: slips
      )

    ~H"""
    <form
      phx-change="table_update"
      phx-submit="table_update"
      id={"due-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
      class="flex items-center gap-1"
      data-due={@state}
      data-derived={@derived}
    >
      <input type="hidden" name="card_id" value={SlipdockWeb.SlipdockComponents.item_id(@card)} />
      <input type="hidden" name="field" value="due_date" />
      <.date_field
        id={"due-date-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
        name="value"
        value={@card.due_date}
        placeholder={@placeholder}
        bare
        class="table-due"
        aria-label="Due date"
      />
      <span
        :for={slip <- @slips}
        class="table-slip shrink-0 text-amber-600 dark:text-amber-300"
        title={slip}
      >
        <.icon name="hero-arrow-trending-up" class="size-3.5" />
      </span>
    </form>
    """
  end

  defp cell(%{field: "completed"} = assigns) do
    ~H"""
    <input
      type="checkbox"
      class="checkbox"
      checked={@card.completed}
      phx-click="toggle_complete"
      phx-value-id={@card.id}
      title={if @card.completed, do: "Mark incomplete", else: "Mark complete"}
    />
    """
  end

  defp cell(%{field: "percent_complete"} = assigns) do
    ~H"""
    <form
      phx-change="table_update"
      phx-submit="table_update"
      id={"percent-#{SlipdockWeb.SlipdockComponents.item_id(@card)}"}
      class="flex items-center gap-1"
    >
      <input type="hidden" name="card_id" value={SlipdockWeb.SlipdockComponents.item_id(@card)} />
      <input type="hidden" name="field" value="percent_complete" />
      <input
        type="number"
        name="value"
        value={@card.percent_complete}
        min="0"
        max="100"
        step="5"
        phx-debounce="400"
        class="input field-bare w-16"
      />
      <span class="text-xs text-base-content/50">%</span>
    </form>
    """
  end

  defp cell(%{field: "time"} = assigns) do
    ~H"""
    <SlipdockWeb.SlipdockComponents.time_badge
      :if={Slipdock.TimeTracking.tracked?(@card)}
      card={@card}
    />
    """
  end

  defp cell(%{field: "flags"} = assigns) do
    ~H"""
    <span class="flex items-center gap-1"><.flag_icon
      :for={flag <- @card.flags}
      flag={flag}
      card={@card}
      class="size-3.5"
    /></span>
    """
  end

  # Tags keep to one line (#1731): the first few, then "+N", and every name
  # in the tooltip, so a long list doesn't make its row taller.
  defp cell(%{field: "tags"} = assigns) do
    tags = assigns.card.tags

    assigns =
      assign(assigns,
        shown: Enum.take(tags, @tags_shown),
        more: max(length(tags) - @tags_shown, 0),
        names: Enum.map_join(tags, ", ", & &1.name)
      )

    ~H"""
    <span :if={@shown != []} class="table-tags flex flex-nowrap items-center gap-1" title={@names}><span
      :for={tag <- @shown}
      class="table-tag"
    ><.tag_chip tag={tag} size="xs" /></span><span
      :if={@more > 0}
      data-role="more-tags"
      class="inline-flex shrink-0 items-center rounded-md px-1.5 py-0.5 text-2xs font-medium leading-none text-base-content/70 ring-1 ring-inset ring-base-content/20"
    >+{@more}</span></span>
    """
  end

  defp cell(%{field: "checklist"} = assigns) do
    done = Enum.count(assigns.card.checklist_items, & &1.done)
    total = length(assigns.card.checklist_items)
    assigns = assign(assigns, done: done, total: total)

    ~H"""
    <span :if={@total > 0} class={["font-mono text-xs", @done == @total && "text-success"]}>{@done}/{@total}</span>
    """
  end

  defp cell(%{field: "comments"} = assigns) do
    ~H"""
    <span :if={@card.comments != []} class="inline-flex items-center gap-1 text-xs"><.icon
      name="hero-chat-bubble-left"
      class="size-3.5"
    /> {length(@card.comments)}</span>
    """
  end

  defp cell(%{field: "dependencies"} = assigns), do: ~H"<.dependency_badge card={@card} />"
  defp cell(%{field: "subcards"} = assigns), do: ~H"<.subcards_badge card={@card} />"

  defp cell(%{field: "health"} = assigns) do
    ~H"""
    <span class="flex items-center gap-1">
      <.health_pill health={Slipdock.Boards.Card.health(@card)} />
      <.stated_pill
        :if={Slipdock.Boards.Card.stated_health(@card)}
        health={Slipdock.Boards.Card.stated_health(@card)}
        with_label={false}
      />
    </span>
    """
  end

  defp cell(%{field: "color"} = assigns) do
    ~H"""
    <span :if={@card.color} class="inline-flex items-center gap-1 text-xs"><span class={[
      "size-3 rounded-full",
      Palette.dot(@card.color)
    ]}></span> {Palette.label(@card.color)}</span>
    """
  end

  defp cell(%{field: "created"} = assigns) do
    ~H"""
    <span
      class="text-xs text-base-content/60"
      title={Dates.exact(@card.inserted_at)}
    >{relative_time(@card.inserted_at)}</span>
    """
  end

  defp cell(%{field: "updated"} = assigns) do
    ~H"""
    <span
      class="text-xs text-base-content/60"
      title={Dates.exact(@card.updated_at)}
    >{relative_time(@card.updated_at)}</span>
    """
  end

  defp cell(%{field: "votes"} = assigns) do
    ~H"""
    <span :if={Slipdock.Boards.Card.vote_total(@card) > 0} class="chip chip-line" title="Votes">
      <.icon name="hero-hand-thumb-up" class="size-3" /> {Slipdock.Boards.Card.vote_total(@card)}
    </span>
    """
  end

  defp cell(%{field: "goal"} = assigns) do
    assigns = assign(assigns, goals: Slipdock.Boards.Card.goals(assigns.card))

    ~H"""
    <span class="flex flex-wrap gap-1">
      <span
        :for={goal <- @goals}
        role="link"
        tabindex="0"
        class="chip chip-line max-w-48 cursor-pointer truncate hover:underline"
        phx-click="open_card"
        phx-value-id={goal.id}
        title={goal.title}
      >
        <.icon name="hero-flag" class="size-3" /> {goal.title}
      </span>
    </span>
    """
  end

  # Both directions, each with its own wording ("Duplicated by", not "Duplicates").
  defp cell(%{field: "links"} = assigns) do
    out = if is_list(assigns.card.links_out), do: assigns.card.links_out, else: []
    inn = if is_list(assigns.card.links_in), do: assigns.card.links_in, else: []

    lines =
      Enum.map(out, &"#{Slipdock.Boards.CardLink.label(&1.kind, :out)} #{&1.to.title}") ++
        Enum.map(inn, &"#{Slipdock.Boards.CardLink.label(&1.kind, :in)} #{&1.from.title}")

    assigns = assign(assigns, lines: lines)

    ~H"""
    <span
      :if={@lines != []}
      class="inline-flex items-center gap-1 text-xs"
      title={Enum.join(@lines, "; ")}
    ><.icon name="hero-arrows-right-left" class="size-3.5" /> {length(@lines)}</span>
    """
  end

  defp cell(%{field: "f:" <> _} = assigns) do
    field = Config.custom_field(assigns.field, assigns.board)
    value = field && Slipdock.Fields.value(assigns.card, field)
    assigns = assign(assigns, fdef: field, value: value)

    ~H"""
    <span
      :if={@fdef && not is_nil(@value)}
      class={["text-xs", @fdef.kind == "formula" && "font-mono font-semibold"]}
    >
      <%= case @fdef.kind do %>
        <% "rating" -> %>
          <span
            class="text-amber-500"
            title={"#{round(@value)} of #{Slipdock.Boards.FieldDefinition.rating_max(@fdef)}"}
          >
            {String.duplicate("★", round(@value))}
          </span>
        <% "select" -> %>
          <% option = Enum.find(@fdef.options, &(&1["key"] == @value)) %>
          <span class={[
            "chip",
            if(option && option["color"], do: Palette.chip(option["color"]), else: "chip-line")
          ]}>
            {Slipdock.Fields.format(@fdef, @value)}
          </span>
        <% _ -> %>
          {Slipdock.Fields.format(@fdef, @value)}
      <% end %>
    </span>
    """
  end

  defp cell(%{field: "id"} = assigns) do
    ~H"""
    <span class="font-mono text-xs text-base-content/50">#{@card.id}</span>
    """
  end
end
