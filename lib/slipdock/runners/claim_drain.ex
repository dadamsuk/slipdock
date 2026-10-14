defmodule Slipdock.Runners.ClaimDrain do
  @moduledoc """
  Answers the runners' open claims when the app stops, before the endpoint
  drains.

  A runner's claim is a long-poll of up to 50 seconds, so a deploy always
  stops the old app with some still open. The endpoint gives in-flight
  requests 3 seconds and then drops them, and a proxy in front can't replay
  a request it has already sent: each one ended as a 502. This process starts
  after `SlipdockWeb.Endpoint` and so stops before it. On the way down it
  marks the node draining and tells every waiting claim, which answers
  "nothing queued" (see `Slipdock.Runners.claim/2`) while the endpoint is
  still there to send it. Claims that arrive after that answer at once.
  """
  use GenServer

  @key {__MODULE__, :draining}
  @topic "runner_claims:drain"

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @doc "True once this node has begun to stop."
  def draining?, do: :persistent_term.get(@key, false)

  @doc "Subscribes the caller to `:draining`, sent when this node begins to stop."
  def subscribe, do: Phoenix.PubSub.subscribe(Slipdock.PubSub, @topic)

  def unsubscribe, do: Phoenix.PubSub.unsubscribe(Slipdock.PubSub, @topic)

  @doc """
  Marks this node draining and answers every waiting claim. Only this node's:
  the others in a cluster carry on.
  """
  def drain do
    :persistent_term.put(@key, true)
    Phoenix.PubSub.local_broadcast(Slipdock.PubSub, @topic, :draining)
  end

  @doc false
  # For tests: back to taking claims.
  def reset, do: :persistent_term.erase(@key)

  @impl true
  def init(:ok) do
    # Trapped, so the supervisor's shutdown runs `terminate/2`.
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: drain()
end
