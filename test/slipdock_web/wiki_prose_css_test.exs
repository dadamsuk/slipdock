defmodule SlipdockWeb.WikiProseCssTest do
  # Long Markdown lines wrap within the viewport (#1169). What a browser makes
  # of these rules is checked in a real one by tools/e2e/wiki-wrap.sh; this
  # keeps the rules themselves from quietly going away.
  use ExUnit.Case, async: true

  @path Path.expand("../../assets/css/app.css", __DIR__)
  @external_resource @path
  @css File.read!(@path)

  defp rule(selector) do
    case Regex.run(~r/^#{Regex.escape(selector)} \{([^}]*)\}/m, @css) do
      [_, body] -> body
      nil -> flunk("no #{selector} rule in app.css")
    end
  end

  test "prose breaks a long URL or identifier anywhere, so table cells can shrink too" do
    body = rule(".wiki-prose")
    assert body =~ "overflow-wrap: anywhere"
    refute body =~ "overflow-wrap: break-word"
  end

  test "a code block wraps its lines rather than scrolling them out of sight" do
    assert rule(".wiki-prose pre") =~ "white-space: pre-wrap"
  end

  test "nothing later in the stylesheet puts a wiki code block back on one line" do
    refute @css =~ ~r/\.wiki-prose pre[^{,]*\{[^}]*white-space:\s*(pre|nowrap)\s*[;}]/
  end
end
