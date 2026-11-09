defmodule SlipdockWeb.FontsTest do
  @moduledoc """
  Brand system 5 (#1705, decision W-2307): the app's type.

  - JetBrains Mono and Sora are vendored WOFF2s under `priv/static/fonts`,
    each with its OFL licence, and declared with `@font-face`.
  - `--font-mono` is JetBrains Mono and every code value reads it: no other
    mono family is written anywhere in the styles or the templates.
  - `--font-display` is Sora, used only by `.page-title`; Inter runs without
    `cv11`.
  - Page titles and section titles are the `page-title` and `section-title`
    classes, sized by the `--text-page-title` and `--text-section-title`
    tokens, not hand-sized in each template.

  These tests read the sources, so a template that brings back
  `text-2xl font-bold` on its `h1` fails here.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  @css File.read!("assets/css/app.css")
  @styles ["assets/css/app.css", "assets/css/codemirror.css"]
  @fonts "priv/static/fonts"

  @vendored %{
    "JetBrainsMonoVariable" => {"JetBrainsMonoVariable.woff2", "JetBrainsMono-OFL.txt"},
    "SoraVariable" => {"SoraVariable.woff2", "Sora-OFL.txt"}
  }

  # Names a mono family by hand.
  @mono_family ~r/\b(?:ui-monospace|SFMono-Regular|Menlo|Consolas|Monaco|Courier(?: New)?|monospace)\b/

  describe "the vendored faces" do
    for {family, {woff2, licence}} <- @vendored do
      test "#{family} is a WOFF2 with its OFL licence" do
        bytes = File.read!(Path.join(@fonts, unquote(woff2)))
        assert <<"wOF2", _::binary>> = bytes
        # A latin subset of the weight axis: a real font, not a stub.
        assert byte_size(bytes) > 10_000

        text = File.read!(Path.join(@fonts, unquote(licence)))
        assert text =~ "SIL Open Font License, Version 1.1"
      end

      test "#{family} is declared with @font-face, from a file that exists" do
        assert %{"src" => src, "weight" => weight} = font_face(@css, unquote(family))
        assert src == "/fonts/" <> unquote(woff2)
        assert File.exists?(Path.join("priv/static", src))
        # Variable: one file carries every weight.
        assert weight =~ ~r/^\d+ \d+$/
      end
    end

    test "every @font-face in app.css points at a file under priv/static" do
      faces = Regex.scan(~r/@font-face\s*\{[^}]*\}/s, @css)
      assert length(faces) == 3

      for [face] <- faces do
        [_, url] = Regex.run(~r/url\("([^"]+)"\)/, face)
        assert File.exists?(Path.join("priv/static", url)), "#{url} isn't vendored"
      end
    end

    test "fonts are served as static files" do
      assert "fonts" in SlipdockWeb.static_paths()
    end

    test "font_face/2 finds nothing for a family that isn't declared" do
      assert font_face(@css, "GeistMono") == nil
    end
  end

  describe "the tokens" do
    test "the mono, display and sans faces lead their stacks" do
      theme = theme_block(@css)
      assert token(theme, "--font-mono") =~ ~r/^"JetBrainsMonoVariable", /
      assert token(theme, "--font-display") =~ ~r/^"SoraVariable", /
      assert token(theme, "--font-sans") =~ ~r/^"InterVariable", /
    end

    test "page and section titles have sizes and line heights" do
      theme = theme_block(@css)

      for name <- ~w(--text-page-title --text-page-title-lg --text-section-title) do
        assert token(theme, name) =~ ~r/^[\d.]+rem$/, "#{name} isn't a rem size"
        assert token(theme, name <> "--line-height") =~ ~r/^[\d.]+rem$/
      end

      assert rem_size(theme, "--text-page-title") > rem_size(theme, "--text-section-title")
      assert rem_size(theme, "--text-page-title-lg") > rem_size(theme, "--text-page-title")
    end

    test "page-title is Sora 600, tight, at the token's size" do
      rule = rule(@css, ".page-title")
      assert rule =~ "font-family: var(--font-display)"
      assert rule =~ "font-size: var(--text-page-title)"
      assert rule =~ "font-weight: 600"
      assert rule =~ "letter-spacing: -0.02em"
    end

    test "section-title is the sans face at the token's size" do
      rule = rule(@css, ".section-title")
      assert rule =~ "font-size: var(--text-section-title)"
      assert rule =~ "font-weight: 600"
      refute rule =~ "font-family"
    end

    test "Inter runs without cv11" do
      [_, body] = Regex.run(~r/\nbody\s*\{([^}]*)\}/, @css)
      assert body =~ "font-feature-settings"
      refute body =~ "cv11"
    end

    test "Sora is used only for page titles" do
      uses = Regex.scan(~r/var\(--font-display\)/, @css)
      assert length(uses) == 1
      refute grep_sources(~r/\bfont-display\b/) |> Enum.any?()
    end
  end

  describe "one mono family" do
    test "no style names a mono family except the --font-mono token" do
      hits =
        for path <- @styles,
            line <- path |> File.read!() |> strip_comments() |> String.split("\n"),
            not String.contains?(line, "--font-mono:"),
            Regex.match?(@mono_family, line),
            do: "#{path}: #{String.trim(line)}"

      assert hits == []
    end

    test "every font-family in the styles reads a token" do
      hits =
        for path <- @styles,
            css = File.read!(path) |> strip_font_faces(),
            [decl, value] <- Regex.scan(~r/font-family:\s*([^;]+);/, css),
            not (value =~ ~r/^(?:var\(--|inherit$)/),
            do: "#{path}: #{decl}"

      assert hits == []
    end

    test "no template sets a font family by hand" do
      assert grep_sources(~r/font-family|font-\[/) == []
      assert grep_sources(@mono_family) == []
    end

    test "the checks catch a hand-written stack" do
      assert Regex.match?(@mono_family, ".x { font-family: ui-monospace, Menlo; }")
      assert Regex.match?(@mono_family, "font-family: 'Courier New'")
      refute Regex.match?(@mono_family, ".field-mono { font-family: var(--font-mono); }")
    end
  end

  describe "titles in templates" do
    test "no page h1 is sized by hand" do
      assert stray_titles(sources(), "h1", ~r/(?<![\w:-])text-(?:lg|xl|2xl|3xl|4xl)(?![\w-])/) ==
               []
    end

    test "no h2 hand-sizes a section title" do
      assert stray_titles(
               sources(),
               "h2",
               ~r/(?<![\w:-])text-(?:lg|xl|2xl)(?![\w-])/
             ) == []
    end

    test "the pages use page-title on their h1" do
      for path <- ~w(
            lib/slipdock_web/live/work_live/index.ex
            lib/slipdock_web/live/favourite_live/index.ex
            lib/slipdock_web/live/template_live/index.ex
            lib/slipdock_web/live/tool_live/index.ex
            lib/slipdock_web/live/group_live/index.ex
            lib/slipdock_web/live/vault_live/index.ex
            lib/slipdock_web/live/garden_live/index.ex
            lib/slipdock_web/live/board_live/visualise.ex
            lib/slipdock_web/live/help_live/index.ex
          ) do
        # Since #1714 a page's h1 comes from <.page_header>, which draws h1.page-title.
        assert File.read!(path) =~ ~r/<h1[^>]*class="[^"]*\bpage-title\b|<\.page_header\b/,
               "#{path} has no h1.page-title"
      end
    end

    test "the check catches a hand-sized title and passes a token one" do
      src = """
      <h1 class="text-2xl font-bold tracking-tight">Mine</h1>
      <h1 class="page-title">Fine</h1>
      <h1
        id="multi"
        class="flex items-center text-xl"
      >Two lines</h1>
      <h2 class="text-base-content/60 section-title">Fine, not text-base</h2>
      """

      assert [{"x.ex", 1, _}, {"x.ex", 3, _}] =
               stray_titles([{"x.ex", src}], "h1", ~r/(?<![\w:-])text-(?:lg|xl|2xl|3xl)(?![\w-])/)

      assert stray_titles([{"x.ex", src}], "h2", ~r/(?<![\w:-])text-(?:lg|base)(?![\w-])/) == []
    end

    test "the check reads past attributes that nest braces" do
      # Each h1 here hid from `\{[^}]*\}`, which stopped at the first `}` (#2595).
      src = ~S"""
      <h1 id={"x-#{f(@a)}-title"} class="text-2xl">Interpolated id</h1>
      <h1 phx-click={JS.toggle(to: "#m-#{@id}")} data-on={@n > 1} class="text-xl">Calls</h1>
      <h1 id={"q-#{"}"}"} title="}" class="text-lg">Braces in strings</h1>
      <h1 data={%{a: 1}} class="text-xl">A bare map</h1>
      <h1 data-x={[%{y: @z}]} class="text-3xl">A list holding a map</h1>
      <h1 title={"a \"}\" b"} class="text-xl">An escaped quote before a brace</h1>
      <h1 id={"ok-#{@id}"} class="page-title">Fine</h1>
      """

      size = ~r/(?<![\w:-])text-(?:lg|xl|2xl|3xl)(?![\w-])/

      assert [
               {"x.ex", 1, first},
               {"x.ex", 2, _},
               {"x.ex", 3, third},
               {"x.ex", 4, map},
               {"x.ex", 5, list},
               {"x.ex", 6, escaped}
             ] = stray_titles([{"x.ex", src}], "h1", size)

      assert first == ~S|<h1 id={"x-#{f(@a)}-title"} class="text-2xl">|
      assert third =~ ~S(class="text-lg">)
      # Bare nested braces need the brace group's own recursion, and an
      # escaped quote needs the string's `\\.`: without either, these hide.
      assert map == ~S|<h1 data={%{a: 1}} class="text-xl">|
      assert list == ~S|<h1 data-x={[%{y: @z}]} class="text-3xl">|
      assert escaped == ~S|<h1 title={"a \"}\" b"} class="text-xl">|
    end

    test "<.header> renders its title as a page-title h1" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <SlipdockWeb.CoreComponents.header>Boards</SlipdockWeb.CoreComponents.header>
        """)

      assert html =~ ~r/<h1 class="page-title">\s*Boards\s*<\/h1>/
    end
  end

  ## Helpers

  defp sources do
    Path.wildcard("lib/slipdock_web/**/*.{ex,heex}")
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp grep_sources(re) do
    for {path, src} <- sources(), Regex.match?(re, src), do: path
  end

  # A `{…}` attribute value: braces nest, and an Elixir string inside one may
  # hold `}` or `>` and its own `#{…}` (#2595: `\{[^}]*\}` stopped at the
  # first `}` and lost the tag).
  @brace_value ~S'(?(DEFINE)(?<brace>\{(?:[^{}"]|(?&str)|(?&brace))*\})' <>
                 ~S'(?<str>"(?:[^"\\#]|\\.|#(?!\{)|#(?&brace))*"))'

  # Tags `<tag …>` whose class matches `size`, as {path, line, tag}.
  defp stray_titles(sources, tag, size) do
    open = Regex.compile!(~s/#{@brace_value}<#{tag}\\b(?:[^>"{]|"[^"]*"|(?&brace))*>/, "s")

    for {path, src} <- sources,
        [{at, len}] <- Regex.scan(open, src, return: :index, capture: :first),
        text = binary_part(src, at, len),
        [_, class] <- [Regex.run(~r/\bclass="([^"]*)"/, text) || [nil, ""]],
        Regex.match?(size, class) do
      line = src |> binary_part(0, at) |> String.split("\n") |> length()
      {path, line, String.replace(text, ~r/\s+/, " ")}
    end
  end

  defp font_face(css, family) do
    Regex.scan(~r/@font-face\s*\{([^}]*)\}/s, css)
    |> Enum.find_value(fn [_, body] ->
      if body =~ ~s(font-family: "#{family}";) do
        [_, src] = Regex.run(~r/src:\s*url\("([^"]+)"\)/, body)
        [_, weight] = Regex.run(~r/font-weight:\s*([^;]+);/, body)
        %{"src" => src, "weight" => weight}
      end
    end)
  end

  defp theme_block(css) do
    [_, block] = Regex.run(~r/\n@theme\s*\{(.*?)\n\}/s, css)
    block
  end

  defp token(block, name) do
    case Regex.run(~r/\s#{Regex.escape(name)}:\s*([^;]+);/, block) do
      [_, value] -> String.trim(value)
      nil -> flunk("#{name} isn't in @theme")
    end
  end

  defp rem_size(block, name), do: block |> token(name) |> Float.parse() |> elem(0)

  defp rule(css, selector) do
    case Regex.run(~r/\n\s*#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) do
      [_, body] -> body
      nil -> flunk("no #{selector} rule")
    end
  end

  defp strip_font_faces(css), do: Regex.replace(~r/@font-face\s*\{[^}]*\}/s, css, "")

  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")
end
