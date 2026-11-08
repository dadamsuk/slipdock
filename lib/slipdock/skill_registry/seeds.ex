defmodule Slipdock.SkillRegistry.Seeds do
  @moduledoc """
  The sources a new server starts with (#2075, spec W-2513 §Seeds): owned by
  no one, seen by everyone, enabled nowhere.

  `run/0` is called once at boot, off the boot path
  (`Slipdock.Application`). It adds each URL in `seeds/0` that this server
  has never seeded, and records it in `skill_seeds` once it is there. So a
  seed an admin removes stays removed, and one whose fetch failed (GitHub
  down, the server offline) is tried again at the next boot.

  The list is `config :slipdock, :skill_registry, seeds: [...]`, by default
  `mattpocock/skills` (MIT). An empty list seeds nothing.
  """

  import Ecto.Query

  require Logger

  alias Slipdock.Repo
  alias Slipdock.SkillRegistry

  @default ["https://github.com/mattpocock/skills"]

  @doc "The URLs a server seeds."
  @spec seeds() :: [String.t()]
  def seeds, do: Slipdock.Config.get(:skill_registry, [])[:seeds] || @default

  @doc """
  Seeds each URL not seeded before. Returns what happened to each:
  `{url, :added | :already | :seeded_before | {:error, sentence}}`.
  """
  @spec run() :: [{String.t(), atom() | {:error, String.t()}}]
  def run do
    seeded = seeded()

    for url <- seeds() do
      outcome = if MapSet.member?(seeded, url), do: :seeded_before, else: seed(url)
      log(url, outcome)
      {url, outcome}
    end
  end

  @doc "The URLs this server has seeded, whether or not they are still there."
  @spec seeded() :: MapSet.t(String.t())
  def seeded, do: from(s in "skill_seeds", select: s.url) |> Repo.all() |> MapSet.new()

  defp seed(url) do
    outcome =
      case SkillRegistry.add_source(nil, url) do
        {:ok, _source} -> :added
        {:error, reason} -> if seed_exists?(url), do: :already, else: {:error, reason}
      end

    if Enum.member?([:added, :already], outcome), do: record(url)
    outcome
  end

  defp seed_exists?(url),
    do: Repo.exists?(from s in SkillRegistry.Source, where: is_nil(s.owner_id) and s.url == ^url)

  defp record(url) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.insert_all("skill_seeds", [%{url: url, inserted_at: now}], on_conflict: :nothing)
  end

  defp log(url, :added), do: Logger.info("Seeded the skill source #{url}.")

  defp log(url, {:error, reason}),
    do: Logger.warning("Could not seed the skill source #{url}; next boot tries again: #{reason}")

  defp log(_url, _outcome), do: :ok
end
