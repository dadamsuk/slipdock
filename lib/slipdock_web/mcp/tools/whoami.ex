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
      "Who this connection is signed in as, the token's scope (read or write), " <>
        "how much of the account's item limit is used, and waiting_on_you: how many " <>
        "things need this person (the plan-my-day prompt lists them)."

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, additionalProperties: false}

  @impl true
  def read_only?, do: true

  @impl true
  def call(_args, %{user: user, token: token, base_url: base_url}) do
    {:ok,
     %{
       user: %{id: user.id, email: user.email, name: user.name},
       token: %{label: token.label, scope: token.scope, boards: token.scope_boards || []},
       server: base_url,
       limits: Slipdock.Quota.report(user),
       waiting_on_you: Slipdock.Work.waiting_count(user, roots: roots(token))
     }}
  end

  defp roots(%{scope_boards: [_ | _] = ids}), do: ids
  defp roots(_), do: nil
end
