defmodule Slipdock.Inbound.HtmlToMarkdownTest do
  use ExUnit.Case, async: true

  alias Slipdock.Inbound.HtmlToMarkdown

  defp md(html, opts \\ []), do: HtmlToMarkdown.convert(html, opts)

  test "headings, paragraphs and emphasis" do
    assert md(
             "<h1>Title</h1><p>Some <b>bold</b>, <em>italic</em> and <s>gone</s>.</p><h3>Sub</h3>"
           ) ==
             "# Title\n\nSome **bold**, *italic* and ~~gone~~.\n\n### Sub"
  end

  test "Gmail's one div per line, and <br>, are line breaks" do
    assert md(~s(<div dir="ltr"><div>Line one</div><div>Line two<br>Line three</div></div>)) ==
             "Line one\nLine two\nLine three"
  end

  test "whitespace is collapsed as a browser would" do
    assert md("<p>  lots   of\n\n   space  </p>") == "lots of space"
  end

  test "entities are decoded, Markdown characters escaped" do
    assert md("<p>Fish &amp; chips for 2*3 [people] with snake_case</p>") ==
             "Fish & chips for 2\\*3 \\[people\\] with snake\\_case"
  end

  describe "links" do
    test "http, https and mailto become links" do
      assert md(~s(<a href="https://example.com/a b">the site</a>)) ==
               "[the site](https://example.com/a%20b)"

      assert md(~s(<a href="mailto:a@example.com">a@example.com</a>)) == "<mailto:a@example.com>"

      assert md(~s(<a href="https://example.com">https://example.com</a>)) ==
               "<https://example.com>"
    end

    test "other schemes keep their text and lose the link" do
      assert md(~s|<a href="javascript:alert(1)">click</a>|) == "click"
    end

    test "a link with no text is dropped" do
      assert md(~s(<p>x<a href="https://example.com"></a></p>)) == "x"
    end
  end

  describe "lists and quotes" do
    test "bulleted, numbered and nested" do
      html = "<ul><li>One</li><li>Two<ol><li>Alpha</li><li>Beta</li></ol></li></ul>"
      assert md(html) == "- One\n- Two\n\n  1. Alpha\n  2. Beta"
    end

    test "block quotes, nested" do
      assert md("<blockquote><p>Outer</p><blockquote>Inner</blockquote></blockquote>") ==
               "> Outer\n>\n> > Inner"
    end
  end

  describe "code" do
    test "inline code, and <pre> as a fenced block with its spacing kept" do
      assert md("<p>Run <code>mix  test</code></p><pre>def x do\n  1\nend</pre>") ==
               "Run `mix test`\n\n```\ndef x do\n  1\nend\n```"
    end

    test "a fence inside the code picks the other fence" do
      assert md("<pre>```\nnested\n```</pre>") == "~~~\n```\nnested\n```\n~~~"
    end
  end

  describe "tables" do
    test "a data table becomes a GFM table, short rows padded, pipes escaped" do
      html =
        "<table><thead><tr><th>Name</th><th>Qty</th></tr></thead>" <>
          "<tbody><tr><td>A|B</td><td>1</td></tr><tr><td>C</td></tr></tbody></table>"

      assert md(html) == "| Name | Qty |\n| --- | --- |\n| A\\|B | 1 |\n| C |  |"
    end

    test "a layout table (blocks in cells) is read cell by cell" do
      html =
        "<table><tr><td><p>Hello there</p></td><td><table><tr><td>inner</td></tr></table></td></tr></table>"

      assert md(html) == "Hello there\n\ninner"
    end

    test "a one-column table is layout too" do
      assert md("<table><tr><td>Only</td></tr><tr><td>Column</td></tr></table>") ==
               "Only\nColumn"
    end
  end

  describe "images" do
    test "an http image is kept" do
      assert md(~s(<img src="https://example.com/a.png" alt="A [chart]">)) ==
               "![A chart](https://example.com/a.png)"
    end

    test "a cid image becomes a reference to the uploaded attachment" do
      cid = fn
        "chart@local" -> "/attachments/7/chart.png"
        _ -> nil
      end

      assert md(~s(<img src="cid:chart@local" alt="chart">), cid: cid) ==
               "![chart](/attachments/7/chart.png)"

      assert md(~s(<p>x<img src="cid:unknown@local"></p>), cid: cid) == "x"
    end

    test "a cid image with no way to resolve it is dropped" do
      assert md(~s(<p>x<img src="cid:chart@local"></p>)) == "x"
    end

    test "tracking pixels, hidden images and data: images are dropped" do
      html =
        ~s(<p>x</p><img src="https://t.example.com/open.gif" width="1" height="1">) <>
          ~s(<img src="https://example.com/h.png" style="display: none">) <>
          ~s(<img src="data:image/png;base64,AAAA">)

      assert md(html) == "x"
    end
  end

  describe "what is dropped" do
    test "head, styles, scripts and comments" do
      html =
        "<html><head><title>T</title><style>p{color:red}</style></head>" <>
          "<body><script>alert(1)</script><!-- note --><p>Body</p></body></html>"

      assert md(html) == "Body"
    end

    test "Outlook's o: tags and hidden preheaders" do
      html =
        ~s(<p class="MsoNormal">Hi<o:p></o:p></p>) <>
          ~s(<div style="display:none;max-height:0">preheader text</div><v:shape>x</v:shape>)

      assert md(html) == "Hi"
    end
  end

  test "the Outlook fixture reads cleanly" do
    raw = File.read!(Path.join([__DIR__, "../../fixtures/inbound/outlook_html_only.eml"]))
    {:ok, message} = Slipdock.Inbound.Message.parse(raw)

    assert md(message.html) == "The “release notes” page needs updating – today."
  end

  test "empty or text-only input" do
    assert md("") == ""
    assert md("plain words") == "plain words"
    assert md("<p>   </p><div></div>") == ""
  end

  test "broken HTML still gives its text" do
    assert md("<p>Unclosed <b>bold <i>and italic") =~ "Unclosed **bold *and italic"
  end
end
