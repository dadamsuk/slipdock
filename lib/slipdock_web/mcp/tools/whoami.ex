defmodule SlipdockWeb.MCP.Tools.Whoami do
  @moduledoc "Who the connection is signed in as, and what its token may do."
  @behaviour SlipdockWeb.MCP.Tool

  @impl true
  def name, do: "whoami"

  @impl true
  def title, do: "Who am I"

  @impl true
  def description,
    do:
      "Who this connection is signed in as, its token's scope, the account's item " <>
        "limit used, waiting_on_you: how many things need this person, waiting_hidden: " <>
        "how many they dismissed or muted, and overseer: the overseer's alerts, first."

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, additionalProperties: false}

  @impl true
  def read_only?, do: true

  @impl true
  def call(_args, %{user: user, token: token, base_url: base_url}) do
    waiting = Slipdock.Work.waiting(user, roots: roots(token), paths: false)

    {:ok,
     %{
       user: %{id: user.id, email: user.email, name: user.name},
       token: %{label: token.label, scope: token.scope, boards: token.scope_boards || []},
       server: base_url,
       limits: Slipdock.Quota.report(user),
       waiting_on_you: length(waiting.items),
       waiting_hidden: %{
         dismissed: length(waiting.dismissed),
         muted: waiting.muted,
         muted_boards: waiting.muted_boards
       },
       overseer:
         waiting.items
         |> Slipdock.Work.overseer_first()
         |> Enum.map(&SlipdockWeb.API.OverseerJSON.condition/1)
     }}
  end

  defp roots(%{scope_boards: [_ | _] = ids}), do: ids
  defp roots(_), do: nil
end
