defmodule SlipdockWeb.AccountLive.ProfileComponent do
  @moduledoc """
  The Account tab: who you are, what you have used, who has been let in, and
  the way out.
  """
  use SlipdockWeb, :live_component

  alias Slipdock.Accounts

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Loaded once. The parent hands a fresh `current_user` back down after a
    # save, which must not cost the queries a second time.
    if Map.has_key?(socket.assigns, :profile_form),
      do: {:ok, socket},
      else: {:ok, load(socket)}
  end

  defp load(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(profile_form: to_form(Accounts.change_profile(user)))
    |> assign(quota: Slipdock.Quota.status(user))
    |> assign(limits: Slipdock.Quota.report(user))
    |> assign(support_sessions: Accounts.support_sessions_for(user))
    |> assign(source_url: Slipdock.Config.get(:source_url))
  end

  @impl true
  def handle_event("save_profile", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, params) do
      {:ok, user} ->
        # The header shows the name too, so the page needs the new user.
        send(self(), {:current_user, user})
        send(self(), {:flash, :info, "Profile saved."})

        {:noreply,
         assign(socket, current_user: user, profile_form: to_form(Accounts.change_profile(user)))}

      {:error, cs} ->
        {:noreply, assign(socket, profile_form: to_form(cs))}
    end
  end

  # One limit, with a bar and a sentence when it is close or full. Shared by
  # items, boards and storage so the three never drift apart in wording.
  attr :label, :string, required: true
  attr :status, :map, required: true
  attr :detail, :string, default: nil
  attr :bytes, :boolean, default: false
  attr :full, :string, required: true
  attr :near, :string, required: true

  defp usage(assigns) do
    assigns = assign(assigns, :near?, near?(assigns.status))

    ~H"""
    <div class="mt-4">
      <div class="flex items-baseline justify-between text-sm">
        <span class="font-medium">
          {@label}: {amount(@status.used, @bytes)} of {amount(@status.limit, @bytes)} used
        </span>
        <span class="text-base-content/60">{amount(@status.remaining, @bytes)} left</span>
      </div>
      <progress
        class={[
          "progress mt-2 w-full",
          cond do
            @status.remaining == 0 -> "progress-error"
            @near? -> "progress-warning"
            true -> "progress-primary"
          end
        ]}
        value={@status.used}
        max={@status.limit}
      ></progress>
      <p :if={@detail} class="mt-1 text-xs text-base-content/60">{@detail}</p>
      <p :if={@near?} class="mt-3 rounded-xl bg-warning/10 p-3 text-sm">
        {if @status.remaining == 0, do: @full, else: @near}
      </p>
    </div>
    """
  end

  defp amount(value, true), do: Slipdock.Quota.humanise_bytes(value)
  defp amount(value, _bytes), do: value

  # The same fifth-of-the-limit rule `Slipdock.Quota.warning?/2` uses, applied
  # to a status already in hand rather than by asking the database again.
  defp near?(%{limit: limit, remaining: remaining}),
    do: remaining <= max(div(limit, 5), 1)

  # Whether a bar tells this person anything. Every install has the guardrails
  # on, so without this a self-hoster with four cards would be shown "4 of
  # 250,000" — a number that is true, useless, and slightly alarming. Shown
  # once a hundredth of it is gone, or once it is close.
  defp worth_showing?(%{limited?: false}), do: false

  defp worth_showing?(%{used: used, limit: limit} = status),
    do: used * 100 >= limit or near?(status)

  # Still in force, as opposed to merely recorded.
  defp live_support?(session) do
    is_nil(session.ended_at) and DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">Profile</h2>
        <p class="text-sm text-base-content/60">Signed in as {@current_user.email}</p>
        <.form
          for={@profile_form}
          id="profile-form"
          phx-submit="save_profile"
          phx-target={@myself}
          class="mt-4 flex items-end gap-3"
        >
          <div class="flex-1">
            <.input field={@profile_form[:name]} label="Display name" placeholder="Your name" />
          </div>
          <button type="submit" class="btn btn-primary">Save</button>
        </.form>
      </section>

      <section
        :if={@limits.trial.applies?}
        class={[
          "rounded-2xl p-6 shadow-sm ring-1",
          if(@limits.trial.expired?,
            do: "bg-error/10 ring-error/30",
            else: "bg-base-100 ring-base-content/10"
          )
        ]}
      >
        <h2 class="text-lg font-semibold">
          {if @limits.trial.expired?, do: "Your free trial has ended", else: "Free trial"}
        </h2>
        <p class="mt-1 text-sm text-base-content/60">
          A free account on this server lasts {@limits.trial.days} days from the day
          it was made. Everything you have made stays here and stays editable either
          way — what ends is adding anything new.
        </p>
        <p class="mt-3 text-sm font-medium">
          {if @limits.trial.expired?,
            do: "Ended #{Calendar.strftime(@limits.trial.ends_at, "%-d %B %Y")}.",
            else:
              "#{@limits.trial.days_left} day(s) left — until #{Calendar.strftime(@limits.trial.ends_at, "%-d %B %Y")}."}
        </p>
      </section>

      <section
        :if={Enum.any?([@limits.items, @limits.boards, @limits.storage], &worth_showing?/1)}
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="text-lg font-semibold">What you are using</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Counted across the boards you own. Things on boards other people have shared
          with you cost you nothing; archiving a card or a page frees it up again, and
          a file counts until it is deleted.
        </p>

        <.usage
          :if={worth_showing?(@limits.items)}
          label="Cards, pages and files"
          status={@limits.items}
          detail={"#{@limits.breakdown.cards} cards · #{@limits.breakdown.pages} pages · #{@limits.breakdown.files} files"}
          full="You have used all of them. Archive something you have finished with, or subscribe for more."
          near="You are close to the limit. Archiving something you have finished with frees it up."
        />

        <.usage
          :if={worth_showing?(@limits.boards)}
          label="Boards you own"
          status={@limits.boards}
          full="You own as many boards as this server allows. Archive one, or ask an admin to raise the limit."
          near="You are close to the limit on boards."
        />

        <.usage
          :if={worth_showing?(@limits.storage)}
          label="Files"
          status={@limits.storage}
          bytes={true}
          full="Your files fill the space this server allows. Delete some attachments, or ask an admin to raise the limit."
          near="You are close to the limit on file storage."
        />
      </section>

      <section
        :if={@support_sessions != []}
        class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
      >
        <h2 class="text-lg font-semibold">Support access to your boards</h2>
        <p class="mt-1 text-sm text-base-content/60">
          Every time an admin of this server has been given access to your boards, and why.
          Current ones are marked; the rest are over.
        </p>

        <ul class="mt-4 space-y-2 text-sm">
          <li :for={session <- @support_sessions} class="flex items-start gap-2">
            <span class={[
              "badge badge-sm mt-0.5",
              if(live_support?(session), do: "badge-warning", else: "badge-ghost")
            ]}>
              {if live_support?(session), do: "now", else: "ended"}
            </span>
            <span>
              <span class="font-medium">{Accounts.User.display_name(session.admin)}</span>
              — “{session.reason}”
              <span class="block text-xs text-base-content/50">
                from {session.inserted_at}, until {session.expires_at}
              </span>
            </span>
          </li>
        </ul>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">Session</h2>
        <p class="text-sm text-base-content/60">
          Sign-in links keep you signed in for 30 days on this browser.
        </p>
        <.link href={~p"/logout"} method="delete" class="btn btn-outline btn-sm mt-4">
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Sign out
        </.link>
      </section>

      <section class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <h2 class="text-lg font-semibold">About</h2>
        <p class="text-sm text-base-content/60">
          Slipdock is free software under the <a
            href="https://www.gnu.org/licenses/agpl-3.0.html"
            target="_blank"
            rel="noopener"
            class="link"
          >GNU AGPL v3</a>. You are using it over a network, so you are entitled to its
          source — including any changes whoever runs this server has made: <a
            href={@source_url}
            target="_blank"
            rel="noopener"
            class="link break-all"
          >{@source_url}</a>.
        </p>
      </section>
    </div>
    """
  end
end
