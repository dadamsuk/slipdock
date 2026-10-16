defmodule SlipdockWeb.HelpLive.Components do
  @moduledoc "The pieces every Help page is built from."
  use SlipdockWeb, :html

  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def part(assigns) do
    ~H"""
    <section
      id={@id}
      class="rounded-2xl bg-base-100 p-6 shadow-sm ring-1 ring-base-content/10"
    >
      <h2 class="text-lg font-semibold">{@title}</h2>
      <div class="help-prose mt-2 space-y-3 text-sm text-base-content/70">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  # Something to copy. Selectable as well, so the button isn't the only way.
  def snippet(assigns) do
    ~H"""
    <div>
      <code
        id={@id}
        class="block select-all whitespace-pre-wrap break-words rounded-xl bg-base-200 px-3 py-2 font-mono text-xs leading-relaxed text-base-content"
        phx-no-format
      >{@text}</code>
      <button
        type="button"
        id={"#{@id}-copy"}
        class="btn btn-ghost btn-xs mt-1 gap-1"
        phx-hook="CopyText"
        data-target={@id}
      >
        <.icon name="hero-clipboard" class="size-3.5" /> <span data-label>Copy</span>
      </button>
    </div>
    """
  end

  attr :current_user, :any, required: true
  attr :to, :string, required: true
  slot :inner_block, required: true

  # A link into the app for people who are signed in; the same words, plain,
  # for people who aren't, who'd only be bounced to sign in.
  def app_link(assigns) do
    ~H"""
    <.link :if={@current_user} navigate={@to} class="link">{render_slot(@inner_block)}</.link><span
      :if={!@current_user}
      class="font-medium text-base-content"
    >{render_slot(@inner_block)}</span>
    """
  end

  attr :mark, :atom, required: true
  attr :note, :string, required: true

  def mark(%{mark: :text} = assigns) do
    ~H"""
    <span class="text-xs">{@note}</span>
    """
  end

  def mark(assigns) do
    ~H"""
    <span class="flex items-start gap-1" data-mark={@mark}>
      <.icon name={mark_icon(@mark)} class={["mt-0.5 size-4 shrink-0", mark_colour(@mark)]} />
      <span class="sr-only">{mark_word(@mark)}</span>
      <span :if={@note != ""} class="text-xs text-base-content/60">{@note}</span>
    </span>
    """
  end

  defp mark_icon(:yes), do: "hero-check-circle"
  defp mark_icon(:some), do: "hero-minus-circle"
  defp mark_icon(:no), do: "hero-x-circle"
  defp mark_colour(:yes), do: "text-success"
  defp mark_colour(:some), do: "text-warning"
  defp mark_colour(:no), do: "text-base-content/30"
  defp mark_word(:yes), do: "Yes"
  defp mark_word(:some), do: "Partly"
  defp mark_word(:no), do: "No"

  def lowercase_first(<<first::utf8, rest::binary>>),
    do: String.downcase(<<first::utf8>>) <> rest
end
