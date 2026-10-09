defmodule SlipdockWeb.ConfigLive.Index do
  @moduledoc """
  Everything the setup wizard asked, editable afterwards. The people who use
  this server live on their own page, at `/users`.

  Deliberately small. Nobody with 250 users is going to run this, so there is
  no org chart and no permission matrix — one page of settings for the server
  and one for its mail.

  The part that matters is what it **refuses**. An admin area that lets you
  brick your own instance is worse than no admin area, so mail settings will
  not save without a test message that arrived, and changing the admin address
  needs the new one to confirm before it takes effect.

  At the top: which build is actually running. The first question worth asking
  about a server behaving unexpectedly is whether it is the server you think.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.{Accounts, Build, Mailer, Settings}
  alias Slipdock.AI.Keys
  alias Slipdock.Settings.Instance

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Configuration",
       mail_error: nil,
       mail_tested?: false,
       tested_mail: nil,
       typed_password: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, tab: tab(socket))}

  defp tab(%{assigns: %{live_action: action}}), do: action

  defp load(socket) do
    settings = Settings.get()

    assign(socket,
      settings: settings,
      form: to_form(Settings.change(), as: :settings),
      mail_form: mail_form(settings, socket),
      allowlist: Settings.list_allowlist(),
      allow_form: to_form(%{"entry" => ""}, as: :allow),
      requests: Accounts.list_signup_requests(),
      admin_email_pending: settings.admin_email,
      ai_source: Keys.system_source(),
      meetings_usage: Slipdock.Meetings.Usage.server_month(),
      ai_candidates: ai_candidates()
    )
  end

  # What each form may change. Anything else in its params is dropped rather
  # than saved, whatever the browser sends.
  @settings_fields ~w(signup_mode free_card_limit user_directory invites_create_accounts
                      board_limit board_limit_enabled item_limit item_limit_enabled
                      storage_limit_mb storage_limit_enabled trial_days trial_enabled
                      terms_url privacy_url terms_version posthog_key posthog_host
                      posthog_respect_dnt ai_system_user_id meetings_enabled
                      meetings_visibility meetings_hideable meetings_accept_transcripts
                      meetings_accept_audio meetings_accept_findings meetings_reading_model
                      meetings_second_reading meetings_second_model
                      meetings_transcription_minutes meetings_transcription_minutes_enabled
                      meetings_audio_storage_mb meetings_audio_storage_mb_enabled
                      meetings_transcript_captures meetings_transcript_captures_enabled
                      meetings_longest_minutes meetings_max_file_mb meetings_audio_retention)

  @mail_fields ~w(smtp_host smtp_port smtp_username smtp_password smtp_tls smtp_from_email
                  smtp_from_name)

  ## Settings

  @impl true
  def handle_event("save-settings", %{"settings" => attrs}, socket) do
    # Only what these forms show. The admin's own address is changed through
    # its own flow, which verifies the new one first — otherwise a typo sends
    # every approval notice and lock-out warning into the void — and the mail
    # settings through theirs, which wants a test message that arrived.
    attrs = Map.take(attrs, @settings_fields)

    case Settings.update(attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Saved.") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("add-allow", %{"allow" => %{"entry" => entry}}, socket) do
    case Settings.add_allowlist_entry(entry, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Added #{entry}.") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, allow_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("remove-allow", %{"id" => id}, socket) do
    if id = SlipdockWeb.Params.id(id), do: Settings.remove_allowlist_entry(id)
    {:noreply, load(socket)}
  end

  ## Mail

  def handle_event("mail", %{"step_action" => "test", "settings" => attrs}, socket) do
    attrs = with_typed_password(attrs, socket)
    recipient = String.trim(attrs["test_to"] || socket.assigns.current_user.email)

    # Whatever was typed has to survive this re-render, or the form would snap
    # back to the stored settings and the save that follows would store those
    # instead — which is the whole of what the admin was trying to change.
    socket = socket |> remember_typed(attrs) |> assign(mail_form: typed_form(attrs))

    case Mailer.test_delivery(attrs, recipient) do
      :ok ->
        {:noreply,
         socket
         |> assign(mail_tested?: true, mail_error: nil, tested_mail: Map.drop(attrs, ["test_to"]))
         |> put_flash(:info, "Test message sent to #{recipient}. Check that it arrived.")}

      {:error, message} ->
        {:noreply, assign(socket, mail_tested?: false, tested_mail: nil, mail_error: message)}
    end
  end

  def handle_event("mail", %{"settings" => attrs}, socket) do
    # Only the mail fields: anything else riding along would be saved on the
    # strength of a test message that says nothing about it.
    attrs = attrs |> with_typed_password(socket) |> Map.take(@mail_fields)
    changing? = changing_mail?(socket.assigns.settings, attrs)

    cond do
      # A test that went out for *other* values proves nothing about these
      # ones, so editing a field after testing asks for another test.
      changing? and not tested?(socket, attrs) ->
        {:noreply,
         socket
         |> assign(mail_form: typed_form(attrs))
         |> assign(
           mail_error:
             "Send a test message that arrives before saving. A mail server that does " <>
               "not work is how everybody gets locked out for good."
         )}

      true ->
        case Settings.update(attrs) do
          {:ok, _} ->
            # The values just saved are the ones a test message travelled
            # through, which is what "last confirmed working" means.
            if changing?, do: Settings.mark_smtp_verified()

            {:noreply,
             socket
             |> assign(
               mail_tested?: false,
               mail_error: nil,
               tested_mail: nil,
               typed_password: nil
             )
             |> put_flash(:info, "Mail settings saved.")
             |> load()}

          {:error, changeset} ->
            {:noreply, assign(socket, mail_form: to_form(Map.put(changeset, :action, :validate)))}
        end
    end
  end

  ## The admin address

  def handle_event("change-admin-email", %{"settings" => %{"admin_email" => email}}, socket) do
    case Accounts.request_admin_email_change(email, socket.assigns.current_user) do
      {:ok, :sent} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "A code is on its way to #{email}. The address changes when it is confirmed; " <>
             "until then everything still goes to the old one."
         )}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("confirm-admin-email", %{"confirm" => %{"code" => code}}, socket) do
    case Accounts.confirm_admin_email_change(code, socket.assigns.current_user) do
      {:ok, email} ->
        {:noreply, socket |> put_flash(:info, "The admin address is now #{email}.") |> load()}

      {:error, :too_many_attempts} ->
        {:noreply,
         put_flash(socket, :error, "Too many wrong codes. Wait an hour, then try again.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That code is wrong, or it has expired.")}
    end
  end

  ## Internals

  # The mail form's values come from these params rather than from per-input
  # `value=` attributes: an attribute wins over whatever the person typed, so
  # every re-render of the page (a test send, a validation error) would put the
  # stored settings back into the fields and the next save would store those.
  defp mail_form(settings, socket) do
    settings
    |> Settings.to_form_params()
    |> Map.put("test_to", socket.assigns[:current_user] && socket.assigns.current_user.email)
    |> to_form(as: :settings)
  end

  # The same, for values that have been submitted but not saved. The password
  # is left out on purpose — it is never sent to a browser — and
  # `with_typed_password/2` puts it back on the way in.
  defp typed_form(attrs), do: attrs |> Map.drop(["smtp_password"]) |> to_form(as: :settings)

  defp with_typed_password(attrs, socket) do
    case {to_string(attrs["smtp_password"]), socket.assigns.typed_password} do
      {"", remembered} when is_binary(remembered) -> Map.put(attrs, "smtp_password", remembered)
      _ -> attrs
    end
  end

  defp remember_typed(socket, attrs) do
    case to_string(attrs["smtp_password"]) do
      "" -> socket
      password -> assign(socket, typed_password: password)
    end
  end

  defp tested?(%{assigns: %{mail_tested?: false}}, _attrs), do: false

  defp tested?(%{assigns: %{tested_mail: tested}}, attrs) when is_map(tested) do
    Enum.all?(@mail_fields, &(to_string(attrs[&1]) == to_string(tested[&1])))
  end

  defp tested?(_socket, _attrs), do: false

  defp changing_mail?(settings, attrs) do
    Enum.any?(@mail_fields, fn field ->
      submitted = attrs[field]
      current = Map.get(settings, String.to_existing_atom(field))

      # A blank password means "keep the stored one", so it is never a change.
      cond do
        field == "smtp_password" and to_string(submitted) == "" -> false
        is_nil(submitted) -> false
        true -> to_string(submitted) != to_string(current)
      end
    end)
  end

  # A limit is a number and a switch: switching one off leaves the number
  # where it was, so switching it back on does not mean typing it again.
  attr :form, :any, required: true
  attr :settings, :any, required: true
  attr :switch, :atom, required: true
  attr :number, :atom, required: true
  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :hint, :string, default: nil

  defp limit_control(assigns) do
    ~H"""
    <div>
      <label class="flex cursor-pointer items-center gap-3 text-sm">
        <input type="hidden" name={"settings[#{@switch}]"} value="false" />
        <input
          type="checkbox"
          name={"settings[#{@switch}]"}
          value="true"
          checked={Map.get(@settings, @switch)}
          class="checkbox checkbox-sm"
        />
        <span class="font-medium">{@label}</span>
        <input
          type="number"
          min="1"
          name={"settings[#{@number}]"}
          value={Map.get(@settings, @number)}
          class="input input-sm input-bordered w-28"
        />
        <span class="text-xs text-base-content/60">{@unit}</span>
      </label>
      <p :if={@hint} class="mt-1 ml-8 text-xs text-base-content/60">{@hint}</p>
      <p
        :for={message <- Keyword.get_values(@form.errors, @number)}
        class="mt-1 ml-8 text-xs text-error"
      >
        {translate_error(message)}
      </p>
    </div>
    """
  end

  # Who may be the server's AI: admins who are not disabled, each marked with
  # whether they have a key or an endpoint saved, since choosing someone with
  # neither changes nothing.
  defp ai_candidates do
    for user <- Accounts.list_admins(), is_nil(user.disabled_at) do
      label = if Keys.own?(user), do: user.email, else: "#{user.email} (no AI key saved)"
      {label, user.id}
    end
  end

  defp ai_source_text(%{source: :server_key}),
    do: "the shared OPENROUTER_API_KEY set on the server, which wins over the choice below"

  defp ai_source_text(%{source: :chosen, user: user}), do: "#{user.email}'s AI settings"

  defp ai_source_text(%{source: :environment, user: user}),
    do: "#{(user && user.email) || "someone"}'s AI settings, named by SLIPDOCK_AI_SYSTEM_USER"

  defp ai_source_text(%{source: :sole_admin, user: user}),
    do:
      "#{user.email}'s AI settings, because registration is closed and they are the only " <>
        "admin with a key"

  defp ai_source_text(_), do: nil

  defp mode_label(mode), do: elem(Instance.describe(mode), 0)
  defp mode_detail(mode), do: elem(Instance.describe(mode), 1)

  defp humanise_tls(:always), do: "Always"
  defp humanise_tls(:never), do: "Never"
  defp humanise_tls(:if_available), do: "If available"

  defp forced_fallback_off?, do: Slipdock.Config.get(:login_fallback) == false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={:config}
    >
      <:nav><span class="font-semibold">Configuration</span></:nav>

      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl space-y-6 p-6">
          <.build_banner />

          <div role="tablist" class="tabs tabs-box">
            <.link patch={~p"/config"} role="tab" class={["tab", @tab == :index && "tab-active"]}>
              Server
            </.link>
            <.link patch={~p"/config/mail"} role="tab" class={["tab", @tab == :mail && "tab-active"]}>
              Email
            </.link>
            <.link
              patch={~p"/config/meetings"}
              role="tab"
              class={["tab", @tab == :meetings && "tab-active"]}
            >
              Meetings
            </.link>
          </div>

          <.server_tab :if={@tab == :index} {assigns} />
          <.mail_tab :if={@tab == :mail} {assigns} />
          <.meetings_tab :if={@tab == :meetings} {assigns} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Which build is running. Frozen at compile time on purpose — see
  # `Slipdock.Build`.
  defp build_banner(assigns) do
    assigns = assign(assigns, build: Build.info())

    ~H"""
    <div
      id="build-info"
      class="flex flex-wrap items-center gap-x-6 gap-y-1 rounded-2xl bg-base-200 px-4 py-3 text-xs"
    >
      <span class="flex items-center gap-2">
        <.icon name="hero-cube" class="size-4 text-base-content/50" />
        <span class="text-base-content/60">Running build</span>
      </span>
      <span>
        <span class="text-base-content/60">Built</span>
        <span class="font-mono font-medium">{Build.built_at_string()} UTC</span>
      </span>
      <span>
        <span class="text-base-content/60">Commit</span>
        <span class="font-mono font-medium" title={@build.git_sha}>{@build.git_short_sha}</span>
        <span
          :if={@build.git_dirty}
          class="badge badge-xs badge-warning ml-1"
          title="There were uncommitted changes when this was compiled."
        >
          modified
        </span>
      </span>
      <span>
        <span class="text-base-content/60">Version</span>
        <span class="font-mono font-medium">{@build.version}</span>
      </span>
    </div>
    """
  end

  # Meeting capture (see `Slipdock.Meetings`): whether it exists here at all,
  # and where it shows. Screen 1 of the mockups.
  defp meetings_tab(assigns) do
    ~H"""
    <section
      id="meetings-settings"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">Meeting mode</h2>
      <p class="mt-1 text-sm text-base-content/60">
        People send a meeting's recording or transcript, and Slipdock proposes the decisions,
        actions and card changes in it, each tied to the words it came from. Nothing reaches a
        board until somebody reviews and commits it. Off, there is no trace of it anywhere:
        no menus, no routes, no commands, no MCP tools. Turning it off deletes nothing.
      </p>

      <.form for={@form} id="meetings-form" phx-submit="save-settings" class="mt-4 space-y-5">
        <input type="hidden" name="settings[signup_mode]" value={@settings.signup_mode} />
        <label class="flex cursor-pointer items-start gap-3 text-sm">
          <input type="hidden" name="settings[meetings_enabled]" value="false" />
          <input
            type="checkbox"
            id="meetings-enabled"
            name="settings[meetings_enabled]"
            value="true"
            checked={@settings.meetings_enabled}
            class="toggle toggle-sm mt-0.5"
          />
          <span>
            <span class="block font-medium">Meeting mode is on</span>
            <span class="block text-xs text-base-content/60">
              Captures are read with each person's AI settings, so their key or endpoint is
              what a meeting is sent to.
            </span>
          </span>
        </label>

        <fieldset class="space-y-2">
          <legend class="text-sm font-medium">Where it shows</legend>
          <label
            :for={
              {value, title, text} <- [
                {:used_only, "Only where used",
                 "A board's Meetings tab appears after its first capture. Until then there is one entry in the board's … menu."},
                {:every_board, "On every board", "Every board has a Meetings tab."}
              ]
            }
            class="flex cursor-pointer gap-3 rounded-xl p-3 ring-1 ring-base-content/10 hover:bg-base-200 has-[:checked]:bg-primary/5 has-[:checked]:ring-primary"
          >
            <input
              type="radio"
              name="settings[meetings_visibility]"
              value={value}
              checked={@settings.meetings_visibility == value}
              class="radio radio-sm mt-0.5"
            />
            <span class="text-sm">
              <span class="block font-medium">{title}</span>
              <span class="block text-xs text-base-content/60">{text}</span>
            </span>
          </label>
        </fieldset>

        <label class="flex cursor-pointer items-start gap-3 text-sm">
          <input type="hidden" name="settings[meetings_hideable]" value="false" />
          <input
            type="checkbox"
            name="settings[meetings_hideable]"
            value="true"
            checked={@settings.meetings_hideable}
            class="checkbox checkbox-sm mt-0.5"
          />
          <span>
            <span class="block font-medium">Let people hide it</span>
            <span class="block text-xs text-base-content/60">
              Each person can put meeting capture out of sight for themselves, under Account →
              Settings → Display.
            </span>
          </span>
        </label>

        <fieldset class="space-y-2">
          <legend class="text-sm font-medium">What may be sent</legend>
          <label
            :for={
              {field, title, text} <- [
                {:meetings_accept_transcripts, "Transcripts",
                 "WebVTT, SRT, Name: text, and Fireflies or Otter exports. Cost no transcription."},
                {:meetings_accept_audio, "Recordings",
                 "Stored on this server, counted against the board owner's file storage."},
                {:meetings_accept_findings, "Findings from an agent",
                 "An agent's own reading of the meeting, checked like Slipdock's."}
              ]
            }
            class="flex cursor-pointer items-start gap-3 text-sm"
          >
            <input type="hidden" name={"settings[#{field}]"} value="false" />
            <input
              type="checkbox"
              name={"settings[#{field}]"}
              value="true"
              checked={Map.get(@settings, field)}
              class="checkbox checkbox-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">{title}</span>
              <span class="block text-xs text-base-content/60">{text}</span>
            </span>
          </label>
        </fieldset>

        <fieldset class="space-y-3">
          <legend class="text-sm font-medium">Reading</legend>
          <p class="text-xs text-base-content/60">
            Every meeting is read twice, independently, and what only one reading found is marked
            so. Each reading runs on the AI settings of the person who sent the meeting.
          </p>
          <.input
            field={@form[:meetings_reading_model]}
            label="Model for the first reading"
            placeholder="Empty: each person's own model"
            value={@settings.meetings_reading_model}
          />
          <.input
            field={@form[:meetings_second_reading]}
            type="select"
            label="Second reading"
            options={[
              {"The same model again", "same"},
              {"Another model", "model"},
              {"None (one reading only)", "off"}
            ]}
            value={@settings.meetings_second_reading}
          />
          <.input
            field={@form[:meetings_second_model]}
            label="Model for the second reading"
            placeholder="Only used with “Another model”"
            value={@settings.meetings_second_model}
          />
        </fieldset>

        <fieldset id="meetings-limits" class="space-y-3">
          <legend class="text-sm font-medium">Limits, per person per month</legend>
          <p class="text-xs text-base-content/60">
            Checked before anything is stored or sent to a provider. Transcription and reading on a
            person's own AI key or endpoint don't count; stored audio always does.
          </p>
          <div
            :for={
              {switch, number, label} <- [
                {:meetings_transcription_minutes_enabled, :meetings_transcription_minutes,
                 "Transcription minutes"},
                {:meetings_audio_storage_mb_enabled, :meetings_audio_storage_mb,
                 "Stored meeting audio (MB)"},
                {:meetings_transcript_captures_enabled, :meetings_transcript_captures,
                 "Captures from transcripts"}
              ]
            }
            class="flex items-end gap-3"
          >
            <label class="flex items-center gap-2 pb-2 text-sm">
              <input type="hidden" name={"settings[#{switch}]"} value="false" />
              <input
                type="checkbox"
                name={"settings[#{switch}]"}
                value="true"
                checked={Map.get(@settings, switch)}
                class="checkbox checkbox-sm"
              /> {label}
            </label>
            <input
              type="number"
              min="0"
              name={"settings[#{number}]"}
              value={Map.get(@settings, number)}
              class="input input-sm w-28"
              aria-label={label}
            />
          </div>
          <div class="grid gap-3 sm:grid-cols-3">
            <.input
              field={@form[:meetings_longest_minutes]}
              type="number"
              label="Longest meeting (minutes)"
              value={@settings.meetings_longest_minutes}
            />
            <.input
              field={@form[:meetings_max_file_mb]}
              type="number"
              label="Largest recording (MB)"
              value={@settings.meetings_max_file_mb}
            />
            <.input
              field={@form[:meetings_audio_retention]}
              type="select"
              label="Keep recordings"
              options={[
                {"Until committed", "until_committed"},
                {"30 days", "30_days"},
                {"90 days", "90_days"}
              ]}
              value={@settings.meetings_audio_retention}
            />
          </div>
        </fieldset>

        <button type="submit" class="btn btn-primary btn-sm">Save</button>
      </.form>
    </section>

    <section
      id="meetings-usage"
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">This month</h2>
      <p class="mt-1 text-sm text-base-content/60">
        What meeting capture has cost the server since {Calendar.strftime(
          @meetings_usage.month,
          "%-d %B"
        )}:
        work on people's own keys is theirs and not counted here.
      </p>
      <dl class="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
        <dt class="text-base-content/60">Transcription</dt>
        <dd id="usage-minutes">{@meetings_usage.transcription_minutes} min</dd>
        <dt class="text-base-content/60">Model tokens</dt>
        <dd id="usage-tokens">{@meetings_usage.tokens}</dd>
        <dt class="text-base-content/60">Cost reported</dt>
        <dd id="usage-cost">${:erlang.float_to_binary(@meetings_usage.cost, decimals: 2)}</dd>
        <dt class="text-base-content/60">Audio stored</dt>
        <dd id="usage-audio">{div(@meetings_usage.audio_bytes, 1024 * 1024)} MB</dd>
      </dl>
      <table :if={@meetings_usage.heaviest != []} id="usage-heaviest" class="table table-sm mt-3">
        <thead>
          <tr>
            <th>Heaviest users</th><th>Transcription</th><th>Tokens</th><th>Cost</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={h <- @meetings_usage.heaviest}>
            <td>{h.name || h.email}</td>
            <td>{div(round(h.transcription_seconds), 60)} min</td>
            <td>{h.tokens}</td>
            <td>${:erlang.float_to_binary(h.cost, decimals: 2)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp server_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="text-lg font-semibold">Who can register</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Changing this does not remove anybody. People who already have an account keep it,
        whichever way you set this.
      </p>

      <.form for={@form} id="admin-settings-form" phx-submit="save-settings" class="mt-4 space-y-5">
        <label
          :for={mode <- Instance.signup_modes()}
          class="flex cursor-pointer gap-3 rounded-xl p-3 ring-1 ring-base-content/10 hover:bg-base-200 has-[:checked]:bg-primary/5 has-[:checked]:ring-primary"
        >
          <input
            type="radio"
            name="settings[signup_mode]"
            value={mode}
            checked={@settings.signup_mode == mode}
            class="radio radio-sm mt-0.5 radio-primary"
          />
          <span class="min-w-0">
            <span class="block text-sm font-medium">{mode_label(mode)}</span>
            <span class="block text-xs text-base-content/60">{mode_detail(mode)}</span>
          </span>
        </label>

        <.input
          field={@form[:free_card_limit]}
          type="number"
          label="Items allowed per free account"
          value={@settings.free_card_limit}
          placeholder="No limit"
        />
        <p class="-mt-3 text-xs text-base-content/60">
          Cards, wiki pages and uploaded files together, on the boards they own.
          Blank for no limit, which is what a server you run for yourself wants.
          Accounts with a paid-up date, and admins, are not counted against this.
        </p>

        <.limit_control
          form={@form}
          settings={@settings}
          switch={:trial_enabled}
          number={:trial_days}
          label="Free accounts expire"
          unit="days after they are made"
          hint="A free trial. It stands alongside the limits below rather than inside
                them: an account can have no card limit at all and still run out of
                trial. Nothing is deleted and nothing is locked — an expired account
                can read and edit everything it has, but cannot add anything new.
                Set a paid-up date on a person in Users to take them off the clock."
        />

        <fieldset class="space-y-4 rounded-xl p-4 ring-1 ring-base-content/10">
          <legend class="px-1 text-sm font-medium">Limits for everybody</legend>
          <p class="text-xs text-base-content/60">
            These apply to every account on this server, free or paid, admin or not,
            however this server is run. They are not a way to sell anything — they are
            the ceiling that stops one runaway import filling the disk. Turn any of
            them off if you would rather have no ceiling at all.
          </p>

          <.limit_control
            form={@form}
            settings={@settings}
            switch={:board_limit_enabled}
            number={:board_limit}
            label="Boards one person may own"
            unit="boards"
            hint="Sub-boards — the ones behind subcards — do not count."
          />

          <.limit_control
            form={@form}
            settings={@settings}
            switch={:item_limit_enabled}
            number={:item_limit}
            label="Items on one person's boards"
            unit="cards, pages and files"
            hint="Counted the same way as the free allowance above. Where both apply,
                  the lower one wins."
          />

          <.limit_control
            form={@form}
            settings={@settings}
            switch={:storage_limit_enabled}
            number={:storage_limit_mb}
            label="Files on one person's boards"
            unit="MB"
            hint="The sum of every attachment behind their boards. 10240 is 10 GB."
          />
        </fieldset>

        <fieldset class="space-y-2">
          <legend class="text-sm font-medium">Who people can see</legend>
          <label class="flex cursor-pointer items-start gap-3 text-sm">
            <input
              type="radio"
              name="settings[user_directory]"
              value="instance"
              checked={@settings.user_directory == :instance}
              class="radio radio-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">Everyone on this server</span>
              <span class="block text-xs text-base-content/60">
                Right for one person or a team who all work together.
              </span>
            </span>
          </label>
          <label class="flex cursor-pointer items-start gap-3 text-sm">
            <input
              type="radio"
              name="settings[user_directory]"
              value="shared_only"
              checked={@settings.user_directory == :shared_only}
              class="radio radio-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">Only people they share something with</span>
              <span class="block text-xs text-base-content/60">
                Right when strangers share this server. Changing to this hides people from
                each other who can see each other today.
              </span>
            </span>
          </label>
        </fieldset>

        <label class="flex cursor-pointer items-start gap-3 text-sm">
          <input type="hidden" name="settings[invites_create_accounts]" value="false" />
          <input
            type="checkbox"
            name="settings[invites_create_accounts]"
            value="true"
            checked={@settings.invites_create_accounts}
            class="checkbox checkbox-sm mt-0.5"
          />
          <span>
            <span class="block font-medium">Sharing with a stranger gives them an account</span>
            <span class="block text-xs text-base-content/60">
              Off, you can only share with people who already have one. On, anybody you share
              a card with can use this server — subject to the card limit above.
            </span>
          </span>
        </label>

        <button type="submit" class="btn btn-primary">Save</button>
      </.form>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Terms and privacy</h3>
        <p class="mt-1 text-xs text-base-content/60">
          For a server other people use. Fill in a link and a version and the sign-in page says
          that signing in means agreeing to them, linking to both; each sign-in records the
          version in force. Leave them empty — as a server only you use should — and none of
          this appears anywhere.
        </p>

        <.form for={@form} id="terms-form" phx-submit="save-settings" class="mt-3 space-y-3">
          <input type="hidden" name="settings[signup_mode]" value={@settings.signup_mode} />
          <.input
            field={@form[:terms_url]}
            type="url"
            label="Terms of service"
            value={@settings.terms_url}
            placeholder="https://example.com/terms"
          />
          <.input
            field={@form[:privacy_url]}
            type="url"
            label="Privacy notice"
            value={@settings.privacy_url}
            placeholder="https://example.com/privacy"
          />
          <.input
            field={@form[:terms_version]}
            type="text"
            label="Version"
            value={@settings.terms_version}
            placeholder="2026-10-02"
          />
          <p class="text-xs text-base-content/60">
            Writing the terms themselves is your job, not Slipdock's. One thing they should
            say: card and page text is sent to OpenRouter when anybody uses the AI features.
          </p>
          <button type="submit" class="btn btn-outline btn-sm">Save</button>
        </.form>
      </div>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Product analytics and error tracking</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Fill in a PostHog project key and a host, and every page sends pageviews, clicks and
          its uncaught errors to PostHog, and the server sends its own errors and crashes to
          PostHog's Error Tracking. Leave either empty and nothing about PostHog is loaded at
          all — no script, no requests.
        </p>

        <.form for={@form} id="analytics-form" phx-submit="save-settings" class="mt-3 space-y-3">
          <input type="hidden" name="settings[signup_mode]" value={@settings.signup_mode} />
          <.input
            field={@form[:posthog_key]}
            type="text"
            label="PostHog project key"
            value={@settings.posthog_key}
            placeholder="phc_..."
            autocomplete="off"
          />
          <.input
            field={@form[:posthog_host]}
            type="url"
            label="PostHog host"
            value={@settings.posthog_host}
            placeholder="https://us.i.posthog.com"
          />
          <p class="text-xs text-base-content/60">
            https://us.i.posthog.com for PostHog's US cloud, https://eu.i.posthog.com for
            the EU one, or the address of a proxy of your own (which must serve both the
            script and the ingest endpoints). A key with no host leaves analytics off — the
            region is never guessed. If people use this server, your privacy notice should
            say that it uses PostHog.
          </p>
          <label class="flex cursor-pointer items-start gap-3 text-sm">
            <input type="hidden" name="settings[posthog_respect_dnt]" value="false" />
            <input
              type="checkbox"
              name="settings[posthog_respect_dnt]"
              value="true"
              checked={@settings.posthog_respect_dnt}
              class="checkbox checkbox-sm mt-0.5"
            />
            <span>
              <span class="block font-medium">Respect Do-Not-Track</span>
              <span class="block text-xs text-base-content/60">
                On, a visitor whose browser asks not to be tracked (Do-Not-Track or Global
                Privacy Control) is left out of analytics. Off, everyone is counted.
              </span>
            </span>
          </label>
          <button type="submit" class="btn btn-outline btn-sm">Save</button>
        </.form>
      </div>

      <div id="ai-system" class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">AI for search and automations</h3>
        <p class="mt-1 text-xs text-base-content/60">
          Semantic search, the search index and scheduled automations run with nobody signed
          in, so they cannot use whoever is looking. They use one admin's AI settings — the key
          or endpoint saved under Account → AI model — and every board's content is sent
          through them.
        </p>

        <p :if={@ai_source.source != :none} id="ai-system-status" class="mt-3 text-sm">
          <.icon name="hero-check-circle" class="size-4 text-success" />
          <span>Now using {ai_source_text(@ai_source)}.</span>
        </p>
        <p :if={@ai_source.source == :none} id="ai-system-status" class="mt-3 text-sm text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          Off: semantic search and AI automations will not run until an admin with an AI key
          is chosen here.
        </p>

        <.form for={@form} id="ai-system-form" phx-submit="save-settings" class="mt-3 space-y-3">
          <input type="hidden" name="settings[signup_mode]" value={@settings.signup_mode} />
          <.input
            field={@form[:ai_system_user_id]}
            type="select"
            label="Whose AI settings to use"
            options={@ai_candidates}
            prompt="Nobody chosen (fall back to the environment, or the only admin with a key)"
            value={@settings.ai_system_user_id}
          />
          <p class="text-xs text-base-content/60">
            Only admins are offered: anyone else could point their account at a server of their
            own and receive every card. Searches and indexing are billed to that person's key.
          </p>
          <button type="submit" class="btn btn-outline btn-sm">Save</button>
        </.form>
      </div>

      <div :if={@settings.signup_mode == :allowlist} class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Who is allowed</h3>
        <p class="mt-1 text-xs text-base-content/60">
          An address, or a bare domain to let in everybody there.
        </p>

        <ul class="mt-3 divide-y divide-base-content/5">
          <li :for={entry <- @allowlist} class="flex items-center justify-between py-2 text-sm">
            <span class="font-mono">{entry.entry}</span>
            <span class="flex items-center gap-3">
              <span class="text-xs text-base-content/50">
                {if entry.last_used_at, do: "used", else: "never used"}
              </span>
              <button
                type="button"
                phx-click="remove-allow"
                phx-value-id={entry.id}
                class="btn btn-ghost btn-xs"
              >
                Remove
              </button>
            </span>
          </li>
          <li :if={@allowlist == []} class="py-2 text-sm text-base-content/50">
            Nobody yet — so nobody new can register.
          </li>
        </ul>

        <.form for={@allow_form} id="allow-form" phx-submit="add-allow" class="mt-3 flex gap-2">
          <div class="flex-1">
            <.input
              field={@allow_form[:entry]}
              type="text"
              placeholder="you@example.com or example.com"
            />
          </div>
          <button type="submit" class="btn btn-outline">Add</button>
        </.form>
      </div>
    </section>
    """
  end

  defp mail_tab(assigns) do
    ~H"""
    <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
      <h2 class="text-lg font-semibold">Email</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Sign-in codes, invitations and whatever your automation rules send.
      </p>

      <.form for={@mail_form} id="admin-mail-form" phx-submit="mail" class="mt-4 space-y-4">
        <.input
          field={@mail_form[:smtp_host]}
          type="text"
          label="Mail server"
          placeholder="smtp.example.com"
        />
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@mail_form[:smtp_port]}
            type="number"
            label="Port"
            placeholder="587"
          />
          <.input
            field={@mail_form[:smtp_tls]}
            type="select"
            label="TLS"
            options={Enum.map(Instance.tls_modes(), &{humanise_tls(&1), &1})}
          />
        </div>
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@mail_form[:smtp_username]}
            type="text"
            label="Username"
            value={@settings.smtp_username}
            autocomplete="off"
          />
          <.input
            field={@mail_form[:smtp_password]}
            type="password"
            label="Password"
            placeholder={if Settings.smtp_password_set?(), do: "unchanged", else: ""}
            autocomplete="off"
          />
        </div>
        <p class="-mt-2 text-xs text-base-content/60">
          Leave the password empty to keep the one already stored — it is never sent to your
          browser, so it cannot be sent back.
        </p>
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@mail_form[:smtp_from_email]}
            type="email"
            label="Send from"
          />
          <.input
            field={@mail_form[:smtp_from_name]}
            type="text"
            label="Sender name"
            value={@settings.smtp_from_name}
          />
        </div>

        <div class="rounded-xl bg-base-200 p-4">
          <p class="text-sm font-medium">Send a test message</p>
          <p class="mt-1 text-xs text-base-content/60">
            Changes cannot be saved until one arrives. A mail server that does not work is how
            everybody gets locked out of this server for good.
          </p>
          <div class="mt-3 flex items-end gap-2">
            <div class="flex-1">
              <.input
                field={@mail_form[:test_to]}
                type="email"
                label="To"
              />
            </div>
            <button type="submit" name="step_action" value="test" class="btn btn-outline mb-1">
              Send test
            </button>
          </div>
          <p :if={@mail_error} class="mt-2 text-sm text-error">{@mail_error}</p>
          <p :if={@mail_tested?} class="mt-2 text-sm text-success">
            <.icon name="hero-check-circle" class="size-4" /> A test message went out.
          </p>
          <p :if={@settings.smtp_verified_at} class="mt-2 text-xs text-base-content/50">
            Last confirmed working: {@settings.smtp_verified_at}
          </p>
        </div>

        <button type="submit" name="step_action" value="save" class="btn btn-primary">Save</button>
      </.form>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">When mail is not working</h3>
        <p class="mt-1 text-sm text-base-content/70">
          Sign-in codes are written to a file on the server and to its log, so that an
          instance with no mail can still be used.
          <span class="font-medium">Anyone who can read either can sign in as anybody</span>
          — fine on a machine only you can reach, a hole on one you share.
        </p>
        <p class="mt-2 text-sm">
          Right now:
          <span class="font-medium">
            {if Settings.login_fallback_enabled?(), do: Accounts.fallback_path(), else: "off"}
          </span>
        </p>
        <p :if={forced_fallback_off?()} class="mt-2 rounded-xl bg-base-200 p-3 text-xs">
          Forced off by <code class="font-mono">SLIPDOCK_LOGIN_FALLBACK=false</code>
          in this server's environment, which nothing here can undo. That is the right
          setting for a host other people can reach.
        </p>
      </div>

      <div class="mt-6 border-t border-base-content/10 pt-6">
        <h3 class="font-medium">Admin address</h3>
        <p class="mt-1 text-sm text-base-content/60">
          Where requests and warnings go. Currently <span class="font-medium">{@settings.admin_email || "nowhere"}</span>.
          A new address has to confirm a code before it takes effect — an admin address
          nobody reads is a silent lock-out.
        </p>

        <.form
          for={@form}
          id="admin-email-form"
          phx-submit="change-admin-email"
          class="mt-3 flex gap-2"
        >
          <div class="flex-1">
            <.input field={@form[:admin_email]} type="email" placeholder="new@example.com" />
          </div>
          <button type="submit" class="btn btn-outline">Send a code</button>
        </.form>

        <.form
          for={to_form(%{}, as: :confirm)}
          id="admin-email-confirm"
          phx-submit="confirm-admin-email"
          class="mt-2 flex gap-2"
        >
          <div class="flex-1">
            <.input
              field={to_form(%{}, as: :confirm)[:code]}
              type="text"
              placeholder="Code from the new address"
            />
          </div>
          <button type="submit" class="btn btn-ghost">Confirm</button>
        </.form>
      </div>
    </section>
    """
  end
end
