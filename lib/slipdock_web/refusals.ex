defmodule SlipdockWeb.Refusals do
  @moduledoc """
  A door's refusal of a write the context refused (`Slipdock.Policy`,
  #3169; W-1945 §Permissions, *Where authorisation lives*).

  The context answers `{:error, %Slipdock.Policy.Refused{}}` when it
  refuses a write, whatever the door checked first. A LiveView's handler
  may match the answer itself and say it, but one written before the
  context asked may ignore it, or crash matching `{:ok, _}`. `said/3` runs
  the handler so neither happens: a crash on a refusal (or on what the
  handler made of one) is caught, and a
  refusal the handler didn't say is said, in the door's own words place
  (the panel's notice, the page's flash). REST and MCP turn one into a 403
  and a tool error (`SlipdockWeb.API.FallbackController`,
  `SlipdockWeb.MCP.Args.refusal/1`).
  """

  alias Slipdock.Policy
  alias Slipdock.Policy.Refused

  @doc """
  Runs `handler` (an event's `{:noreply, socket}` or `{:reply, map,
  socket}`) for `socket`. A refusal the context answered while it ran is
  said with `say.(socket, message)`, unless the handler said something
  already (`said?.(before, after)`, by default a new flash or panel error).
  """
  def said(socket, handler, say, said? \\ &said_already?/2) when is_function(handler, 0) do
    Policy.take_refusal()

    result =
      try do
        handler.()
      rescue
        # A crash on the refusal itself (matching `{:ok, _}`), or on anything
        # the handler then did with it (`changeset.errors` of a refusal, say,
        # #3172): the context refused while it ran, so the refusal is what to
        # say. A crash with no refusal behind it is the handler's own.
        e ->
          case refusal_in(e) || Process.get({Policy, :refusal}) do
            %Refused{} = refused ->
              Process.put({Policy, :refusal}, refused)
              {:noreply, socket}

            nil ->
              reraise e, __STACKTRACE__
          end
      end

    case Policy.take_refusal() do
      nil -> result
      %Refused{message: message} -> say_in(result, socket, message, say, said?)
    end
  end

  defp refusal_in(%{term: {:error, %Refused{} = refused}}), do: refused
  defp refusal_in(%{term: %Refused{} = refused}), do: refused
  defp refusal_in(_), do: nil

  defp say_in({:noreply, after_socket}, before, message, say, said?),
    do: {:noreply, maybe_say(before, after_socket, message, say, said?)}

  defp say_in({:reply, map, after_socket}, before, message, say, said?),
    do: {:reply, map, maybe_say(before, after_socket, message, say, said?)}

  defp say_in(other, _before, _message, _say, _said?), do: other

  defp maybe_say(before, after_socket, message, say, said?) do
    if said?.(before, after_socket), do: after_socket, else: say.(after_socket, message)
  end

  # The handler said something of its own: a new error flash, or a new
  # error in the panel's callout.
  defp said_already?(before, after_socket) do
    flash = &Phoenix.Flash.get(&1.assigns[:flash] || %{}, :error)
    notice = & &1.assigns[:panel_notice]

    (flash.(after_socket) != nil and flash.(after_socket) != flash.(before)) or
      (match?({:error, _}, notice.(after_socket)) and notice.(after_socket) != notice.(before))
  end
end

# A refusal drawn where a door draws its own error's words (a flash, a
# notice) is its message, not a crash in the render (#3174).
defimpl Phoenix.HTML.Safe, for: Slipdock.Policy.Refused do
  def to_iodata(%{message: message}), do: Phoenix.HTML.Engine.html_escape(message)
end
