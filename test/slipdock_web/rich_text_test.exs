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

  describe "markdown/2" do
    defp md(text), do: text |> RichText.markdown() |> Phoenix.HTML.safe_to_string()

    test "renders the Markdown people write in a card" do
      html = md("# Plan\n\nsome **bold**, *soft* and `code`\n\n- one\n- two\n\n1. first")

      assert html =~ "<h1>Plan</h1>"
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>soft</em>"
      assert html =~ "<code>code</code>"
      assert html =~ "<ul>\n<li>one</li>\n<li>two</li>\n</ul>"
      assert html =~ "<ol>\n<li>first</li>\n</ol>"
      refute html =~ "**"
      refute html =~ "# Plan"
    end

    test "keeps single newlines as line breaks, and renders quotes, tables, task lists and code blocks" do
      html =
        md(
          "line1\nline2\n\n> said\n\n- [x] done\n- [ ] not\n\n|a|b|\n|-|-|\n|1|2|\n\n```\nx = 1\n```"
        )

      assert html =~ "line1<br>\nline2"
      assert html =~ "<blockquote>\n<p>said</p>"
      assert html =~ ~s(<input type="checkbox" checked="" disabled=""> done)
      assert html =~ "<td>1</td>"
      assert html =~ "<pre><code>x = 1\n</code></pre>"
    end

    test "shows raw HTML as written rather than obeying it" do
      html = md("a <b>hi</b> <script>alert(1)</script>\n\n<div onclick=\"x()\">block</div>")

      assert html =~ "a &lt;b&gt;hi&lt;/b&gt; &lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ ~s|&lt;div onclick="x()"&gt;block&lt;/div&gt;|
      refute html =~ "<script"
      refute html =~ "<b>"
      refute html =~ "<div"
    end

    test "raw HTML inside a link's text stays text too" do
      html = md("[*<img src=x onerror=alert(1)>*](/cards/1)")
      assert html =~ ~s(<a href="/cards/1")
      assert html =~ "<em>&lt;img src=x onerror=alert(1)&gt;</em>"
      refute html =~ "<img"
    end

    test "links safe URLs and bare URLs, and keeps the click from editing the card" do
      html = md("[docs](https://example.com/x) and https://example.com/y.")

      assert html =~
               ~s|<a href="https://example.com/x" target="_blank" class="link link-primary break-all" onclick="event.stopPropagation()" rel="noopener">docs</a>|

      assert html =~ ~s|<a href="https://example.com/y" target="_blank"|
      assert html =~ "</a>.</p>"
    end

    test "never links an unsafe scheme or a protocol-relative URL" do
      html = md("[x](javascript:alert(1)) ![pic](//evil.example/i.png) [y](data:text/html,hi)")

      refute html =~ "javascript:"
      refute html =~ "evil.example"
      refute html =~ "data:"
      refute html =~ "<a"
      refute html =~ "<img"
      assert html =~ "x pic y"
    end

    test "renders same-site images inline, with the alt text escaped" do
      html = md(~s|![a "shot"](/attachments/3/shot.png)|)

      assert html =~
               ~s(<img src="/attachments/3/shot.png" alt="a &quot;shot&quot;" loading="lazy")

      assert html =~ ~s(<a href="/attachments/3/shot.png" target="_blank")
    end

    test "leaves code alone" do
      html = md("`https://example.com` and `**not bold**`\n\n```\n<b>[x](/y)</b>\n```")
      assert html =~ "<code>https://example.com</code>"
      assert html =~ "<code>**not bold**</code>"
      assert html =~ "&lt;b&gt;[x](/y)&lt;/b&gt;"
      refute html =~ "<a"
    end

    test "nil and empty text" do
      assert md(nil) == ""
      assert md("") == ""
    end
  end
end
