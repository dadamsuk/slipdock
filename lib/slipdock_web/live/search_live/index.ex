defmodule SlipdockWeb.SearchLive.Index do
  @moduledoc """
  One box over everything you can see, in two modes.

  **Search** matches by meaning (`Slipdock.Search`) and hands back the cards, so
  you choose. **Ask** hands the same search to a model as a tool
  (`Slipdock.AI.Researcher`) and hands back an answer, so it chooses. Same
  query, same index, same permissions — the difference is only who does the
  reading, which is why they are one page with a toggle rather than two
  pages that looked alike and behaved differently.

  The mode is the route (`/search` and `/ask`), not a socket assign, so a
  mode is linkable, the browser's back button works through it and the two
  header icons both land somewhere real. Toggling carries the query across
  but keeps each mode's own state: your results are still there when you
  come back from asking, and the conversation survives a look at the list.

  Both run on `start_async` — an embedding call is a few hundred
  milliseconds and a model call several seconds — and both discard a reply
  whose mode or query is no longer the one on screen.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.AI.Researcher
  alias Slipdock.SavedQueries
  alias Slipdock.Search
  alias Slipdock.Search.Embedding
  alias SlipdockWeb.Markdown

  # What each mode offers before you have typed anything, until the person
  # has saved something of their own — see `Slipdock.SavedQueries`. Both are
  # rendered the same way, clickable, because an example you can only read
  # is a worse example than one that shows you the answer.
  @suggestions [
    "What's at risk across all my boards right now?",
    "What did we decide about pricing?",
    "Which cards have been sitting untouched the longest?",
    "Summarise everything blocked and who it's waiting on."
  ]

  @examples [
    "the card that was blocked on legal",
    "anything about flaky tests",
    "what did we say about the pricing change"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       query: "",
       busy: false,
       error: nil,
       # Search's own state.
       results: [],
       searched: nil,
       archived: false,
       board_id: nil,
       # Ask's own state.
       messages: [],
       form_key: 0,
       boards: Slipdock.Access.list_boards(socket.assigns.current_user, archived: :all),
       embeddings?: Slipdock.AI.Embeddings.configured?(),
       model?: Slipdock.AI.configured?(socket.assigns.current_user),
       # An index nobody has built answers every query with nothing, which
       # reads as "there is nothing there" when it means "nobody has built
       # it yet". Worth telling the difference.
       indexed?: Search.available?()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    mode = mode(socket.assigns.live_action)

    socket =
      socket
      |> assign(mode: mode, page_title: if(mode == :ask, do: "Ask", else: "Search"))
      |> load_saved()
      |> scope_to_board(params["board"])

    case String.trim(params["q"] || "") do
      "" -> {:noreply, socket}
      q -> {:noreply, socket |> assign(query: q) |> run_if_new(q)}
    end
  end

  # A search arriving from somewhere that is already about one board — the
  # wiki's own search box, say — keeps that scope. The reader's own list of
  # boards is the permission check: a board that is not in it is not a board
  # they can narrow to.
  defp scope_to_board(socket, nil), do: socket
  defp scope_to_board(socket, ""), do: assign(socket, board_id: nil)

  defp scope_to_board(socket, ref) do
    with {id, ""} <- Integer.parse(to_string(ref)),
         true <- Enum.any?(socket.assigns.boards, &(&1.id == id)) do
      assign(socket, board_id: id)
    else
      _ -> socket
    end
  end

  # The saved list, and what to offer when nothing is saved. Reloaded whenever
  # it could have changed: the mode, or a save.
  defp load_saved(socket) do
    %{current_user: user, mode: mode} = socket.assigns
    fallback = if mode == :ask, do: @suggestions, else: @examples

    assign(socket, offer: SavedQueries.examples_for(user, mode, fallback))
  end

  defp mode(:ask), do: :ask
  defp mode(_), do: :search

  # Arriving with a query in the URL runs it — from the toggle, a shared link
  # or the board page. In Ask that is a model call, so it happens only into an
  # empty conversation: coming back to a thread you already have re-reads it,
  # it doesn't ask it again.
  defp run_if_new(%{assigns: %{mode: :ask, messages: []}} = socket, q), do: ask(socket, q)
  defp run_if_new(%{assigns: %{mode: :ask}} = socket, _q), do: socket
  defp run_if_new(%{assigns: %{searched: q}} = socket, q), do: socket
  defp run_if_new(socket, q), do: search(socket, q)

  ## Events -------------------------------------------------------------------

  # The box, typed in. Search runs as you type (an embedding call, cheap and
  # quick); Ask waits for Enter, because a model call should be asked for.
  @impl true
  def handle_event("typed", %{"q" => q}, socket) do
    q = String.trim(q)
    socket = assign(socket, query: q)

    cond do
      socket.assigns.mode == :ask -> {:noreply, socket}
      q == "" -> {:noreply, assign(socket, results: [], searched: nil, error: nil)}
      q == socket.assigns.searched -> {:noreply, socket}
      true -> {:noreply, search(socket, q)}
    end
  end

  def handle_event("submit", %{"q" => q}, socket) do
    q = String.trim(q)

    cond do
      q == "" or socket.assigns.busy -> {:noreply, assign(socket, query: q)}
      socket.assigns.mode == :ask -> {:noreply, socket |> assign(query: q) |> ask(q)}
      q == socket.assigns.searched -> {:noreply, assign(socket, query: q)}
      true -> {:noreply, socket |> assign(query: q) |> search(q)}
    end
  end

  def handle_event("suggest", %{"text" => text}, socket) do
    cond do
      socket.assigns.busy -> {:noreply, socket}
      socket.assigns.mode == :ask -> {:noreply, socket |> assign(query: text) |> ask(text)}
      true -> {:noreply, socket |> assign(query: text) |> search(text)}
    end
  end

  # The star: on the box it saves what is in it, on a question in the thread
  # it saves that one. Ask clears its box on submit, so the thread is the only
  # place left to press it — and the honest place, since whether a question is
  # worth keeping is something you know once you have seen the answer.
  def handle_event("toggle_saved", params, socket) do
    %{current_user: user, mode: mode, query: query} = socket.assigns
    text = String.trim(params["text"] || query)

    if text == "" do
      {:noreply, socket}
    else
      SavedQueries.toggle(user, mode, text)
      {:noreply, load_saved(socket)}
    end
  end

  def handle_event("unsave", %{"id" => id}, socket) do
    if id = SlipdockWeb.Params.id(id), do: SavedQueries.delete(socket.assigns.current_user, id)
    {:noreply, load_saved(socket)}
  end

  def handle_event("clear", _, socket) do
    {:noreply,
     assign(socket,
       query: "",
       results: [],
       searched: nil,
       error: nil,
       form_key: socket.assigns.form_key + 1
     )}
  end

  def handle_event("reset", _, socket) do
    {:noreply,
     assign(socket,
       messages: [],
       query: "",
       error: nil,
       busy: false,
       form_key: socket.assigns.form_key + 1
     )}
  end

  def handle_event("toggle_archived", _, socket) do
    socket = assign(socket, archived: not socket.assigns.archived)
    {:noreply, rerun(socket)}
  end

  def handle_event("set_board", %{"board" => ""}, socket),
    do: {:noreply, socket |> assign(board_id: nil) |> rerun()}

  def handle_event("set_board", %{"board" => id}, socket),
    do: {:noreply, socket |> assign(board_id: SlipdockWeb.Params.id(id)) |> rerun()}

  ## Running ------------------------------------------------------------------

  defp rerun(%{assigns: %{searched: nil}} = socket), do: socket
  defp rerun(socket), do: search(socket, socket.assigns.query)

  defp search(socket, query) do
    %{current_user: user, archived: archived, board_id: board_id} = socket.assigns

    socket
    |> assign(busy: true, error: nil)
    |> start_async(:search, fn ->
      {query, Search.search(user, query, archived: archived, board_id: board_id, limit: 30)}
    end)
  end

  defp ask(socket, text) do
    user = socket.assigns.current_user
    history = Enum.map(socket.assigns.messages, &%{role: &1.role, content: &1.content})
    question = %{id: next_id(), role: "user", content: text, sources: [], searches: []}

    socket
    |> assign(
      messages: socket.assigns.messages ++ [question],
      query: "",
      busy: true,
      error: nil,
      form_key: socket.assigns.form_key + 1
    )
    |> start_async(:ask, fn -> Researcher.ask(user, history, text) end)
  end

  @impl true
  def handle_async(:search, {:ok, {query, {:ok, results}}}, socket) do
    # A slower earlier query must not overwrite the answer to a later one,
    # and neither must a query whose mode you have since left.
    if socket.assigns.mode == :search and query == socket.assigns.query do
      {:noreply, assign(socket, results: results, searched: query, busy: false, error: nil)}
    else
      {:noreply, assign(socket, busy: false)}
    end
  end

  def handle_async(:search, {:ok, {_query, {:error, message}}}, socket),
    do: {:noreply, assign(socket, busy: false, error: message, results: [])}

  def handle_async(:search, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: false, error: "The search crashed: #{inspect(reason)}")}

  def handle_async(:ask, {:ok, {:ok, answer}}, socket) do
    message = %{
      id: next_id(),
      role: "assistant",
      content: answer.reply,
      sources: answer.sources,
      searches: answer.searches
    }

    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message], busy: false)}
  end

  def handle_async(:ask, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, busy: false, error: message)}

  def handle_async(:ask, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, busy: false, error: "The assistant crashed: #{inspect(reason)}")}

  defp next_id, do: System.unique_integer([:positive, :monotonic])

  ## Presentation -------------------------------------------------------------

  # The toggle carries whatever is in the box across, so "I searched, now ask
  # the same thing" is one click rather than retyping.
  defp mode_path(:search, ""), do: ~p"/search"
  defp mode_path(:search, q), do: ~p"/search?#{[q: q]}"
  defp mode_path(:ask, ""), do: ~p"/ask"
  defp mode_path(:ask, q), do: ~p"/ask?#{[q: q]}"

  defp configured?(%{mode: :ask} = assigns), do: assigns.model? and assigns.embeddings?
  defp configured?(assigns), do: assigns.embeddings?

  # `offer` already holds everything saved in this mode, so the star's state
  # is a list lookup rather than a query on every keystroke.
  defp saved?({:saved, queries}, query), do: Enum.any?(queries, &(&1.text == query))
  defp saved?(_, _), do: false

  # A score is a cosine similarity with a keyword bonus on top, which means
  # nothing to anyone. Three bands say the only thing a reader wants from it.
  defp strength(score) when score >= 0.55, do: {"Strong", "text-success"}
  defp strength(score) when score >= 0.38, do: {"Good", "text-primary"}
  defp strength(_), do: {"Loose", "text-base-content/50"}

  defp kind_icon("card"), do: "hero-rectangle-stack"
  defp kind_icon("comment"), do: "hero-chat-bubble-left"
  defp kind_icon("status_update"), do: "hero-signal"
  defp kind_icon(_), do: "hero-document-text"

  @snippet 260

  # The card chunk repeats its board, list and facets as its first lines,
  # which is the right thing to embed and pure noise to read back under a
  # result that already says all three. Comments and updates get the same
  # treatment: their first line is the "Comment on card X" preamble.
  defp snippet(%{kind: "card", body: body}) do
    body
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "Board: ") or String.starts_with?(&1, "Card: ")))
    |> Enum.join(" ")
    |> tidy()
  end

  # A page chunk's first two lines are where it lives and what it is called,
  # which the result above already says.
  defp snippet(%{kind: kind, body: body}) when kind in ["page", "page_section"] do
    body
    |> String.split("\n")
    |> Enum.reject(
      &(String.starts_with?(&1, "Board: ") or String.starts_with?(&1, "Page: ") or
          String.starts_with?(&1, "Wiki page "))
    )
    |> Enum.join(" ")
    |> tidy()
  end

  defp snippet(%{body: body}) do
    body
    |> String.split("\n", parts: 2)
    |> List.last()
    |> tidy()
  end

  defp tidy(text) do
    trimmed = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(trimmed) > @snippet,
      do: String.slice(trimmed, 0, @snippet) <> "…",
      else: trimmed
  end

  defp card_path(card), do: ~p"/boards/#{card.board_id}/cards/#{card.id}"

  # The assistant reads cards and wiki pages, so a source is either.
  defp source_path(%{page: page}), do: ~p"/boards/#{page.board_id}/wiki/#{page.slug}"
  defp source_path(%{card: card}), do: card_path(card)

  defp source_title(%{page: page}), do: page.title
  defp source_title(%{card: card}), do: card.title

  defp source_board(%{page: page}), do: page.board && page.board.name
  defp source_board(%{card: card}), do: board_name(card)

  # A result is a card or a wiki page; both know where they live.
  defp result_path(%{kind: "page", page: page}),
    do: ~p"/boards/#{page.board_id}/wiki/#{page.slug}"

  defp result_path(%{card: card}), do: card_path(card)

  # "Deploy/Rollback#2" is the second part of a long section; the heading is
  # what a person recognises and what the anchor is built from.
  defp section_title(section) do
    section
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("/")
    |> List.last()
  end

  defp board_name(%{board: %{name: name}}), do: name
  defp board_name(_), do: nil

  ## Render -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        configured: configured?(assigns),
        saved: saved?(assigns.offer, assigns.query)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      alerts={@alerts}
      alerts_open={@alerts_open}
      quick_add={@quick_add}
      shortcuts={@shortcuts}
      viewport={@viewport}
      nav_active={@mode}
    >
      <div class="kanban-scroll h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-6 sm:px-6 sm:py-10">
          <div class="mb-4">
            <div
              class="inline-flex rounded-xl bg-base-200 p-0.5 text-sm"
              role="tablist"
              aria-label="How to look"
            >
              <.link
                :for={
                  {key, label, icon} <- [
                    {:search, "Search", "hero-magnifying-glass"},
                    {:ask, "Ask", "hero-sparkles"}
                  ]
                }
                patch={mode_path(key, @query)}
                role="tab"
                aria-selected={to_string(@mode == key)}
                class={[
                  "flex items-center gap-1.5 rounded-lg px-3.5 py-1.5 font-medium transition",
                  if(@mode == key,
                    do: "bg-base-100 shadow-sm",
                    else: "text-base-content/60 hover:text-base-content"
                  )
                ]}
              >
                <.icon name={icon} class="size-4" /> {label}
              </.link>
            </div>
            <p class="mt-2 text-xs text-base-content/50">
              Search finds cards; Ask gives answers to questions.
            </p>
          </div>

          <form
            id="deep-search"
            phx-change="typed"
            phx-submit="submit"
            class="relative"
          >
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-base-content/40"
            />
            <input
              id={"deep-search-input-#{@form_key}"}
              type="text"
              name="q"
              value={@query}
              autocomplete="off"
              autofocus
              phx-debounce="600"
              disabled={not @configured or (@mode == :ask and @busy)}
              placeholder={
                if @mode == :ask,
                  do: "Ask a question about anything on your boards…",
                  else: "What was that thing we decided about refunds?"
              }
              class="input input-lg w-full rounded-2xl bg-base-100 pl-12 pr-11 text-base shadow-sm ring-1 ring-base-content/10 focus:outline-none focus:ring-2 focus:ring-primary/40"
            />
            <div
              :if={@query != ""}
              class="absolute right-2.5 top-1/2 flex -translate-y-1/2 items-center"
            >
              <button
                type="button"
                phx-click="toggle_saved"
                class={[
                  "rounded-full p-1 transition",
                  if(@saved,
                    do: "text-warning hover:bg-base-200",
                    else: "text-base-content/40 hover:bg-base-200 hover:text-base-content"
                  )
                ]}
                aria-pressed={to_string(@saved)}
                aria-label={
                  if @saved,
                    do: "Saved — click to unsave",
                    else: "Save this #{if @mode == :ask, do: "question", else: "search"}"
                }
                title={
                  if @saved,
                    do: "Saved",
                    else: "Save this #{if @mode == :ask, do: "question", else: "search"}"
                }
              >
                <.icon name={if @saved, do: "hero-star-solid", else: "hero-star"} class="size-4" />
              </button>
              <button
                type="button"
                phx-click="clear"
                class="rounded-full p-1 text-base-content/40 hover:bg-base-200 hover:text-base-content"
                aria-label="Clear"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </form>

          <%!-- Search's filters; Ask narrows by being asked to, in words. --%>
          <div :if={@mode == :search} class="mt-3 flex flex-wrap items-center gap-2 text-xs">
            <select
              name="board"
              phx-change="set_board"
              class="select select-sm rounded-lg bg-base-100 ring-1 ring-base-content/10"
            >
              <option value="" selected={is_nil(@board_id)}>All boards</option>
              <option :for={b <- @boards} value={b.id} selected={@board_id == b.id}>{b.name}</option>
            </select>
            <button
              type="button"
              phx-click="toggle_archived"
              class={[
                "rounded-lg px-2.5 py-1.5 font-medium ring-1 transition",
                if(@archived,
                  do: "bg-primary/10 text-primary ring-primary/30",
                  else: "bg-base-100 text-base-content/60 ring-base-content/10 hover:bg-base-200"
                )
              ]}
            >
              <.icon name="hero-archive-box" class="mr-1 size-3.5" /> Include archived
            </button>
            <span :if={@busy} class="flex items-center gap-1.5 text-base-content/50">
              <span class="loading loading-spinner loading-xs"></span> Searching…
            </span>
            <span :if={not @busy and not is_nil(@searched)} class="text-base-content/50">
              {length(@results)} {if length(@results) == 1, do: "card", else: "cards"}
            </span>
          </div>

          <div :if={@mode == :ask and @messages != []} class="mt-3 flex justify-end">
            <button type="button" phx-click="reset" class="btn btn-ghost btn-xs gap-1">
              <.icon name="hero-trash" class="size-3.5" /> Start again
            </button>
          </div>

          <.notices
            configured={@configured}
            indexed={@indexed?}
            mode={@mode}
            model={@model?}
            embeddings={@embeddings?}
          />

          <p
            :if={@error}
            class="mt-6 flex items-start gap-2 rounded-xl bg-error/10 px-4 py-3 text-sm text-error"
          >
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />{@error}
          </p>

          <.search_results
            :if={@mode == :search}
            results={@results}
            searched={@searched}
            busy={@busy}
            error={@error}
            configured={@configured}
            archived={@archived}
            offer={@offer}
            mode={@mode}
          />

          <.conversation
            :if={@mode == :ask}
            messages={@messages}
            busy={@busy}
            configured={@configured}
            offer={@offer}
            mode={@mode}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Pieces -------------------------------------------------------------------

  attr :configured, :boolean, required: true
  attr :indexed, :boolean, required: true
  attr :mode, :atom, required: true
  attr :model, :boolean, required: true
  attr :embeddings, :boolean, required: true

  defp notices(assigns) do
    ~H"""
    <p
      :if={not @configured}
      class="mt-6 flex items-start gap-2 rounded-xl bg-warning/10 px-4 py-3 text-sm text-warning"
    >
      <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
      <span :if={not @embeddings}>
        This needs an embedding model. Set <code class="font-mono">OPENROUTER_API_KEY</code>
        and run <code class="font-mono">mix slipdock.reindex</code>.
      </span>
      <span :if={@embeddings and not @model}>
        Ask needs a language model. Set <code class="font-mono">OPENROUTER_API_KEY</code>.
      </span>
    </p>

    <p
      :if={@configured and not @indexed}
      class="mt-6 flex items-start gap-2 rounded-xl bg-warning/10 px-4 py-3 text-sm text-warning"
    >
      <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
      Nothing is indexed yet, so {if @mode == :ask,
        do: "the assistant has nothing to search",
        else: "every search comes back empty"}. Run
      <code class="font-mono">mix slipdock.reindex</code>
      on the server to build it.
    </p>
    """
  end

  attr :offer, :any, required: true, doc: "{:saved, queries} or {:examples, texts}"
  attr :mode, :atom, required: true

  # What the page offers before you have typed: your own saved queries, or the
  # built-in examples until you have saved one. Never both — a list of
  # somebody's real questions mixed with our guesses is a worse list than
  # either on its own.
  defp offer_list(assigns) do
    ~H"""
    <p
      :if={match?({:saved, _}, @offer)}
      class="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-base-content/45"
    >
      <.icon name="hero-star-solid" class="size-3.5 text-warning" />
      Saved {if @mode == :ask, do: "questions", else: "searches"}
    </p>

    <ul class="space-y-2">
      <li :for={item <- items(@offer)} class="relative">
        <button
          type="button"
          phx-click="suggest"
          phx-value-text={text_of(item)}
          class={[
            "w-full rounded-xl bg-base-100 px-4 py-3 text-left text-sm shadow-sm ring-1 ring-base-content/10 transition hover:bg-base-200/60",
            saved_item?(item) && "pr-11"
          ]}
        >
          {text_of(item)}
        </button>
        <button
          :if={saved_item?(item)}
          type="button"
          phx-click="unsave"
          phx-value-id={item.id}
          class="absolute right-2 top-1/2 -translate-y-1/2 rounded-full p-1.5 text-base-content/30 transition hover:bg-base-200 hover:text-base-content"
          aria-label={"Remove “#{item.text}” from saved"}
          title="Remove from saved"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </li>
    </ul>
    """
  end

  defp items({:saved, queries}), do: queries
  defp items({:examples, texts}), do: texts

  defp saved_item?(%Slipdock.SavedQueries.SavedQuery{}), do: true
  defp saved_item?(_), do: false

  defp text_of(%Slipdock.SavedQueries.SavedQuery{text: text}), do: text
  defp text_of(text), do: text

  attr :results, :list, required: true
  attr :searched, :any, required: true
  attr :busy, :boolean, required: true
  attr :error, :any, required: true
  attr :configured, :boolean, required: true
  attr :archived, :boolean, required: true
  attr :offer, :any, required: true
  attr :mode, :atom, required: true

  defp search_results(assigns) do
    ~H"""
    <div :if={@configured and is_nil(@searched) and not @busy} class="mt-6">
      <.offer_list offer={@offer} mode={@mode} />
      <p class="mt-5 text-xs leading-relaxed text-base-content/50">
        Describe what you're after rather than guessing at its title. Comments and status updates
        are searched too, so the answer is often on a card whose name says nothing about it.
      </p>
    </div>

    <p
      :if={not is_nil(@searched) and @results == [] and not @busy and is_nil(@error)}
      class="mt-6 rounded-xl bg-base-100 px-4 py-3 text-sm text-base-content/60 shadow-sm ring-1 ring-base-content/10"
    >
      Nothing close enough. Try describing it differently{if not @archived,
        do: ", or include archived cards",
        else: ""}.
    </p>

    <%!-- A card and a wiki page are ranked against each other and shown in
          one list: "what did we decide about refunds" should find the
          decision record and the card that argued about it together. --%>
    <ol :if={@results != []} class="mt-6 space-y-3">
      <li
        :for={result <- @results}
        id={"result-#{result.kind}-#{result.subject.id}"}
        class="overflow-hidden rounded-2xl bg-base-100 shadow-sm ring-1 ring-base-content/10"
      >
        <.link navigate={result_path(result)} class="block px-4 py-3 hover:bg-base-200/40">
          <div class="flex items-start gap-3">
            <.icon
              name={if result.kind == "page", do: "hero-document-text", else: "hero-rectangle-stack"}
              class="mt-1 size-4 shrink-0 text-base-content/35"
            />
            <div class="min-w-0 flex-1">
              <p class="truncate font-semibold">
                <span :if={result.card && result.card.completed} class="mr-1 text-success">✓</span>
                {result.subject.title}
              </p>
              <p class="mt-0.5 truncate text-xs text-base-content/50">
                {result.subject.board.name}
                <span :if={result.kind == "page"}>› wiki</span>
                <span :if={result.card && result.card.column}>› {result.card.column.name}</span>
                <span :if={result.card && result.card.archived_at} class="text-warning">
                  · archived
                </span>
                <span :if={result.card && result.card.due_date}>· due {result.card.due_date}</span>
                <span :if={result.page && result.page.summary}>· {result.page.summary}</span>
              </p>
            </div>
            <span class={["shrink-0 text-xs font-medium", elem(strength(result.score), 1)]}>
              {elem(strength(result.score), 0)}
            </span>
          </div>
        </.link>
        <ul class="divide-y divide-base-300/50 border-t border-base-300/50 bg-base-200/25">
          <li
            :for={match <- Enum.take(result.matches, 3)}
            class="flex items-start gap-2 px-4 py-2 text-xs leading-relaxed"
          >
            <.icon name={kind_icon(match.kind)} class="mt-0.5 size-3.5 shrink-0 text-base-content/35" />
            <span class="min-w-0 flex-1">
              <.link
                :if={match.section != ""}
                navigate={"#{result_path(result)}##{SlipdockWeb.Wiki.Renderer.anchor(section_title(match.section))}"}
                class="font-medium text-base-content/60 hover:underline"
              >
                {section_title(match.section)}
              </.link>
              <span :if={match.section == ""} class="font-medium text-base-content/60">
                {Embedding.label(match.kind)}
              </span>
              <span class="text-base-content/70">— {snippet(match)}</span>
            </span>
          </li>
          <li :if={length(result.matches) > 3} class="px-4 py-1.5 text-xs text-base-content/40">
            and {length(result.matches) - 3} more
          </li>
        </ul>
      </li>
    </ol>
    """
  end

  attr :messages, :list, required: true
  attr :busy, :boolean, required: true
  attr :configured, :boolean, required: true
  attr :offer, :any, required: true
  attr :mode, :atom, required: true

  defp conversation(assigns) do
    ~H"""
    <div :if={@messages == [] and not @busy} class="mt-6">
      <.offer_list :if={@configured} offer={@offer} mode={@mode} />
      <p class="mt-5 text-xs leading-relaxed text-base-content/50">
        It can read, not write. To change something, open the board and use the assistant there
        in Edit mode.
      </p>
    </div>

    <div class="mt-6 space-y-5 text-sm">
      <div
        :for={m <- @messages}
        id={"ask-m#{m.id}"}
        class={["flex", if(m.role == "user", do: "justify-end", else: "justify-start")]}
      >
        <div :if={m.role == "user"} class="flex max-w-[90%] items-center gap-1.5">
          <button
            type="button"
            phx-click="toggle_saved"
            phx-value-text={m.content}
            class={[
              "shrink-0 rounded-full p-1.5 transition",
              if(saved?(@offer, m.content),
                do: "text-warning hover:bg-base-200",
                else: "text-base-content/30 hover:bg-base-200 hover:text-base-content"
              )
            ]}
            aria-pressed={to_string(saved?(@offer, m.content))}
            aria-label={
              if saved?(@offer, m.content),
                do: "Saved — click to unsave",
                else: "Save this question"
            }
            title={if saved?(@offer, m.content), do: "Saved", else: "Save this question"}
          >
            <.icon
              name={if saved?(@offer, m.content), do: "hero-star-solid", else: "hero-star"}
              class="size-4"
            />
          </button>
          <div class="whitespace-pre-wrap break-words rounded-2xl rounded-br-md bg-primary px-4 py-2.5 text-primary-content">
            {m.content}
          </div>
        </div>
        <div :if={m.role == "assistant"} class="w-full max-w-[95%] space-y-2.5">
          <p
            :if={m.searches != []}
            class="flex flex-wrap items-center gap-1.5 px-1 text-xs text-base-content/45"
          >
            <.icon name="hero-magnifying-glass" class="size-3.5" />
            <span>Searched</span>
            <span
              :for={q <- m.searches}
              class="rounded-md bg-base-200 px-1.5 py-0.5 font-medium text-base-content/60"
            >
              “{q}”
            </span>
          </p>
          <div
            class="ai-prose rounded-2xl rounded-bl-md bg-base-200 px-4 py-3 leading-relaxed"
            phx-no-format
          >{Markdown.render(m.content)}</div>
          <details
            :if={m.sources != []}
            class="overflow-hidden rounded-xl bg-base-100 ring-1 ring-base-content/10"
          >
            <summary class="cursor-pointer select-none px-3.5 py-2 text-xs font-medium text-base-content/60 hover:bg-base-200/50">
              {length(m.sources)} {if length(m.sources) == 1, do: "thing", else: "things"} it looked at
            </summary>
            <ul class="divide-y divide-base-300/50 border-t border-base-300/50">
              <li :for={source <- m.sources}>
                <.link
                  navigate={source_path(source)}
                  class="flex items-center gap-2 px-3.5 py-2 text-xs hover:bg-base-200/40"
                >
                  <.icon
                    name={
                      if Map.has_key?(source, :page),
                        do: "hero-document-text",
                        else: "hero-rectangle-stack"
                    }
                    class="size-3.5 shrink-0 text-base-content/35"
                  />
                  <span class="min-w-0 flex-1 truncate">{source_title(source)}</span>
                  <span class="shrink-0 text-base-content/40">{source_board(source)}</span>
                </.link>
              </li>
            </ul>
          </details>
        </div>
      </div>

      <div :if={@busy} class="flex justify-start">
        <div
          class="ai-thinking flex items-center gap-1.5 rounded-2xl rounded-bl-md bg-base-200 px-4 py-3"
          aria-label="Searching and thinking"
        >
          <span></span><span></span><span></span>
        </div>
      </div>
    </div>
    """
  end
end
