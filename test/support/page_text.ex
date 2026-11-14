defmodule SlipdockWeb.PageText do
  @moduledoc """
  Refute a short identifier on a page by what a person reads, not by the
  whole HTML (#3163).

  `refute render(view) =~ page.code` matches the markup too: the
  `data-phx-session` and `data-phx-static` tokens are URL-safe base64, whose
  alphabet holds `W`, `-` and digits, so a code like `W-31` turns up in them
  by chance (#3146, #2942), and `"#12"` turns up inside `"#120"` or a CSS
  colour (#2849). The test then fails once in a few hundred runs.

  So a refute of an id, a code or a shortcut goes through `refute_mentions/2`:
  it reads the page's text (no attributes, no `<script>` or `<style>`) and
  matches the identifier as a whole token, so `W-31` doesn't match `W-310`.
  To check a link or an attribute, select the element (`has_element?/3` with
  an `href` selector) instead of searching the HTML.
  """
  import ExUnit.Assertions

  @doc """
  The text a person reads on `page`: a LiveView, rendered HTML or an
  element. Tags, attributes, scripts and styles are dropped; whitespace runs
  become one space.
  """
  def text(%Phoenix.LiveViewTest.View{} = view),
    do: view |> Phoenix.LiveViewTest.render() |> text()

  def text(%Phoenix.LiveViewTest.Element{} = el),
    do: el |> Phoenix.LiveViewTest.render() |> text()

  def text(html) when is_binary(html) do
    html
    |> Floki.parse_document!()
    # Floki.text/2 leaves out <script> by itself, but not <style>.
    |> Floki.filter_out("style")
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Whether `token` appears in `text` as a whole token: not as part of a longer
  word, number or code (`W-31` is not in `W-310`, `#12` is not in `#120`).
  """
  def mentions?(text, token) when is_binary(text) and is_binary(token) do
    Regex.match?(~r/(?<![\w-])#{Regex.escape(token)}(?![\w-])/u, text)
  end

  @doc """
  Fails if a person reading `page` would see `token`.
  """
  def refute_mentions(page, token) do
    text = text(page)

    refute mentions?(text, token),
           "expected the page not to show #{inspect(token)}, but its text does:\n\n" <>
             String.slice(text, 0, 2_000)

    :ok
  end

  @doc """
  Fails unless a person reading `page` would see `token`.
  """
  def assert_mentions(page, token) do
    text = text(page)

    assert mentions?(text, token),
           "expected the page to show #{inspect(token)}, but its text doesn't:\n\n" <>
             String.slice(text, 0, 2_000)

    :ok
  end
end
