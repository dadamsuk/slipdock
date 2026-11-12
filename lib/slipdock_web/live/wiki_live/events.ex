defmodule SlipdockWeb.WikiLive.Events do
  @moduledoc """
  What `WikiLive.Index`'s event modules share (#2788). `use` it in a module
  of `handle_event/3` clauses, each named by a literal string as a
  LiveView's are, and the module gets `events/0`: the names its clauses
  handle, read off the clauses as they are compiled, so there is no second
  list to keep in step. `WikiLive.Index.handle_event/3` hands each event to
  the module that names it.

  The clauses run in the LiveView's own process, with its socket, exactly as
  they did when they were `WikiLive.Index`'s own.
  """

  defmacro __using__(_opts) do
    quote do
      use SlipdockWeb, :html
      import Phoenix.LiveView

      Module.register_attribute(__MODULE__, :wiki_events, accumulate: true)
      @on_definition SlipdockWeb.WikiLive.Events
      @before_compile SlipdockWeb.WikiLive.Events
    end
  end

  @doc false
  def __on_definition__(env, :def, :handle_event, [event | _], _guards, _body)
      when is_binary(event),
      do: Module.put_attribute(env.module, :wiki_events, event)

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defmacro __before_compile__(_env) do
    quote do
      @wiki_event_names @wiki_events |> Enum.reverse() |> Enum.uniq()

      @doc "The events this module's `handle_event/3` clauses handle."
      def events, do: @wiki_event_names
    end
  end
end
