defmodule SlipdockWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias SlipdockWeb.Markdown

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  test "paragraphs, lists and headings" do
    html =
      render(
        "**Headline**\n\nFirst para\nsecond line\n\n- one\n- two *soft*\n\n1. a\n2. b\n\n## Next"
      )

    assert html ==
             "<p><strong>Headline</strong></p><p>First para<br>second line</p>" <>
               "<ul><li>one</li><li>two <em>soft</em></li></ul><ol><li>a</li><li>b</li></ol>" <>
               "<p><strong>Next</strong></p>"
  end

  test "inline code, links and escaping" do
    html = render("Use `mix test` at https://example.com <script>alert(1)</script>")
    assert html =~ "<code>mix test</code>"
    assert html =~ ~s|<a href="https://example.com"|
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end

  test "asterisks inside words stay literal" do
    assert render("2*3*4 and snake_case_name") == "<p>2*3*4 and snake_case_name</p>"
    assert render("") == ""
    assert render(nil) == ""
  end
end
