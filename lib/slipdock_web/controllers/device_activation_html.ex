defmodule SlipdockWeb.DeviceActivationHTML do
  @moduledoc "The /activate page: enter a code, then decide about what it asks for."
  use SlipdockWeb, :html

  embed_templates "device_activation_html/*"

  @doc "What a scope lets the agent do, in a sentence rather than a keyword."
  def scope_sentence("read"),
    do: "Read your boards, cards and wiki pages. It cannot change anything."

  # Never asked for through the device flow any more, but a page that might
  # one day be shown such a request should say what it is, loudly, rather than
  # fall through to the ordinary sentence.
  def scope_sentence("admin"),
    do:
      "ADMINISTER THIS SERVER: change who can sign in, mail and AI settings, and reach " <>
        "other people's boards. Only approve this if you asked for it yourself."

  def scope_sentence(_), do: "Read and change your boards, cards and wiki pages."
end
