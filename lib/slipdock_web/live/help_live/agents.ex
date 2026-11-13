defmodule SlipdockWeb.HelpLive.Agents do
  @moduledoc """
  Help › Agents: the ways an AI agent can work with this server. The overview
  introduces and compares them; each has a page of its own. Addresses on them
  are this server's own, worked out from the request as the Set up an agent
  tab does, so what is copied from here works here.

  The module is the code; the words are beside it (#2919). The overview is
  `agents/overview.html.heex`, each way in's page is
  `agents/topics/<slug>.html.heex` (embedded as `<slug>_topic/1`), and the
  data the pages are drawn from, the ways in and the comparison's rows, are
  `agents/topics.exs` and `agents/features.exs`.
  """
  use SlipdockWeb, :html

  import SlipdockWeb.HelpLive.Components
  import SlipdockWeb.TrustContract, only: [trust_contract: 1]

  # The ways in, in the order the page presents them: what needs least first.
  @topics_file Path.join(__DIR__, "agents/topics.exs")
  @external_resource @topics_file
  @topics @topics_file |> Code.eval_file() |> elem(0)

  @slugs Enum.map(@topics, & &1.slug)

  # The comparison: each row is a question, each cell the answer for one way
  # in, in @topics order. {mark, note}: :yes, :some or :no, and the words that
  # make the mark honest.
  @features_file Path.join(__DIR__, "agents/features.exs")
  @external_resource @features_file
  @features @features_file |> Code.eval_file() |> elem(0)

  def topics, do: @topics
  def slugs, do: @slugs
  def features, do: @features

  # ── The overview, and each way in's page ──────────────────────────────────

  # `overview/1`, and a `<slug>_topic/1` for each way in.
  embed_templates "agents/*.html"
  embed_templates "agents/topics/*.html", suffix: "_topic"

  # ── One way in ────────────────────────────────────────────────────────────

  def topic_page(assigns) do
    ~H"""
    <.topic_nav topics={@topics} current={@topic.slug} />

    <article id={"help-topic-#{@topic.slug}"} class="space-y-6">
      <header class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10">
        <.page_header title={@topic.title} subtitle={@topic.intro} class="">
          <:leading><.icon name={@topic.icon} class="size-6 text-primary" /></:leading>
        </.page_header>
        <p class="mt-2 text-sm">
          <span class="font-medium">Use it when</span>
          <span class="text-base-content/70">{lowercase_first(@topic.when)}</span>
        </p>
      </header>
      <.topic slug={@topic.slug} base_url={@base_url} current_user={@current_user} />
    </article>
    """
  end

  attr :topics, :list, required: true
  attr :current, :string, required: true

  # Across the top of a topic's page (and the CLI's reference): back, then each way in.
  def topic_nav(assigns) do
    ~H"""
    <nav
      id="help-topics"
      aria-label="Help topics"
      class="flex gap-1 overflow-x-auto rounded-2xl bg-base-100 p-1 text-sm shadow-sm ring-1 ring-base-content/10"
    >
      <.link
        patch={~p"/help/agents"}
        class="flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
      >
        <.icon name="hero-arrow-left" class="size-4" /> All ways in
      </.link>
      <.link
        patch={~p"/help/agents/flow"}
        id="help-topics-flow"
        aria-current={@current == "flow" && "page"}
        class={[
          "flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium",
          (@current == "flow" && "bg-primary/10 text-primary") ||
            "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
        ]}
      >
        How work flows
      </.link>
      <.link
        :for={t <- @topics}
        patch={~p"/help/agents/#{t.slug}"}
        aria-current={t.slug == @current && "page"}
        class={[
          "flex items-center gap-1.5 whitespace-nowrap rounded-xl px-3 py-2 font-medium",
          (t.slug == @current && "bg-primary/10 text-primary") ||
            "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
        ]}
      >
        {t.short}
      </.link>
    </nav>
    """
  end

  attr :slug, :string, required: true
  attr :base_url, :string, required: true
  attr :current_user, :any, required: true

  # One clause a way in, calling its template.
  for slug <- @slugs do
    defp topic(%{slug: unquote(slug)} = assigns),
      do: unquote(String.to_existing_atom(slug <> "_topic"))(assigns)
  end

  # The handbook's section pages as the help gives them, built from the Tool
  # (#2045): "the specification, architecture, …, principles (…) and the
  # playbook (…)", a note after the pages that need one.
  @handbook_notes %{
    "principles" => {:safe, "the tie-breakers, each a <code>PRIN</code> rule"},
    "playbook" => "how an idea becomes cards on the board"
  }

  defp handbook_pages do
    names =
      for %{key: key, name: name} <- Slipdock.Handbook.sections() do
        case @handbook_notes do
          %{^key => note} -> [name, " (", note, ")"]
          _ -> name
        end
      end

    {names, [last]} = Enum.split(names, -1)
    ["the ", Enum.intersperse(names, ", "), " and the ", last]
  end
end
