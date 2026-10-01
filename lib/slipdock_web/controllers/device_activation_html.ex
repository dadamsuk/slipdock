defmodule SlipdockWeb.DeviceActivationHTML do
  @moduledoc "The /activate page: enter a code, then decide about what it asks for."
  use SlipdockWeb, :html

  embed_templates "device_activation_html/*"

  @doc "What a scope lets the agent do, in a sentence rather than a keyword."
  def scope_sentence("read"),
    do: "Read your boards, cards and wiki pages. It cannot change anything."

  def scope_sentence(_), do: "Read and change your boards, cards and wiki pages."
end
