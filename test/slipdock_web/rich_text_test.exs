defmodule SlipdockWeb.RichTextTest do
  use ExUnit.Case, async: true

  alias SlipdockWeb.RichText

  defp render(text), do: text |> RichText.render() |> Phoenix.HTML.safe_to_string()

  test "escapes HTML and keeps plain text" do
    assert render("a <b>bold</b> & co") == "a &lt;b&gt;bold&lt;/b&gt; &amp; co"
    assert render(nil) == ""
  end

  test "renders attached images inline" do
    html = render("see ![shot.png](/attachments/3/shot.png) here")
    assert html =~ ~s(<img src="/attachments/3/shot.png" alt="shot.png")
    assert html =~ ~s(<a href="/attachments/3/shot.png" target="_blank")
    assert html =~ "see " and html =~ " here"
  end

  test "renders links and bare URLs, but never unsafe schemes" do
    assert render("[docs](https://example.com/x)") =~ ~s(<a href="https://example.com/x")

    assert render("go to https://example.com/a?b=1, then") =~
             ~s|<a href="https://example.com/a?b=1" target="_blank" rel="noopener" class="link link-primary break-all" onclick="event.stopPropagation()">https://example.com/a?b=1</a>, then|

    assert render("[x](javascript:alert(1))") == "[x](javascript:alert(1))"
    assert render("![x](//evil.example/i.png)") == "![x](//evil.example/i.png)"
  end

  test "detects images" do
    assert RichText.has_image?("![a](/attachments/1/a.png)")
    refute RichText.has_image?("plain")
    refute RichText.has_image?(nil)
  end
end
