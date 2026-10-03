defmodule SlipdockWeb.API.MeController do
  use SlipdockWeb, :controller

  alias Slipdock.AI

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{id: user.id, email: user.email, name: user.name},
      ai_key: ai_key(user),
      # Endpoint, model and embedding model, so an agent can see what it is
      # about to spend and on whose hardware.
      ai: ai_provider(user),
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
  Stores the caller's own API key, the one every AI feature spends on their
  behalf. `PUT /api/me/ai-key {"api_key": "sk-or-…"}`; a blank key removes
  it, as does `DELETE`. Leaves their endpoint and model alone — see
  `put_ai_provider/2` for those.
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

    case AI.Keys.put_settings(user, %{api_key: ""}) do
      :ok -> json(conn, %{ai_key: ai_key(user)})
      {:error, message} -> conn |> put_status(:internal_server_error) |> json(%{error: message})
    end
  end

  @doc """
  Points the caller at a model: any OpenAI-compatible endpoint, with a key if
  it wants one, and which model to ask.

      PUT /api/me/ai-provider {"base_url": "http://llm.local:1234/v1",
                               "model": "qwen/qwen3.5-9b"}

  Only the fields sent are changed; `""` clears one, so `{"base_url": ""}`
  goes back to the server's default endpoint. `api_key`, `model` and
  `embed_model` are the others.
  """
  def put_ai_provider(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ~w(base_url api_key model embed_model))

    if attrs == %{} do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        error: "Send at least one of base_url, api_key, model, embed_model (\"\" clears one)."
      })
    else
      case AI.Keys.put_settings(user, attrs) do
        :ok ->
          json(conn, %{ai: ai_provider(user), ai_key: ai_key(user)})

        {:error, message} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: message})
      end
    end
  end

  @doc """
  What the caller's endpoint can run: `GET /api/me/ai-models`. The endpoint's
  own `/models`, so OpenRouter answers with everything it proxies and a local
  server with what it has. `?base_url=` and `?api_key=` try an endpoint that
  is not stored yet.
  """
  def ai_models(conn, params) do
    opts =
      [user: conn.assigns.current_user]
      |> maybe_opt(:base_url, params["base_url"])
      |> maybe_opt(:api_key, params["api_key"])

    case AI.models(opts) do
      {:ok, models} -> json(conn, %{models: models})
      {:error, message} -> conn |> put_status(:bad_gateway) |> json(%{error: message})
    end
  end

  defp maybe_opt(opts, key, value) when is_binary(value) and value != "",
    do: Keyword.put(opts, key, value)

  defp maybe_opt(opts, _key, _value), do: opts

  # Where this person's AI requests go, and what they ask for. Never the key
  # itself (see `ai_key/1`).
  defp ai_provider(user) do
    settings = AI.Keys.settings(user)

    %{
      base_url: settings.base_url || AI.default_base_url(),
      own_endpoint: settings.base_url,
      model: settings.model || AI.model(),
      own_model: settings.model,
      embed_model: settings.embed_model
    }
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
