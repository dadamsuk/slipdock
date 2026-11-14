defmodule SlipdockWeb.SlipdockComponents.Copy do
  @moduledoc """
  Text to copy, with the button that copies it (#2887): the agent setup, a
  Tool's install steps, the help's snippets, a runner's setup steps and the
  one-time secrets (a new API token, an enrolment key).

  The text is selectable as well, so a copy button that needs JavaScript is
  never the only way out. The button is `CopyText` (`assets/js/app.js`,
  through `copyWithFeedback/2` in `assets/js/copy.js`): it copies the text of
  the element whose id is its `data-target` and says "Copied" for a moment.
  The button's id is the text's with `-copy` after it.
  """
  use Phoenix.Component

  import SlipdockWeb.CoreComponents, only: [callout: 1, icon: 1]

  @doc """
  Text to copy, with a Copy button.

  By default the text is a wrapped `<code>` block with the button under it.
  `pre` makes it a `<pre>` that keeps its lines and scrolls sideways, with
  the button in its top right corner (a runner's setup commands). `class`
  goes on the wrapper (its margin); `label` is the button's word.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, default: "Copy"
  attr :class, :any, default: nil
  attr :pre, :boolean, default: false

  def copy_block(%{pre: true} = assigns) do
    ~H"""
    <div class={["relative", @class]}>
      <pre
        id={@id}
        class="overflow-x-auto whitespace-pre rounded-lg bg-base-300/60 p-3 pr-16 font-mono text-xs"
      >{@text}</pre>
      <button
        type="button"
        id={"#{@id}-copy"}
        phx-hook="CopyText"
        data-target={@id}
        class="btn btn-ghost btn-xs absolute right-1.5 top-1.5"
      >
        <span data-label>{@label}</span>
      </button>
    </div>
    """
  end

  def copy_block(assigns) do
    ~H"""
    <div {wrapper(@class)}>
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
        <.icon name="hero-clipboard" class="size-3.5" /> <span data-label>{@label}</span>
      </button>
    </div>
    """
  end

  # No class, no attribute: a nil class would render `class=""`.
  defp wrapper(nil), do: []
  defp wrapper(class), do: [class: class]

  @doc """
  A secret shown this once: a warning `callout` saying to copy it now, the
  secret as a `copy_block/1`, and a Done button that sends `dismiss` to
  `target`. `what` names it in the heading ("Copy this token now — it won't
  be shown again.").
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :what, :string, required: true
  attr :dismiss, :string, required: true
  attr :target, :any, default: nil

  def secret_once(assigns) do
    ~H"""
    <.callout
      id={"#{@id}-once"}
      kind={:warning}
      title={"Copy this #{@what} now — it won't be shown again."}
      class="mt-4"
      data-secret-once
    >
      <.copy_block id={@id} text={@text} class="mt-2" />
      <button
        type="button"
        class="btn btn-ghost btn-xs mt-2"
        phx-click={@dismiss}
        phx-target={@target}
      >Done</button>
    </.callout>
    """
  end
end
