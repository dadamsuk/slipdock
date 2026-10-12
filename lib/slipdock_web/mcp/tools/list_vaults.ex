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
        "path to a board's wiki or a folder of it. Give vault and path to ask which mapping " <>
        "a path lands in (longest prefix wins) and what is left of it."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        vault: %{type: "string", description: "Vault id or name; leave out to list them all."},
        path: %{type: "string", description: "A vault path to locate, e.g. /Jobs/Acme.md."}
      },
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: true

  @impl true
  def call(args, %{user: user}) do
    with {:ok, ref} <- Args.optional(args, "vault"),
         {:ok, path} <- Args.optional(args, "path") do
      case {ref, path} do
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
