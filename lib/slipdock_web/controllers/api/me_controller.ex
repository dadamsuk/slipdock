defmodule SlipdockWeb.API.MeController do
  use SlipdockWeb, :controller

  alias Slipdock.AI

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{id: user.id, email: user.email, name: user.name},
      ai_key: ai_key(user),
      # Where they stand on cards, so an agent can stop before the wall rather
      # than discovering it with a 402 halfway through a batch. `cards` is the
      # item count — cards, wiki pages and uploaded files together — and keeps
      # its name because callers match on it; `limits` has every dimension,
      # with the item count broken down.
      cards: Slipdock.Quota.status(user),
      limits: Slipdock.Quota.report(user)
    })
  end

  @doc """
  Stores the caller's own OpenRouter key, the one every AI feature spends on
  their behalf. `PUT /api/me/ai-key {"api_key": "sk-or-…"}`; a blank key
  removes it, as does `DELETE`.
  """
  def put_ai_key(conn, params) do
    user = conn.assigns.current_user

    case params["api_key"] || params["key"] do
      key when is_binary(key) ->
        case AI.Keys.put(user, key) do
          :ok ->
            json(conn, %{ai_key: ai_key(user)})

          {:error, message} ->
            conn |> put_status(:internal_server_error) |> json(%{error: message})
        end

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "api_key is required (send an empty string to remove the key)."})
    end
  end

  def delete_ai_key(conn, _params) do
    user = conn.assigns.current_user

    case AI.Keys.delete(user) do
      :ok -> json(conn, %{ai_key: ai_key(user)})
      {:error, message} -> conn |> put_status(:internal_server_error) |> json(%{error: message})
    end
  end

  # Never the key itself — only its shape, when it was set, and whether AI
  # features will run for this person at all.
  defp ai_key(user) do
    %{
      configured: AI.Keys.configured?(user),
      masked: AI.Keys.masked(AI.Keys.get(user)),
      set_at: AI.Keys.updated_at(user),
      ai_available: AI.configured?(user)
    }
  end
end
