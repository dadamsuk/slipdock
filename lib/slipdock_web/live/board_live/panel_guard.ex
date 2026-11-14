defmodule SlipdockWeb.BoardLive.PanelGuard do
  @moduledoc """
  The gate at the top of a board panel's `handle_event/3` (#2893): which
  events the panel takes at all, and who may fire which of them.

  Each of the board's LiveComponents used to open `handle_event/3` with the
  same hand-written clauses (an event not on its list refused, then the
  read-only or owner-only refusals), and the copies drifted. A panel now
  says what its gate is and `use`s this module, which writes those clauses:

      use SlipdockWeb.BoardLive.PanelGuard,
        events: @events,
        access: &assign_access/1,
        refusals: [{:can_write, false, @write_events, :read_only}],
        say: :flash

  An event comes in, and in order:

  1. one not in `:events` is refused with "That isn't something this page
     can do." (`unknown/0`), without asking anything of the database;
  2. `:access` reads the reader's level again (a panel's `update/2` runs
     only when the board hands it something new, so a lowered grant must be
     read at the event, #2771), then `:prepare` runs (clearing the last
     notice, say);
  3. the first of `:refusals` that matches decides (`verdict/3`). Each is
     `{assign, value, events, answer}`: it matches when the socket's
     `assign` is `value` and the event is among `events` (a list, `:all`,
     or `{:except, list}`). The answer is a sentence (or `:read_only`,
     `:owner`, or a function of the socket giving one) to refuse with,
     `:quiet` to do nothing and say nothing, or `:pass` to let the event
     through without looking at the refusals after it;
  4. otherwise the event goes to the panel's `:then` function (`event/3`
     unless named), and `:after`, if given, runs on the socket it returns.

  A refusal is said where the panel says things (`:say`): a flash (`:flash`,
  as `Helpers.flash/3`), the panel's callout (`:notice`, as `Helpers.notice/3`), or
  its `error` assign (`:error`), or a function of the socket and the
  sentence that says it some other way. With `:reply`, a refusal answers the push
  with that map, for a panel whose hooks wait on a reply (the tag name box
  reads `reply.ok`; a push answered `:noreply` leaves `reply` undefined).
  """

  @unknown "That isn't something this page can do."
  @read_only "You have read-only access to this board."
  @owner "Only the board's owner can do that."

  @doc "What a panel says to an event it doesn't take."
  def unknown, do: @unknown

  @doc "What a panel says to a write from a reader who may only read the board."
  def read_only, do: @read_only

  @doc "What an owner's panel says to anybody else."
  def owner, do: @owner

  defmacro __using__(opts) do
    events = Keyword.fetch!(opts, :events)
    access = Keyword.get(opts, :access, quote(do: & &1))
    prepare = Keyword.get(opts, :prepare, quote(do: & &1))
    refusals = Keyword.get(opts, :refusals, [])
    say = Keyword.get(opts, :say, :flash)
    reply = Keyword.get(opts, :reply)
    then = Keyword.get(opts, :then, :event)
    after_fun = Keyword.get(opts, :after)

    quote do
      @impl true
      def handle_event(event, _params, socket) when event not in unquote(events),
        do: SlipdockWeb.BoardLive.PanelGuard.refuse(socket, nil, unquote(say), unquote(reply))

      def handle_event(event, params, socket) do
        socket = socket |> unquote(access).() |> unquote(prepare).()

        case SlipdockWeb.BoardLive.PanelGuard.verdict(event, socket, unquote(refusals)) do
          :ok ->
            SlipdockWeb.BoardLive.PanelGuard.finish(
              unquote(then)(event, params, socket),
              unquote(after_fun)
            )

          :quiet ->
            {:noreply, socket}

          {:refuse, message} ->
            SlipdockWeb.BoardLive.PanelGuard.refuse(
              socket,
              message,
              unquote(say),
              unquote(reply)
            )
        end
      end
    end
  end

  @doc """
  What the gate makes of `event` for this socket: `:ok` to handle it,
  `:quiet` to drop it, or `{:refuse, message}`. The first refusal that
  matches decides; `:pass` lets the event through at once.
  """
  def verdict(event, socket, refusals) do
    Enum.find_value(refusals, :ok, fn {key, value, events, answer} ->
      if Map.get(socket.assigns, key) == value and covers?(events, event),
        do: answer(answer, socket)
    end)
  end

  defp covers?(:all, _event), do: true
  defp covers?({:except, events}, event), do: not Enum.member?(events, event)
  defp covers?(events, event) when is_list(events), do: Enum.member?(events, event)

  defp answer(:pass, _socket), do: :ok
  defp answer(:quiet, _socket), do: :quiet
  defp answer(:read_only, _socket), do: {:refuse, @read_only}
  defp answer(:owner, _socket), do: {:refuse, @owner}
  defp answer(fun, socket) when is_function(fun, 1), do: {:refuse, fun.(socket)}
  defp answer(message, _socket) when is_binary(message), do: {:refuse, message}

  @doc false
  # A refusal, said where the panel says things. `nil` is the unknown event's.
  def refuse(socket, message, say, reply) do
    socket = say(socket, say, message || @unknown)
    if reply, do: {:reply, reply, socket}, else: {:noreply, socket}
  end

  # What `Helpers.flash/3` and `Helpers.notice/3` do, written here: a module
  # every panel `use`s calls nothing in the app, or the panels' compile-time
  # dependency on it joins their cycles (ARCH-2).
  defp say(socket, :flash, message) do
    send(self(), {:put_flash, :error, message})
    socket
  end

  defp say(socket, :notice, message),
    do: Phoenix.Component.assign(socket, panel_notice: {:error, message})

  defp say(socket, :error, message), do: Phoenix.Component.assign(socket, error: message)
  defp say(socket, fun, message) when is_function(fun, 2), do: fun.(socket, message)

  @doc false
  # The handler's result, with the panel's `:after` run on its socket.
  def finish(result, nil), do: result
  def finish({:noreply, socket}, fun), do: {:noreply, fun.(socket)}
  def finish({:reply, map, socket}, fun), do: {:reply, map, fun.(socket)}

  @doc """
  Tells the board whether a picker the panel opens is open now, when that
  changed: the card panel stands aside while one is (the board's render).
  `open_key` is the assign holding the open picker (nil when shut),
  `flag_key` the assign remembering what the board was last told, and the
  board is sent `{message, open?}`.
  """
  def tell_board(socket, open_key, flag_key, message) do
    open = not is_nil(socket.assigns[open_key])
    if open != socket.assigns[flag_key], do: send(self(), {message, open})
    Phoenix.Component.assign(socket, flag_key, open)
  end
end
