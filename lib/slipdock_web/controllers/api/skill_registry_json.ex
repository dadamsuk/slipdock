defmodule SlipdockWeb.API.SkillRegistryJSON do
  @moduledoc """
  The skills registry as the API and the MCP tool give it (#2072): sources,
  their entries, an entry in full with where it is enabled, the skills
  enabled on a board, and the Playbook stages that name one. One place, so
  `/api/skill-*` and the `skill_registry` tool answer alike.
  """

  alias Slipdock.SkillRegistry

  @doc "A source, with its entries' metadata (not their text)."
  def source(source, user) do
    %{
      id: source.id,
      url: source.url,
      kind: source.kind,
      name: source.name,
      licence: source.licence,
      version: source.version,
      fetched_at: source.fetched_at,
      report: source.report,
      seed: is_nil(source.owner_id),
      can_manage: SkillRegistry.can_manage?(user, source),
      entries: Enum.map(source.entries, &entry_summary/1)
    }
  end

  @doc "An entry's metadata, with the hash a pin is made against."
  def entry_summary(entry) do
    %{
      id: entry.id,
      name: entry.name,
      description: entry.description,
      path: entry.path,
      version: entry.version,
      licence: entry.licence,
      content_hash: entry.content_hash,
      fetched_at: entry.fetched_at
    }
  end

  @doc """
  An entry in full: its text, its source, the boards `user` reads it is
  enabled on (each with its pin's status, and the diff when it changed
  upstream), and the Playbook stages naming it.
  """
  def entry(entry, user) do
    entry
    |> entry_summary()
    |> Map.merge(%{
      body: entry.body,
      source: %{id: entry.source.id, name: entry.source.name, url: entry.source.url},
      enabled_on:
        Enum.map(SkillRegistry.enabled_where(user, entry), fn %{enablement: e, writer: writer} ->
          e |> enablement(diff: true) |> Map.merge(%{board: board(e.board), can_change: writer})
        end),
      stages:
        for(
          %{board: b, stages: stages} <- SkillRegistry.naming(user, entry.name),
          stage <- stages,
          do: %{board: board(b), stage: stage.stage, enabled: stage.enabled != nil}
        )
    })
  end

  @doc """
  A skill enabled on a board: what is pinned (the name, source, licence,
  version, hash and when), its status (`current`, `changed`, `removed`)
  and the entry it came from. `text: true` adds the pinned text; `diff:
  true` adds the lines that differ when it changed upstream.
  """
  def enablement(e, opts \\ []) do
    status = SkillRegistry.status(e)

    %{
      name: e.name,
      description: e.description,
      source_name: e.source_name,
      source_url: e.source_url,
      licence: e.licence,
      version: e.version,
      pinned_hash: e.pinned_hash,
      pinned_at: e.pinned_at,
      status: Atom.to_string(status),
      entry_id: e.entry_id,
      upstream_hash: e.entry && e.entry.content_hash
    }
    |> put_if(opts[:text], :text, e.pinned_body)
    |> put_if(opts[:diff] && status == :changed, :diff, diff(e))
  end

  @doc "The Playbook stages naming a skill, per board, as `SkillRegistry.naming/1` gives them."
  def stages(naming) do
    Enum.map(naming, fn %{board: b, stages: stages} ->
      %{
        board: board(b),
        stages:
          Enum.map(stages, fn s ->
            %{
              stage: s.stage,
              skill: s.skill,
              enabled: s.enabled && enablement(s.enabled),
              shipped: s.shipped,
              flagged: s.flagged
            }
          end)
      }
    end)
  end

  defp diff(e) do
    for {op, lines} <- SkillRegistry.diff(e), do: %{op: Atom.to_string(op), lines: lines}
  end

  defp board(b), do: %{id: b.id, code: b.code, name: b.name}

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _, _key, _value), do: map
end
