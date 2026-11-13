defmodule SlipdockWeb.BoardLive.CardPanel.Chips do
  @moduledoc """
  The card panel's Flags and Tags rows: what is on the card, as chips, and
  the menus that add or take off one. Drawn by `BoardLive.CardPanel`'s
  header, which passes each the assigns it reads, by name.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.SlipdockComponents

  alias Slipdock.Boards.Card
  alias Slipdock.Palette

  attr :card, Card, required: true
  attr :can_write, :boolean, required: true
  attr :target, :any, required: true

  @doc "The Flags row: the card's flags as chips, and an Add that opens the list of the rest."
  def flags_row(assigns) do
    ~H"""
    <div
      id="card-flags"
      class="flex flex-wrap items-center gap-x-3 gap-y-1.5"
      data-section-key="f"
      data-section-popover="card-flags-menu"
    >
      <p class="flex w-16 shrink-0 items-center gap-1.5 section-label">
        <.icon name="hero-flag" class="size-3.5" />
        <.keyed_label key="f" label="Flags" />
      </p>
      <div class="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
        <.flag_chip
          :for={flag <- applied_flags(@card)}
          flag={flag}
          card={@card}
          removable={@can_write}
          phx-target={@target}
        />
        <button
          :if={@can_write}
          type="button"
          id="card-flags-add"
          popovertarget="card-flags-menu"
          class="btn btn-ghost btn-xs gap-1 font-normal text-base-content/60"
          aria-label="Add a flag"
        >
          <.icon name="hero-plus" class="size-3.5" /> Add
        </button>
        <span :if={!@can_write and @card.flags == []} class="text-xs text-base-content/40">
          None
        </span>
      </div>
      <div
        :if={@can_write}
        id="card-flags-menu"
        popover
        phx-hook="AnchoredPopover"
        data-anchor="card-flags-add"
        data-align="start"
        class="pop-menu"
      >
        <ul class="menu w-52 rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
          <li :for={{flag, label, icon, color, _} <- flags()}>
            <button
              type="button"
              id={"card-flag-pick-#{flag}"}
              role="menuitemcheckbox"
              aria-checked={to_string(flag in @card.flags)}
              phx-click="toggle_flag"
              phx-value-flag={flag}
              phx-target={@target}
              class="flex items-center gap-2"
            >
              <.icon
                name="hero-check"
                class={["size-4", if(flag in @card.flags, do: "text-primary", else: "invisible")]}
              />
              <.icon name={icon} class={["size-4", color]} />
              <span class="flex-1 text-left">{label}</span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :board, :any, required: true
  attr :card, Card, required: true
  attr :can_write, :boolean, required: true
  attr :tags_path, :string, required: true
  attr :target, :any, required: true

  @doc "The Tags row: the card's tags as chips, and an Add that opens the picker, which also makes a tag."
  def tags_row(assigns) do
    ~H"""
    <div
      id="card-tags"
      class="flex flex-wrap items-center gap-x-3 gap-y-1.5"
      data-section-key="t"
      data-section-popover="card-tags-menu"
    >
      <p class="flex w-16 shrink-0 items-center gap-1.5 section-label">
        <.icon name="hero-tag" class="size-3.5" />
        <.keyed_label key="t" label="Tags" />
      </p>
      <div class="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
        <span
          :for={tag <- Enum.sort_by(@card.tags, &String.downcase(&1.name))}
          id={"card-tag-#{tag.id}"}
          data-role="tag-chip"
          class={[
            "inline-flex items-center gap-1 rounded-full py-0.5 pl-2.5 text-xs font-medium",
            Palette.chip(tag.color),
            if(@can_write, do: "pr-1", else: "pr-2.5")
          ]}
        >
          {tag.name}
          <button
            :if={@can_write}
            type="button"
            phx-click="toggle_tag"
            phx-value-id={tag.id}
            phx-target={@target}
            class="rounded-full p-0.5 opacity-60 transition hover:bg-base-content/10 hover:opacity-100"
            title={"Remove “#{tag.name}”"}
            aria-label={"Remove the tag #{tag.name}"}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </span>
        <button
          :if={@can_write}
          type="button"
          id="card-tags-add"
          popovertarget="card-tags-menu"
          class="btn btn-ghost btn-xs gap-1 font-normal text-base-content/60"
          aria-label="Add a tag"
        >
          <.icon name="hero-plus" class="size-3.5" /> Add
        </button>
        <span :if={!@can_write and @card.tags == []} class="text-xs text-base-content/40">
          None
        </span>
      </div>
      <div
        :if={@can_write}
        id="card-tags-menu"
        popover
        phx-hook="AnchoredPopover"
        data-anchor="card-tags-add"
        data-align="start"
        class="pop-menu"
      >
        <div class="w-64 rounded-xl bg-base-100 p-1 text-sm shadow-xl ring-1 ring-base-content/10">
          <%!-- One box: it narrows the list as you type, and Enter makes a
                tag of what is typed (or applies the one of that name). --%>
          <.form
            for={%{}}
            as={:tag}
            id="card-tag-search"
            phx-submit="create_tag"
            phx-target={@target}
            phx-hook="TagFilter"
            data-list="card-tags-list"
            class="p-1"
          >
            <input
              type="text"
              name="name"
              id="card-tag-search-input"
              maxlength="30"
              autocomplete="off"
              placeholder="Search or name a new tag"
              aria-label="Search tags"
              class="input field-bare w-full"
            />
          </.form>
          <ul id="card-tags-list" class="menu max-h-64 w-full flex-nowrap overflow-y-auto p-0">
            <li
              :for={tag <- @board.tags}
              data-tag-name={tag.name}
            >
              <button
                type="button"
                id={"card-tag-pick-#{tag.id}"}
                role="menuitemcheckbox"
                aria-checked={to_string(Enum.any?(@card.tags, &(&1.id == tag.id)))}
                phx-click="toggle_tag"
                phx-value-id={tag.id}
                phx-target={@target}
                class="flex items-center gap-2"
              >
                <.icon
                  name="hero-check"
                  class={[
                    "size-4",
                    if(Enum.any?(@card.tags, &(&1.id == tag.id)),
                      do: "text-primary",
                      else: "invisible"
                    )
                  ]}
                />
                <span class={["size-2 shrink-0 rounded-full", Palette.dot(tag.color)]}></span>
                <span class="min-w-0 flex-1 truncate text-left">{tag.name}</span>
              </button>
            </li>
            <li
              data-role="no-tags"
              hidden={@board.tags != []}
              class="px-3 py-1.5 text-xs text-base-content/50"
            >
              No tags match.
            </li>
          </ul>
          <div class="border-t border-base-content/10 p-1">
            <button
              type="submit"
              form="card-tag-search"
              id="card-tag-create"
              data-role="new-tag"
              hidden
              class="btn btn-ghost btn-sm w-full justify-start gap-1.5 font-normal"
            >
              <.icon name="hero-plus" class="size-4" />
              <span>New tag “<span data-role="new-tag-name"></span>”</span>
            </button>
            <.link
              id="card-tag-manage"
              data-role="manage-tags"
              patch={@tags_path}
              class="btn btn-ghost btn-sm w-full justify-start gap-1.5 font-normal"
            >
              <.icon name="hero-plus" class="size-4" /> New tag
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The card's flags in the order the picker lists them.
  defp applied_flags(card),
    do: for({flag, _, _, _, _} <- flags(), Enum.member?(card.flags, flag), do: flag)

  attr :flag, :string, required: true
  attr :card, :any, required: true
  attr :removable, :boolean, default: false
  attr :rest, :global

  # An applied flag (#1727): its colour, icon and name, and an × to take it
  # off for someone who may. Filled when a person has to act on it, outline
  # only when the board's own processes clear it (#2624), and its tooltip
  # says which.
  defp flag_chip(assigns) do
    {_, label, icon, color, active_cls} = List.keyfind!(flags(), assigns.flag, 0)
    {attention, why} = flag_attention(assigns.flag, assigns.card)

    assigns =
      assign(assigns,
        label: label,
        icon_name: flag_icon_name(icon, attention),
        color: color,
        chip_cls: if(attention == "auto", do: [color, "ring-current/50"], else: active_cls),
        attention: attention,
        tip: flag_tip(label, attention, why)
      )

    ~H"""
    <span
      id={"card-flag-#{@flag}"}
      data-role="flag-chip"
      data-attention={@attention}
      title={@tip}
      class={[
        "inline-flex items-center gap-1 rounded-full py-0.5 pl-2 text-xs font-medium ring-1",
        @chip_cls,
        if(@removable, do: "pr-1", else: "pr-2.5")
      ]}
    >
      <.icon name={@icon_name} class={["size-3.5", @color]} />
      {@label}
      <.icon :if={@attention == "person"} name="hero-hand-raised" class="size-3 opacity-70" />
      <span :if={@attention == "auto"} class="font-normal opacity-70">· clears itself</span>
      <span class="sr-only">{@tip}</span>
      <button
        :if={@removable}
        type="button"
        phx-click="toggle_flag"
        phx-value-flag={@flag}
        class="rounded-full p-0.5 opacity-60 transition hover:bg-base-content/10 hover:opacity-100"
        title={"Remove “#{@label}”"}
        aria-label={"Remove the flag #{@label}"}
        {@rest}
      >
        <.icon name="hero-x-mark" class="size-3" />
      </button>
    </span>
    """
  end
end
