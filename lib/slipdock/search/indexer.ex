defmodule Slipdock.Search.Indexer do
  @moduledoc """
  Keeps the semantic index up to date without anyone waiting for it.

  Every write that changes searchable text — a card saved, a comment added,
  a status update recorded, a wiki page written — calls `enqueue/1` with the
  card id, or `enqueue_page/1` with the page id. That is a
  cast: it returns immediately, so saving a card never depends on OpenRouter
  being up or quick. The queue then settles for a moment before flushing, so
  a burst of edits to one card (the usual shape of typing) costs one
  embedding call rather than ten, and the whole batch goes in as few
  requests as `Slipdock.AI.Embeddings` can manage.

  Nothing here is a source of truth. If the app stops mid-queue, or a call
  to the model fails, the index is merely behind — `mix slipdock.reindex`
  puts it right, and a failed flush is logged and dropped rather than
  retried forever against an outage.

  In the test environment (`interval: :manual`) the queue never flushes on
  its own; tests call `flush/0` to do it synchronously.
  """

  use GenServer

  import Ecto.Query, warn: false

  require Logger

  alias Slipdock.Search

  @default_interval 2_000
  # A ceiling on how many cards one flush loads and embeds at once, so a bulk
  # import turns into a series of ordinary batches rather than one huge one.
  @max_per_flush 40

  ## Client -------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Queues a card for re-embedding. Safe to call from anywhere, including
  inside a transaction: it never blocks and never fails.
  """
  @spec enqueue(integer | Slipdock.Boards.Card.t() | nil) :: :ok
  def enqueue(nil), do: :ok
  def enqueue(%{id: id}), do: enqueue(id)

  def enqueue(card_id) when is_integer(card_id) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:enqueue, {:card, card_id}})
    else
      :ok
    end
  catch
    # The indexer is not essential; never let its absence break a save.
    :exit, _ -> :ok
  end

  @doc "Queues a wiki page for re-embedding. Same contract as `enqueue/1`."
  @spec enqueue_page(integer | Slipdock.Wiki.Page.t() | nil) :: :ok
  def enqueue_page(nil), do: :ok
  def enqueue_page(%{id: id}), do: enqueue_page(id)

  def enqueue_page(page_id) when is_integer(page_id) do
    if enabled?() do
      GenServer.cast(__MODULE__, {:enqueue, {:page, page_id}})
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Queues several cards at once."
  def enqueue_all(card_ids) when is_list(card_ids), do: Enum.each(card_ids, &enqueue/1)

  @doc "Queues several pages at once."
  def enqueue_pages(page_ids) when is_list(page_ids), do: Enum.each(page_ids, &enqueue_page/1)

  @doc "Drops a page from the index (it was deleted, archived or made a draft)."
  @spec forget_page(integer | nil) :: :ok
  def forget_page(nil), do: :ok

  def forget_page(page_id) when is_integer(page_id) do
    Search.forget_page(page_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Drops a card from the index (it was deleted). Done synchronously, because
  it is a local delete with nothing to wait for and leaving a deleted card
  searchable for two seconds is worse than the microsecond it costs.
  """
  @spec forget(integer | nil) :: :ok
  def forget(nil), do: :ok

  def forget(card_id) when is_integer(card_id) do
    Search.forget_card(card_id)
    :ok
  rescue
    # A card deleted along with its board takes its embeddings with it
    # through the foreign key; a missing table in a bare test repo is not
    # worth failing a delete over either.
    _ -> :ok
  end

  @doc "Embeds everything queued right now, and waits. Used by tests and the reindex task."
  @spec flush(timeout) :: {:ok, map} | {:error, term}
  def flush(timeout \\ 120_000), do: GenServer.call(__MODULE__, :flush, timeout)

  @doc "How many cards are waiting to be embedded."
  @spec pending() :: non_neg_integer
  def pending do
    GenServer.call(__MODULE__, :pending)
  catch
    :exit, _ -> 0
  end

  @doc """
  Throws the queue away without embedding any of it.

  The queue is global, and a test's cards vanish when its transaction rolls
  back — so without this, ids from a finished test survive into the next one,
  where `pending/0` counts them and a flush finds nothing behind them. Tests
  call this in setup; nothing else should.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> :ok
  end

  ## Server -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{queue: MapSet.new(), timer: nil}}
  end

  @impl true
  def handle_cast({:enqueue, card_id}, state) do
    {:noreply, %{state | queue: MapSet.put(state.queue, card_id)} |> schedule()}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {result, state} = do_flush(state)
    {:reply, result, state}
  end

  def handle_call(:pending, _from, state), do: {:reply, MapSet.size(state.queue), state}

  def handle_call(:reset, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:reply, :ok, %{state | queue: MapSet.new(), timer: nil}}
  end

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = do_flush(%{state | timer: nil})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Flushing -----------------------------------------------------------------

  defp do_flush(%{queue: queue} = state) do
    if MapSet.size(queue) == 0 do
      {{:ok, %{embedded: 0, unchanged: 0, removed: 0}}, state}
    else
      {batch, rest} = queue |> Enum.to_list() |> Enum.split(@max_per_flush)
      state = %{state | queue: MapSet.new(rest)}

      result = embed(batch)

      # Anything left over goes round again on the next tick.
      {result, if(rest == [], do: state, else: schedule(state))}
    end
  end

  # One queue, two kinds of thing in it: cards and pages embed the same way
  # and are merely loaded and swept differently.
  defp embed(entries) do
    card_ids = for {:card, id} <- entries, do: id
    page_ids = for {:page, id} <- entries, do: id

    with {:ok, cards} <- embed_cards(card_ids),
         {:ok, pages} <- embed_pages(page_ids) do
      counts = Map.merge(cards, pages, fn _k, a, b -> a + b end)

      if counts.embedded > 0 or counts.removed > 0 do
        Logger.info(
          "Search index: #{counts.embedded} embedded, #{counts.unchanged} unchanged, " <>
            "#{counts.removed} removed across #{length(card_ids)} cards and #{length(page_ids)} pages"
        )
      end

      {:ok, counts}
    else
      {:error, reason} = error ->
        Logger.warning("Search index update failed: #{reason}")
        error
    end
  rescue
    exception ->
      Logger.warning("Search index update crashed: #{Exception.message(exception)}")
      {:error, Exception.message(exception)}
  end

  defp embed_cards([]), do: {:ok, %{embedded: 0, unchanged: 0, removed: 0}}

  defp embed_cards(card_ids) do
    cards = Search.load_cards(card_ids)
    # Cards that have gone since they were queued take their chunks with them.
    Enum.each(card_ids -- Enum.map(cards, & &1.id), &Search.forget_card/1)
    Search.index_cards(cards)
  end

  defp embed_pages([]), do: {:ok, %{embedded: 0, unchanged: 0, removed: 0}}

  defp embed_pages(page_ids) do
    pages = Search.load_pages(page_ids)
    Enum.each(page_ids -- Enum.map(pages, & &1.id), &Search.forget_page/1)
    Search.index_pages(pages)
  end

  defp schedule(%{timer: nil} = state) do
    case interval() do
      :manual -> state
      ms -> %{state | timer: Process.send_after(self(), :flush, ms)}
    end
  end

  defp schedule(state), do: state

  defp enabled?, do: Process.whereis(__MODULE__) != nil

  defp interval do
    Application.get_env(:slipdock, :search, [])
    |> Keyword.get(:interval, @default_interval)
  end
end
