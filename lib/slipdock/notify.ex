defmodule Slipdock.Notify do
  @moduledoc """
  Telling one person about something on a card (#2101): a wait opened on
  them or routed to them (`Slipdock.Boards.WaitEmail`), an @mention of them
  (`Slipdock.Mentions`).

  The callers decide who is told; this does the telling, on every channel
  there is. Today that is two:

    * **email**, unchanged: `Slipdock.Automations.Notifier.deliver/4`;
    * **the browser**: a broadcast on the person's own topic (`topic/1`).
      `SlipdockWeb.NotifyHook` subscribes every signed-in LiveView to it and
      pushes `desktop-notify` to the page, where the `DesktopNotify` hook
      (`assets/js/desktop_notify.js`) shows a desktop toast if this browser
      has them on. No tab open means nobody is listening, and nothing shows:
      on purpose, there is no Web Push.

  Each telling has its own id, sent as the toast's `tag`, so the same
  person's several tabs show one toast rather than one each.

  Both happen through `Slipdock.Deferred`, so a write that rolls back tells
  nobody.
  """

  alias Slipdock.Accounts.User
  alias Slipdock.Automations.Notifier
  alias Slipdock.Boards.Card

  @pubsub Slipdock.PubSub

  @doc "The PubSub topic a person's own notifications go to."
  @spec topic(User.t() | integer()) :: String.t()
  def topic(%User{id: id}), do: topic(id)
  def topic(id) when is_integer(id), do: "notify:user:#{id}"

  @doc "Subscribes the calling process to `user`'s notifications."
  def subscribe(user), do: Phoenix.PubSub.subscribe(@pubsub, topic(user))

  @doc """
  Tells `person` about `card`.

    * `:subject` and `:body`: the email;
    * `:email`: options for `Notifier.deliver/4` (`card:` is added);
    * `:title` and `:text`: the toast (`:title` defaults to the subject);
    * `:kind`: what it is about (`"wait"`, `"wait_routed"`, `"mention"`);
    * `:by`: who did it, if known, so a page can tell its own reader's
      doing apart (the callers never tell someone about their own act).
  """
  @spec person(User.t(), Card.t(), keyword()) :: :ok
  def person(%User{} = person, %Card{} = card, opts) do
    subject = Keyword.fetch!(opts, :subject)
    email_opts = Keyword.put(Keyword.get(opts, :email, []), :card, card)
    event = event(person, card, opts)

    Slipdock.Deferred.defer(fn ->
      Notifier.deliver([person.email], subject, Keyword.fetch!(opts, :body), email_opts)
      Phoenix.PubSub.broadcast(@pubsub, topic(person), {:notify, event})
    end)

    :ok
  end

  defp event(person, card, opts) do
    %{
      id: "notify-" <> Ecto.UUID.generate(),
      kind: Keyword.get(opts, :kind, "card"),
      user_id: person.id,
      by_id: by_id(opts[:by]),
      card_id: card.id,
      board_id: card.board_id,
      path: "/boards/#{card.board_id}/cards/#{card.id}",
      title: Keyword.get(opts, :title) || Keyword.fetch!(opts, :subject),
      body: opts |> Keyword.get(:text, "") |> to_string() |> String.slice(0, 240)
    }
  end

  defp by_id(%User{id: id}), do: id
  defp by_id(id) when is_integer(id), do: id
  defp by_id(_), do: nil
end
