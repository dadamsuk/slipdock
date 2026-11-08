defmodule SlipdockWeb.API.SkillRegistryController do
  @moduledoc """
  The skills registry over REST (#2072, spec W-2513): what the Skills page
  (`/skills`) does, with the page's permissions.

  - Sources (`/skill-sources`) are the caller's own and the seeds. Adding
    one fetches it (with `seed: true`, an admin adds a seed); its owner (an
    admin, for a seed) refreshes or removes it. A fetch's refusal is its sentence, as a 422.
  - An entry (`/skill-entries/:id`) is the whole file, its hash, where it
    is enabled and which Playbook stages name it.
  - A board's skills (`/boards/:board/skills`): a writer enables an entry
    pinned to the `hash` they read, re-pins one by name after reading its
    diff, or disables it. The pinned text is what the board's agents get.
  - `/skill-stages`: every Playbook stage the caller can read that names a
    skill, with what it gets, flagged when nothing provides it.
  """
  use SlipdockWeb, :controller

  alias Slipdock.SkillRegistry
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.SkillRegistryJSON, as: JSON

  action_fallback SlipdockWeb.API.FallbackController

  @doc "The caller's sources and the seeds, each with its entries' metadata."
  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{sources: Enum.map(SkillRegistry.list_sources(user), &JSON.source(&1, user))})
  end

  @doc "One source the caller sees."
  def show(conn, %{"id" => id}) do
    with {:ok, source} <- source(conn, id),
         do: json(conn, %{source: JSON.source(source, conn.assigns.current_user)})
  end

  @doc """
  Adds the source at `url`: fetches it and keeps its entries. `seed: true`
  adds it for everyone instead, which only an admin may.
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    seed = Enum.member?([true, "true"], params["seed"])

    with {:ok, source} <-
           user |> SkillRegistry.add_source(params["url"], seed: seed) |> refused() do
      conn |> put_status(:created) |> json(%{source: JSON.source(source, user)})
    end
  end

  @doc "Fetches a source again, saying which entries were added, changed and removed."
  def refresh(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, source} <- source(conn, id),
         {:ok, source, changes} <- user |> SkillRegistry.refresh_source(source) |> refused() do
      json(conn, %{source: JSON.source(source, user), changes: changes})
    end
  end

  @doc "Removes a source and its entries."
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, source} <- source(conn, id),
         {:ok, removed} <- user |> SkillRegistry.remove_source(source) |> refused() do
      json(conn, %{deleted: %{id: removed.id, name: removed.name, url: removed.url}})
    end
  end

  @doc "One entry in full: its text, where it is enabled, and which stages name it."
  def entry(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case id |> integer() |> then(&(&1 && SkillRegistry.get_entry(user, &1))) do
      nil -> {:error, :not_found, "skill"}
      entry -> json(conn, %{entry: JSON.entry(entry, user)})
    end
  end

  @doc "The Playbook stages naming a skill on every board the caller reads."
  def stages(conn, _params),
    do: json(conn, %{boards: JSON.stages(SkillRegistry.naming(conn.assigns.current_user))})

  @doc "Enables `entry` (an id) on the board, pinned to `hash`, the text the caller read."
  def enable(conn, %{"board" => ref} = params) do
    user = conn.assigns.current_user

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, entry_id} <- required_id(params["entry"]),
         {:ok, hash} <- required(params, "hash"),
         {:ok, e} <- user |> SkillRegistry.enable(board, entry_id, hash) |> refused() do
      conn |> put_status(:created) |> json(%{skill: JSON.enablement(e, text: true)})
    end
  end

  @doc "Re-pins a skill enabled on the board, by name, to `hash`: the entry's text now."
  def repin(conn, %{"board" => ref, "name" => name} = params) do
    user = conn.assigns.current_user

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, e} <- enabled(board, name),
         {:ok, hash} <- required(params, "hash"),
         {:ok, e} <- user |> SkillRegistry.repin(e, hash) |> refused() do
      json(conn, %{skill: JSON.enablement(e, text: true)})
    end
  end

  @doc "Disables a skill on the board, by name."
  def disable(conn, %{"board" => ref, "name" => name}) do
    user = conn.assigns.current_user

    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write),
         {:ok, e} <- enabled(board, name),
         {:ok, _} <- user |> SkillRegistry.disable(e) |> refused() do
      json(conn, %{disabled: %{name: e.name, board: board.code || board.id}})
    end
  end

  ## Helpers

  defp source(conn, id) do
    case id
         |> integer()
         |> then(&(&1 && SkillRegistry.get_source(conn.assigns.current_user, &1))) do
      nil -> {:error, :not_found, "skill source"}
      source -> {:ok, source}
    end
  end

  defp enabled(board, name) do
    case SkillRegistry.get_enabled(board, name) do
      nil -> {:error, :not_found, "skill enabled on that board"}
      e -> {:ok, e}
    end
  end

  defp required(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :bad_request, "#{key} is required"}
    end
  end

  defp required_id(value) do
    case integer(value) do
      nil -> {:error, :bad_request, "entry is required: the id of a skill you can see"}
      id -> {:ok, id}
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp refused({:error, "That skill isn't one you can see."}), do: {:error, :not_found, "skill"}
  defp refused({:error, "Only " <> _ = message}), do: {:error, :forbidden, message}

  defp refused({:error, message}) when is_binary(message),
    do: {:error, :unprocessable_entity, message}

  defp refused(ok), do: ok
end
