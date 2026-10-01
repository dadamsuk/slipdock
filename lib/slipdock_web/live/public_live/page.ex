defmodule SlipdockWeb.PublicLive.Page do
  @moduledoc """
  A published wiki page: anyone with the link reads it, without an account.

  Two things are deliberately *not* live here. The page's live queries show
  the answers they gave when it was published, and its references — card
  chips, page links, mentions — are plain text. There is nobody behind an
  anonymous request to have permissions, so a live query or a followable link
  would be a way to read private cards from the open web. The prose is
  current; the answers are a snapshot, and publishing again refreshes them.
  """
  use SlipdockWeb, :live_view

  alias Slipdock.Wiki
  alias Slipdock.Wiki.Page
  alias SlipdockWeb.Wiki.Renderer

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Wiki.get_published(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That page is no longer published.")
         |> redirect(to: ~p"/login")}

      %Page{} = page ->
        {:ok,
         assign(socket,
           page: page,
           board: page.board,
           page_title: "#{page.title} · #{page.board.name}",
           html: Renderer.to_html(page.body, page: page, static: true, frozen: page.frozen || %{})
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-base-200">
      <header class="border-b border-base-300 bg-base-100">
        <div class="mx-auto flex max-w-3xl items-center gap-2 px-4 py-3 text-sm sm:px-8">
          <Layouts.brand_mark />
          <span class="font-semibold">{@board.name}</span>
          <span class="text-base-content/40">· wiki</span>
          <span class="ml-auto font-mono text-2xs text-base-content/40">{@page.code}</span>
        </div>
      </header>

      <main class="mx-auto max-w-3xl px-4 py-8 sm:px-8 sm:py-12">
        <h1 class="text-3xl font-bold tracking-tight">{@page.title}</h1>
        <p :if={@page.summary} class="mt-2 text-base-content/60">{@page.summary}</p>
        <div class="wiki-prose mt-8">{Phoenix.HTML.raw(@html)}</div>

        <footer class="mt-12 border-t border-base-300 pt-4 text-xs text-base-content/50">
          Published {stamp(@page.published_at)}; last edited {stamp(@page.updated_at)}.
          <span class="block">
            Anything counted or listed here was counted when the page was published.
          </span>
        </footer>
      </main>
    </div>
    """
  end

  defp stamp(nil), do: "—"
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y")
end
