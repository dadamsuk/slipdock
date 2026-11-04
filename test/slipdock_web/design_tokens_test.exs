defmodule SlipdockWeb.DesignTokensTest do
  @moduledoc """
  The brand palette in `assets/css/app.css` (#1702, decision W-2307): the
  values match the decision, the text on them reads (4.5:1, WCAG AA for small
  text) in light, dark and the phone's dark ramp, nothing paints the old
  default loading bar, and no template under `lib/slipdock_web` writes a
  colour by hand.

  The contrast is worked out from the tokens themselves, read out of
  app.css, so changing a value there is what this test checks.
  """
  use ExUnit.Case, async: true

  @css File.read!("assets/css/app.css")

  # Files that may write a colour out, and why.
  @exempt %{
    # Collaborator cursors handed to the Excalidraw canvas, which takes hex;
    # chosen to tell people apart on its white or dark canvas, not themed.
    "lib/slipdock_web/presence.ex" => :excalidraw_collaborators
  }

  # A hex colour as a whole word (six or eight digits), a short one where a
  # colour is plainly meant, a Tailwind arbitrary colour, or a CSS colour
  # function. Card references (`#1702`) and anchors (`href="#add"`) aren't.
  @colour_patterns [
    ~r/(?:^|["'\s(=:,])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6})\b/,
    ~r/(?:color|fill|stroke|background|border|stop-color)[\w-]*\s*[:=]\s*["']?#[0-9a-fA-F]{3,8}\b/i,
    ~r/-\[#[0-9a-fA-F]/,
    ~r/\b(?:rgba?|hsla?|oklch|oklab)\(/
  ]

  describe "the themes" do
    test "light follows the decision: Slip teal on white and Page, Harbor ink text" do
      light = theme("light")
      assert light["base-100"] == "#FFFFFF"
      assert light["base-200"] == "#F3F6F7"
      assert light["base-300"] == "#E2EAED"
      assert light["base-content"] == "#10263A"
      assert light["primary"] == "#1A6E7C"
      assert light["primary-content"] == "#FFFFFF"
      assert light["accent"] == "#F26A3A"
    end

    test "dark follows the decision: Harbor ink ground, Mist text, Slip teal light" do
      dark = theme("dark")
      assert dark["base-100"] == "#16304A"
      assert dark["base-200"] == "#10263A"
      assert dark["base-content"] == "#EAF1F3"
      assert dark["primary"] == "#5FB3C1"
      assert dark["accent"] == "#F26A3A"
    end

    test "every theme sets every colour daisyUI paints with, as hex" do
      names =
        ~w(base-100 base-200 base-300 base-content primary primary-content secondary
           secondary-content accent accent-content neutral neutral-content info info-content
           success success-content warning warning-content error error-content)

      for name <- ["light", "dark"] do
        tokens = theme(name)
        assert Enum.sort(Map.keys(tokens)) == Enum.sort(names), "#{name}"

        for {key, value} <- tokens do
          assert value =~ ~r/^#[0-9A-F]{6}$/, "#{name} --color-#{key}: #{value}"
        end
      end
    end

    test "the phone's dark ramp stretches the surfaces apart, on the same hue" do
      dark = theme("dark")
      phone = phone_ramp()
      assert Map.keys(phone) |> Enum.sort() == ~w(base-100 base-200 base-300)
      # Raised surfaces lift, the ground and the borders drop.
      assert luminance(phone["base-100"]) > luminance(dark["base-100"])
      assert luminance(phone["base-200"]) < luminance(dark["base-200"])
      assert luminance(phone["base-300"]) < luminance(dark["base-300"])
    end
  end

  describe "contrast" do
    test "text, muted text and button labels reach 4.5:1 in both themes" do
      for {name, tokens} <- [{"light", theme("light")}, {"dark", theme("dark")}],
          surface <- ["base-100", "base-200"] do
        text = tokens["base-content"]
        bg = tokens[surface]
        assert_reads(text, bg, "#{name} text on #{surface}")
        assert_reads(muted(text, bg), bg, "#{name} muted text on #{surface}")
      end

      for {name, tokens} <- [{"light", theme("light")}, {"dark", theme("dark")}] do
        assert_reads(tokens["primary-content"], tokens["primary"], "#{name} button label")
        assert_reads(tokens["primary"], tokens["base-100"], "#{name} primary as a link")
      end
    end

    test "muted text reads on the phone's dark ramp too" do
      dark = theme("dark")

      for {surface, bg} <- phone_ramp(), surface != "base-300" do
        assert_reads(dark["base-content"], bg, "phone text on #{surface}")
        assert_reads(muted(dark["base-content"], bg), bg, "phone muted text on #{surface}")
      end
    end

    test "status colours carry their labels, and the neutral and secondary theirs" do
      for {name, tokens} <- [{"light", theme("light")}, {"dark", theme("dark")}],
          colour <- ~w(info success warning error neutral secondary accent) do
        assert_reads(tokens["#{colour}-content"], tokens[colour], "#{name} #{colour}")
      end
    end

    test "muted text is drawn at 65%, in the utilities layer" do
      assert muted_share() == 0.65
      [_, block] = Regex.run(~r/@layer utilities \{(.*?)\n\}/s, @css)
      assert block =~ ".text-base-content\\/60"
    end

    test "the check can fail: /60 of Harbor ink on white is under 4.5:1" do
      light = theme("light")
      text = mix(light["base-content"], light["base-100"], 0.60)
      assert contrast(text, light["base-100"]) < 4.5
      # And orange carries no white label, which is why the accent's is ink.
      assert contrast("#FFFFFF", light["accent"]) < 4.5
    end
  end

  describe "the page around the app" do
    test "the loading bar takes the primary; Phoenix's default blue is gone" do
      app = File.read!("assets/js/app.js")
      refute app =~ "#29d"
      assert app =~ "topbar.config(topbarOptions())"
      assert File.read!("assets/js/theme_color.js") =~ ~s|read("primary")|
    end

    test "theme-color follows the theme instead of being written in the layout" do
      root = File.read!("lib/slipdock_web/components/layouts/root.html.heex")
      refute root =~ "theme-color"
      assert File.read!("assets/js/theme.js") =~ "syncThemeColor()"
    end
  end

  describe "no hand-written colours in lib/slipdock_web" do
    test "every template and module paints from the theme" do
      found =
        for path <- Path.wildcard("lib/slipdock_web/**/*.{ex,heex,exs}"),
            not Map.has_key?(@exempt, path),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            colour_literal?(line) do
          "#{path}:#{n}: #{String.trim(line)}"
        end

      assert found == [],
             "colours written by hand; use a theme colour (text-primary, bg-base-200, …):\n" <>
               Enum.join(found, "\n")
    end

    test "the orange accent is never text (3.0:1 on white): it marks the moving card" do
      found =
        for path <- Path.wildcard("lib/slipdock_web/**/*.{ex,heex}"),
            File.read!(path) =~ ~r/\btext-accent\b/,
            do: path

      assert found == []
    end

    test "the exempt files exist and still need it" do
      for {path, _why} <- @exempt do
        assert File.exists?(path), "#{path} is exempt but gone; drop it from @exempt"
        assert path |> File.read!() |> String.split("\n") |> Enum.any?(&colour_literal?/1)
      end
    end

    test "catches what it should" do
      for line <- [
            ~S|<path fill="#10263A" />|,
            ~S|style="color: #fff"|,
            ~S|class="bg-[#1e7f8f] p-2"|,
            ~S|background: rgba(0, 0, 0, .3)|,
            ~S|border-color: oklch(56% 0.11 277)|,
            ~S|@colours ~w(#e03131 #1971c2)|,
            ~S|stroke='#abc'|
          ] do
        assert colour_literal?(line), line
      end
    end

    test "leaves card references, anchors and ids alone" do
      for line <- [
            ~S|Closed by #1702 and #1700.|,
            ~S|<a href="#add">Add</a>|,
            ~S|phx-target="#card-123"|,
            ~S|gettext("#%{id}")|,
            ~S|class="text-primary bg-base-200"|
          ] do
        refute colour_literal?(line), line
      end
    end
  end

  # -- reading app.css ---------------------------------------------------------

  defp theme(name) do
    block =
      @css
      |> String.split(~s(@plugin "daisyui/packages/bundle/daisyui-theme" {))
      |> Enum.find(&(&1 =~ ~s(name: "#{name}";))) ||
        flunk("no #{name} theme in app.css")

    block |> String.split("\n}", parts: 2) |> hd() |> colours()
  end

  defp phone_ramp do
    [_, block] =
      Regex.run(~r/@media \(width < 40rem\) \{\s*\[data-theme="dark"\] \{(.*?)\}/s, @css) ||
        flunk("no phone dark ramp in app.css")

    colours(block)
  end

  defp colours(block) do
    Regex.scan(~r/--color-([\w-]+):\s*([^;]+);/, block)
    |> Map.new(fn [_, key, value] -> {key, String.upcase(String.trim(value))} end)
  end

  defp muted_share do
    [_, pct] =
      Regex.run(
        ~r/@layer utilities \{\s*\.text-base-content\\\/60 \{\s*color: color-mix\(in oklab, var\(--color-base-content\) (\d+)%, transparent\);/,
        @css
      ) || flunk("no muted-text rule in app.css")

    String.to_integer(pct) / 100
  end

  defp muted(text, bg), do: mix(text, bg, muted_share())

  defp colour_literal?(line), do: Enum.any?(@colour_patterns, &Regex.match?(&1, line))

  # -- colour arithmetic ---------------------------------------------------------

  defp assert_reads(fg, bg, what) do
    ratio = contrast(fg, bg)
    assert ratio >= 4.5, "#{what}: #{Float.round(ratio, 2)}:1, under 4.5:1"
  end

  # A translucent colour over a surface, as a browser composites it: in
  # gamma-encoded sRGB. Returns the result as a hex string.
  defp mix(fg, bg, alpha) do
    Enum.zip_with(channels(fg), channels(bg), fn f, b -> round(alpha * f + (1 - alpha) * b) end)
    |> Enum.map_join(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> then(&("#" <> &1))
  end

  defp channels("#" <> hex) do
    hex |> Base.decode16!(case: :mixed) |> :binary.bin_to_list()
  end

  defp luminance(hex) do
    [r, g, b] =
      hex
      |> channels()
      |> Enum.map(fn c ->
        c = c / 255
        if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end)

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp contrast(a, b) do
    {la, lb} = {luminance(a), luminance(b)}
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end
end
