defmodule SlipdockWeb.TrustContract do
  @moduledoc """
  The trust contract (#2581, `Slipdock.Machines.TrustContract`) as HTML, the
  one way the Machines page and Help › Agents show it.

  It is rendered here, when this module compiles, rather than through
  `SlipdockWeb.RichText`: the text is wrapped for a terminal, and RichText
  turns every newline into a line break. The text is the project's own, from
  the repository, so nothing in it needs sanitising.
  """
  use Phoenix.Component

  alias Slipdock.Machines.TrustContract

  @html MDEx.to_html!(TrustContract.markdown())

  @doc "The contract, as prose."
  attr :class, :any, default: nil

  def trust_contract(assigns) do
    assigns = assign(assigns, :html, Phoenix.HTML.raw(@html))

    ~H"""
    <div class={["card-prose", @class]} data-role="trust-contract">{@html}</div>
    """
  end
end
