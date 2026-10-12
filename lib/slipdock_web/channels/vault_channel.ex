defmodule SlipdockWeb.VaultChannel do
  @moduledoc """
  `vault:<id>` — tells a connected client a vault has changed, so it polls
  `GET /api/vaults/:id/changes?since=<cursor>` now rather than on a timer
  (W-103 R2.8). Each push is `"change"` with `%{"cursor" => n}`: the newest
  cursor there is. The feed itself stays the one source of truth; this only
  says when to read it.

  Only the vault's owner may join, by the vault's id or name.
  """
  use SlipdockWeb, :channel

  alias Slipdock.Vaults
  alias Slipdock.Wiki.Changes

  @impl true
  def join("vault:" <> ref, _params, socket) do
    case Vaults.get_vault(socket.assigns.current_user, ref) do
      {:ok, vault} ->
        Changes.subscribe(vault.id)
        {:ok, %{vault_id: vault.id}, assign(socket, :vault_id, vault.id)}

      _ ->
        {:error, %{reason: "no vault of yours is called that"}}
    end
  end

  @impl true
  def handle_info({:vault_change, vault_id, cursor}, %{assigns: %{vault_id: vault_id}} = socket) do
    push(socket, "change", %{cursor: cursor})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
