defmodule SlipdockWeb.MCP.Tools.ListVaults do
  @moduledoc """
  The caller's vaults and their mappings (see `Slipdock.Vaults`), or with a
  `path`, where in one vault that path lands.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Vaults
  alias SlipdockWeb.API.JSON, as: V
  alias SlipdockWeb.MCP.Args

  @impl true
  def name, do: "list_vaults"

  @impl true
  def title, do: "List vaults"

  @impl true
  def description,
    do:
      "Your vaults: board wikis laid out as one Obsidian-style vault, each mapping a vault " <>
        "path to a board's wiki or a folder of it, with how many pages each holds and the " <>
        "folders the vault is synced to (each sync token, last sync). Give vault and path to ask which mapping " <>
        "a path lands in (longest prefix wins) and what is left of it; vault and link, which " <>
        "page a [[link]] finds in it; vault and changes_since, what changed after a cursor."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        vault: %{type: "string", description: "Vault id or name; leave out to list them all."},
        path: %{type: "string", description: "A vault path to locate, e.g. /Jobs/Acme.md."},
        link: %{
          type: "string",
          description: "A link's words to resolve, e.g. Note or Folder/Note."
        },
        changes_since: %{
          type: "integer",
          description: "With vault: what changed after this cursor (0 for everything kept)."
        }
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user} = context) do
    case args do
      %{"changes_since" => since} -> changes(args, since, user, context)
      _ -> lookup(args, user)
    end
  end

  defp changes(args, since, user, context) do
    with {:ok, ref} <- Args.required(args, "vault"),
         :ok <- cursor(since),
         {:ok, vault} <- Args.refusal(Vaults.get_vault(user, ref)) do
      {:ok, Slipdock.Wiki.Changes.since(vault, since, user, limit: 200, token: context[:token])}
    end
  end

  defp cursor(since) when is_integer(since) and since >= 0, do: :ok
  defp cursor(_), do: {:error, "changes_since is a cursor: a whole number, 0 or more"}

  defp lookup(args, user) do
    with {:ok, ref} <- Args.optional(args, "vault"),
         {:ok, path} <- Args.optional(args, "path"),
         {:ok, link} <- Args.optional(args, "link") do
      case {ref, path || (link && {:link, link})} do
        {nil, {:link, _}} ->
          {:error, "say which vault the link is in"}

        {ref, {:link, link}} ->
          with {:ok, vault} <- Args.refusal(Vaults.get_vault(user, ref)),
               {:ok, page, path} <- Args.refusal(Vaults.resolve_link(vault, link, user)),
               do:
                 {:ok,
                  %{
                    page: Map.take(V.page_summary(page), [:id, :code, :title, :board_id, :url]),
                    path: "/" <> path
                  }}

        {nil, nil} ->
          {:ok, %{vaults: user |> Vaults.list_vaults() |> Enum.map(&V.vault/1)}}

        {nil, _path} ->
          {:error, "say which vault the path is in"}

        {ref, nil} ->
          with {:ok, vault} <- Args.refusal(Vaults.get_vault(user, ref)),
               do: {:ok, %{vault: V.vault(vault)}}

        {ref, path} ->
          with {:ok, vault} <- Args.refusal(Vaults.get_vault(user, ref)),
               {:ok, mapping, rest} <- Args.refusal(Vaults.locate(vault, path)),
               do: {:ok, %{mapping: V.vault_mapping(mapping), rest: rest}}
      end
    end
  end
end
