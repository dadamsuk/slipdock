defmodule SlipdockWeb.ErrorHTMLTest do
  use SlipdockWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  # #325: an error is a page of the app, styled, saying what happened and
  # offering the way back — not a bare line of text.
  test "renders 404.html as a page with the way back" do
    html = render_to_string(SlipdockWeb.ErrorHTML, "404", "html", [])

    assert html =~ "<title>Not Found · Slipdock</title>"
    assert html =~ "/assets/css/app.css"
    assert html =~ "nothing here"
    assert html =~ ~s|href="/"|
    assert html =~ "Back to your boards"
  end

  test "renders 500.html saying it was logged and nothing was lost" do
    html = render_to_string(SlipdockWeb.ErrorHTML, "500", "html", [])

    assert html =~ "<h1 class=\"text-2xl font-semibold\">Internal Server Error</h1>"
    assert html =~ "It has been logged"
    assert html =~ "Back to your boards"
  end

  test "any other status gets its name and a generic way back" do
    html = render_to_string(SlipdockWeb.ErrorHTML, "422", "html", [])

    assert html =~ "Unprocessable"
    assert html =~ "could not be completed"
    assert html =~ "Back to your boards"
  end
end
