defmodule SlipdockWeb.AccountLive.TokensComponent do
  @moduledoc """
  The API tokens tab: minting a token for the CLI or a script, showing its
  plaintext exactly once, and the list to revoke from.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Accounts

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Loaded once; a later update from the parent must not drop a token that
    # is on screen waiting to be copied.
    if Map.has_key?(socket.assigns, :tokens),
      do: {:ok, socket},
      else: {:ok, socket |> assign(new_token: nil, form_key: 0) |> load_tokens()}
  end

  defp load_tokens(socket),
    do: assign(socket, tokens: Accounts.list_api_tokens(socket.assigns.current_user))

  @impl true
  def handle_event("create_token", params, socket) do
    label = params["label"] |> to_string() |> String.trim()
    label = if label == "", do: "CLI", else: label

    {token, _} =
      Accounts.create_api_token(socket.assigns.current_user, label,
        scope: params["scope"],
        expires_at: Accounts.expiry_in_days(params["expires_in_days"])
      )

    {:noreply,
     socket |> assign(new_token: token) |> update(:form_key, &(&1 + 1)) |> load_tokens()}
  end

  def handle_event("delete_token", %{"id" => id}, socket) do
    if id = SlipdockWeb.Params.id(id),
      do: :ok = Accounts.delete_api_token(socket.assigns.current_user, id)

    {:noreply, socket |> assign(new_token: nil) |> load_tokens()}
  end

  def handle_event("dismiss_token", _, socket), do: {:noreply, assign(socket, new_token: nil)}

  defp relative_time(dt), do: SlipdockWeb.SlipdockComponents.relative_time(dt)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">API tokens</h2>
        <p class="text-sm text-base-content/60">
          For the <code>slipdock</code>
          CLI and scripts. Run <code>slipdock auth &lt;token&gt;</code>
          after creating one.
        </p>
        <div :if={@new_token} class="mt-4 rounded-xl bg-warning/10 p-4 text-sm">
          <p class="font-medium">Copy this token now — it won't be shown again.</p>
          <code
            id="new-token"
            class="mt-2 block select-all break-all rounded bg-base-200 px-2 py-1 font-mono text-xs"
          >{@new_token}</code>
          <button
            type="button"
            class="btn btn-ghost btn-xs mt-2"
            phx-click="dismiss_token"
            phx-target={@myself}
          >Done</button>
        </div>
        <form
          id={"token-form-#{@form_key}"}
          phx-submit="create_token"
          phx-target={@myself}
          class="mt-4 flex flex-wrap items-center gap-2"
        >
          <input
            type="text"
            name="label"
            placeholder="Label (e.g. laptop)"
            class="input input-sm min-w-40 flex-1"
            autocomplete="off"
          />
          <select name="scope" class="select select-sm" aria-label="What this token may do">
            <option value="write">Read and write</option>
            <option value="read">Read only</option>
            <option :if={Accounts.admin?(@current_user)} value="admin">
              Administer this server
            </option>
          </select>
          <select name="expires_in_days" class="select select-sm" aria-label="When it expires">
            <option value="">Never expires</option>
            <option value="30">Expires in 30 days</option>
            <option value="90">Expires in 90 days</option>
            <option value="365">Expires in a year</option>
          </select>
          <button type="submit" class="btn btn-primary btn-sm">Create token</button>
        </form>
        <ul class="mt-4 divide-y divide-base-content/10">
          <li
            :for={t <- @tokens}
            id={"token-#{t.id}"}
            class="flex items-center gap-3 py-2 text-sm"
          >
            <.icon name="hero-key" class="size-4 text-base-content/40" />
            <span class="flex min-w-0 flex-1 flex-col">
              <span class="flex items-center gap-2">
                <span class="truncate font-medium">{t.label}</span>
                <span class={[
                  "rounded px-1.5 py-0.5 text-[11px] font-medium",
                  if(t.scope == "read",
                    do: "bg-base-200 text-base-content/70",
                    else: "bg-primary/10 text-primary"
                  )
                ]}>
                  {case t.scope do
                    "read" -> "read only"
                    "admin" -> "admin"
                    _ -> "read/write"
                  end}
                </span>
                <span
                  :if={t.oauth_client_id}
                  class="rounded bg-base-200 px-1.5 py-0.5 text-[11px] font-medium text-base-content/70"
                  title="Connected with OAuth: its token renews itself every hour"
                >
                  connected app
                </span>
                <span
                  :if={Slipdock.Accounts.UserToken.lapsed?(t)}
                  class="rounded bg-error/10 px-1.5 py-0.5 text-[11px] font-medium text-error"
                >
                  expired
                </span>
              </span>
              <span class="text-xs text-base-content/50">
                created {relative_time(t.inserted_at)}<span :if={t.last_used_at}> · used {relative_time(
                  t.last_used_at
                )}<span :if={t.last_used_ip}> from {t.last_used_ip}</span></span><span :if={
                  t.refresh_expires_at
                }> · {if Slipdock.Accounts.UserToken.lapsed?(t),
                  do: "expired " <> relative_time(t.refresh_expires_at),
                  else: "renews until " <> relative_time(t.refresh_expires_at)}</span><span :if={
                  t.expires_at && is_nil(t.refresh_expires_at)
                }> · {if Slipdock.Accounts.UserToken.expired?(t),
                  do: "expired " <> relative_time(t.expires_at),
                  else: "expires " <> relative_time(t.expires_at)}</span><span :if={
                  is_nil(t.expires_at)
                }> · never expires</span>
              </span>
            </span>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete_token"
              phx-target={@myself}
              phx-value-id={t.id}
              data-confirm="Revoke this token?"
            >Revoke</button>
          </li>
        </ul>
        <p :if={@tokens == []} class="mt-3 text-sm text-base-content/50">No tokens yet.</p>
      </section>
    </div>
    """
  end
end
