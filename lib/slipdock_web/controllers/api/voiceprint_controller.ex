defmodule SlipdockWeb.API.VoiceprintController do
  @moduledoc """
  The caller's own voiceprint over the JSON API (see
  `Slipdock.Meetings.Voiceprints`). Behind the `:meetings` pipeline, and 404
  while voiceprints are off. Every route is about the token's owner: a
  request that names anybody (`user`, `user_id`, `email`) is refused rather
  than quietly answered about the caller.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Meetings.Voiceprints

  plug :require_enabled
  plug :refuse_other_people

  @doc "Their voiceprint, the consent wording, and the meetings they could enrol from."
  def show(conn, _params), do: json(conn, state(conn.assigns.current_user))

  @doc """
  Enrols them: multipart `audio` (a recording of their own voice) or
  `capture` (a meeting where their voice was confirmed), with `consent` set
  to the wording's version.
  """
  def create(conn, params) do
    user = conn.assigns.current_user

    source =
      case params do
        %{"audio" => %Plug.Upload{path: path, filename: name}} -> {:recording, path, name}
        %{"capture" => id} when id not in [nil, ""] -> {:capture, id}
        _ -> nil
      end

    case source && Voiceprints.enrol(user, source, consent: params["consent"]) do
      nil ->
        error(conn, 422, "send audio (a recording of your own voice) or capture (a meeting id)")

      {:ok, _} ->
        conn |> put_status(:created) |> json(state(user))

      {:error, :consent} ->
        conn
        |> put_status(422)
        |> json(%{
          error:
            "a voiceprint needs your consent: send consent=#{Voiceprints.wording_version()} " <>
              "to agree to the wording",
          code: "consent_required",
          consent: consent()
        })

      {:error, :off} ->
        off(conn)

      {:error, message} ->
        error(conn, 422, message)
    end
  end

  @doc "Deletes it, at once; later captures stop using it."
  def delete(conn, _params) do
    user = conn.assigns.current_user

    case Voiceprints.delete(user) do
      :ok -> json(conn, Map.put(state(user), :deleted, true))
      {:error, :none} -> error(conn, 404, "you have no voiceprint")
    end
  end

  defp state(user) do
    print = Voiceprints.get(user)

    %{
      voiceprint:
        print &&
          %{
            source: print.source,
            source_capture_id: print.source_capture_id,
            consented_at: print.consented_at,
            consent_version: print.consent_version,
            dimensions: length(print.embedding)
          },
      consent: consent(),
      offers:
        Enum.map(Voiceprints.offers(user), fn %{capture: c, voice: v} ->
          %{capture: c.id, title: c.title, board_id: c.board_id, voice: v.label}
        end)
    }
  end

  defp consent, do: %{version: Voiceprints.wording_version(), wording: Voiceprints.wording()}

  defp require_enabled(conn, _) do
    if Voiceprints.enabled?(), do: conn, else: conn |> off() |> halt()
  end

  defp refuse_other_people(conn, _) do
    if Enum.any?(~w(user user_id email), &Map.has_key?(conn.params, &1)),
      do: conn |> error(403, "a voiceprint can only be your own") |> halt(),
      else: conn
  end

  defp off(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "voiceprints are off on this server", code: "voiceprints_off"})
  end

  defp error(conn, status, message),
    do: conn |> put_status(status) |> json(%{error: message})
end
