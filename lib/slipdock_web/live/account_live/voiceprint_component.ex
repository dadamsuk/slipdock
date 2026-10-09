defmodule SlipdockWeb.AccountLive.VoiceprintComponent do
  @moduledoc """
  The voiceprint tab, there only while an admin has voiceprints on (see
  `Slipdock.Meetings.Voiceprints`): the person's own voiceprint, the consent
  wording they agree to, enrolling from a recording of their own or from a
  meeting where their voice was confirmed, and deleting it. Everything here
  is about the signed-in person; nothing names anybody else.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Meetings.Voiceprints

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if Map.has_key?(socket.assigns, :voiceprint),
      do: {:ok, socket},
      else:
        {:ok,
         socket
         |> assign(error: nil)
         |> load()
         |> allow_upload(:recording,
           accept: Slipdock.Meetings.Limits.audio_extensions(),
           max_entries: 1,
           max_file_size: 25_000_000
         )}
  end

  defp load(socket) do
    user = socket.assigns.current_user

    assign(socket,
      voiceprint: Voiceprints.get(user),
      offers: Voiceprints.offers(user),
      consents: Voiceprints.consents(user)
    )
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("enrol-recording", params, socket) do
    user = socket.assigns.current_user
    consent = consent(params)

    result =
      consume_uploaded_entries(socket, :recording, fn %{path: path}, entry ->
        # Read from the upload and left there: the recording is never kept.
        {:ok, Voiceprints.enrol(user, {:recording, path, entry.client_name}, consent: consent)}
      end)

    case result do
      [] -> {:noreply, assign(socket, error: "Choose a recording of your voice first.")}
      [r] -> done(socket, r)
    end
  end

  def handle_event("enrol-capture", %{"capture" => id} = params, socket) do
    r = Voiceprints.enrol(socket.assigns.current_user, {:capture, id}, consent: consent(params))
    done(socket, r)
  end

  def handle_event("delete", _params, socket) do
    case Voiceprints.delete(socket.assigns.current_user) do
      :ok -> send(self(), {:flash, :info, "Your voiceprint is deleted."})
      {:error, :none} -> :ok
    end

    {:noreply, socket |> assign(error: nil) |> load()}
  end

  # The box is the consent: ticked, it sends the version of the wording shown.
  defp consent(%{"consent" => "true"}), do: Voiceprints.wording_version()
  defp consent(_), do: nil

  defp done(socket, {:ok, _}) do
    send(self(), {:flash, :info, "Your voiceprint is saved."})
    {:noreply, socket |> assign(error: nil) |> load()}
  end

  defp done(socket, {:error, :consent}),
    do: {:noreply, assign(socket, error: "Tick the box to agree first: nothing was saved.")}

  defp done(socket, {:error, :off}),
    do: {:noreply, assign(socket, error: "Voiceprints are off on this server.")}

  defp done(socket, {:error, message}) when is_binary(message),
    do: {:noreply, assign(socket, error: String.capitalize(message) <> ".")}

  attr :id, :string, required: true

  defp consent_box(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-start gap-3 text-sm">
      <input type="checkbox" id={@id} name="consent" value="true" class="checkbox checkbox-sm mt-0.5" />
      <span>{Voiceprints.wording()}</span>
    </label>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section
        id="voiceprint"
        class="space-y-4 rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <div>
          <h2 class="text-lg font-semibold">Voiceprint</h2>
          <p class="text-sm text-base-content/60">
            Optional, and only yours to decide. A voiceprint helps meeting capture suggest when it was
            you speaking; the suggestion is shown as evidence and can be corrected. Only numbers made
            from your voice are kept, never the recording.
          </p>
        </div>

        <p :if={@error} id="voiceprint-error" class="text-sm text-error">{@error}</p>

        <div :if={@voiceprint} id="voiceprint-saved" class="space-y-3 text-sm">
          <p>
            You have a voiceprint, made from {if @voiceprint.source == "meeting",
              do: "a meeting where your voice was confirmed",
              else: "a recording of your own"} with your consent on {Calendar.strftime(
              @voiceprint.consented_at,
              "%-d %B %Y"
            )}.
          </p>
          <button
            id="voiceprint-delete"
            type="button"
            class="btn btn-error btn-outline btn-sm"
            phx-click="delete"
            phx-target={@myself}
            data-confirm="Delete your voiceprint? Meetings stop using it straight away."
          >
            Delete my voiceprint
          </button>
        </div>

        <div :if={!@voiceprint} class="space-y-6">
          <form
            id="voiceprint-recording"
            phx-change="validate"
            phx-submit="enrol-recording"
            phx-target={@myself}
            class="space-y-3"
          >
            <h3 class="text-sm font-medium">From a recording of your own voice</h3>
            <p class="text-xs text-base-content/60">
              Half a minute of you talking is plenty.
            </p>
            <.live_file_input
              upload={@uploads.recording}
              class="file-input file-input-sm w-full max-w-sm"
            />
            <.consent_box id="voiceprint-consent-recording" />
            <button type="submit" class="btn btn-primary btn-sm">Save my voiceprint</button>
          </form>

          <div :if={@offers != []} id="voiceprint-offers" class="space-y-3">
            <h3 class="text-sm font-medium">Or from a meeting where your voice was confirmed</h3>
            <form
              :for={%{capture: c, voice: v} <- @offers}
              id={"voiceprint-offer-#{c.id}"}
              phx-submit="enrol-capture"
              phx-target={@myself}
              class="space-y-2 rounded-xl bg-base-200/50 p-3"
            >
              <input type="hidden" name="capture" value={c.id} />
              <p class="text-sm">
                “{c.title}” — {v.label} was confirmed as you. Only if those lines really are you.
              </p>
              <.consent_box id={"voiceprint-consent-#{c.id}"} />
              <button type="submit" class="btn btn-sm">Use my voice from this meeting</button>
            </form>
          </div>
        </div>

        <details :if={@consents != []} id="voiceprint-consents" class="text-xs text-base-content/60">
          <summary class="cursor-pointer">Your consent record</summary>
          <ul class="mt-2 space-y-1">
            <li :for={c <- @consents}>
              {Calendar.strftime(c.inserted_at, "%-d %b %Y %H:%M")} — {c.event} (wording {c.wording_version})
            </li>
          </ul>
        </details>
      </section>
    </div>
    """
  end
end
