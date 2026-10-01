defmodule SlipdockWeb.ShareComponents do
  @moduledoc "Sharing UI: who has access to a board, card or view, and a form to grant more."
  use SlipdockWeb, :html

  alias Slipdock.Access.Grant
  alias Slipdock.Accounts.User

  attr :resource, :string, required: true, doc: "board | card | view"
  attr :grants, :list, required: true
  attr :groups, :list, required: true, doc: "groups the current user can pick"
  attr :can_manage, :boolean, required: true
  attr :form_key, :integer, required: true
  attr :compact, :boolean, default: false

  def share_panel(assigns) do
    ~H"""
    <div class="space-y-2">
      <p :if={@grants == [] and !@can_manage} class="text-xs text-base-content/50">
        Not shared with anyone else.
      </p>
      <ul :if={@grants != []} class="space-y-1">
        <li
          :for={g <- @grants}
          id={"grant-#{@resource}-#{g.id}"}
          class="flex items-center gap-2 rounded-lg px-1 py-1 text-sm hover:bg-base-200/60"
        >
          <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-2xs font-bold">
            <.icon :if={Grant.subject_type(g) == :group} name="hero-user-group" class="size-3.5" />
            <span :if={Grant.subject_type(g) == :user}>{User.initials(g.user)}</span>
          </span>
          <span class="min-w-0 flex-1 truncate">
            {if Grant.subject_type(g) == :group, do: g.group.name, else: User.display_name(g.user)}
            <span :if={Grant.subject_type(g) == :user and g.user.name} class="text-base-content/50">· {g.user.email}</span>
          </span>
          <span class={[
            "badge badge-xs",
            if(g.level == "write", do: "badge-primary", else: "badge-ghost")
          ]}>
            {if g.level == "write", do: "can edit", else: "read only"}
          </span>
          <button
            :if={@can_manage}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="revoke_grant"
            phx-value-id={g.id}
            phx-value-resource={@resource}
            title="Remove access"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ul>
      <form
        :if={@can_manage}
        id={"share-#{@resource}-#{@form_key}"}
        phx-submit="share"
        class={["flex flex-wrap items-center gap-1.5", @compact && "text-xs"]}
      >
        <input type="hidden" name="resource" value={@resource} />
        <select
          name="group"
          class="select select-xs w-36"
          title="Share with a group, or leave on 'a person' and enter an email"
        >
          <option value="">a person (by email)</option>
          <option :for={g <- @groups} value={g.id}>group: {g.name}</option>
        </select>
        <input
          type="email"
          name="email"
          placeholder="email@example.com"
          class="input input-xs w-44"
          autocomplete="off"
        />
        <select name="level" class="select select-xs w-28">
          <option value="read">read only</option>
          <option value="write">can edit</option>
        </select>
        <button type="submit" class="btn btn-xs btn-primary">Share</button>
      </form>
    </div>
    """
  end
end
