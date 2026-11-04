defmodule SlipdockWeb.CalloutTest do
  @moduledoc """
  `callout/1` (#1697): one component for every notice set into a page. Its
  text is one flowing block (inline code stays in the sentence), in
  base-content on its kind's tint, and that reads at AA (4.5:1) in light,
  dark and the phone's dark ramp, worked out from the tokens in app.css.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias SlipdockWeb.CoreComponents

  @css File.read!("assets/css/app.css")

  # The surface a callout sits on is its tint at 10% over the page or a card.
  @tint 0.10

  describe "rendering" do
    for {kind, icon} <- [
          info: "hero-information-circle",
          warning: "hero-exclamation-triangle",
          error: "hero-exclamation-circle"
        ] do
      test "#{kind}: its icon, tint and left rule; the text is never the kind's colour" do
        html = callout(kind: unquote(kind), body: "Something to know.")
        doc = LazyHTML.from_fragment(html)
        root = LazyHTML.query(doc, "[data-callout=#{unquote(kind)}]")

        assert Enum.count(root) == 1
        class = root |> LazyHTML.attribute("class") |> hd()
        assert class =~ "border-l-4"
        assert class =~ "border-#{unquote(kind)}"
        assert class =~ "bg-#{unquote(kind)}/10"
        assert class =~ "text-base-content"
        refute class =~ ~r/\btext-#{unquote(kind)}\b/
        assert html =~ unquote(icon)
        assert LazyHTML.text(root) =~ "Something to know."
      end
    end

    test "with no kind it is info, a note rather than an alert" do
      html = callout(body: "Plain.")
      assert html =~ ~s(data-callout="info")
      assert html =~ ~s(role="note")
    end

    test "a warning or an error is an alert" do
      assert callout(kind: :warning, body: "x") =~ ~s(role="alert")
      assert callout(kind: :error, body: "x") =~ ~s(role="alert")
    end

    test "a title goes above the text, and none means no empty heading" do
      titled = callout(kind: :error, title: "Couldn't save", body: "The board is archived.")
      assert titled =~ ~r/<p class="font-semibold">\s*Couldn&#39;t save\s*<\/p>/

      refute callout(kind: :error, body: "x") =~ "font-semibold"
    end

    test "id and extra classes reach the outer element" do
      html = callout(id: "my-note", class: "mt-6", body: "x")
      doc = LazyHTML.from_fragment(html)
      class = doc |> LazyHTML.query("#my-note") |> LazyHTML.attribute("class") |> hd()
      assert class =~ "mt-6"
    end

    test "text, inline code and the rest of the sentence are one block, not columns" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.callout id="c" kind={:warning}>
          Run <code>mix slipdock.reindex</code> on the server to build it.
        </CoreComponents.callout>
        """)

      doc = LazyHTML.from_fragment(html)
      # The flex row holds exactly two things: the icon and the text block.
      assert doc |> LazyHTML.query("#c > *") |> Enum.count() == 2
      block = LazyHTML.query(doc, "#c > div > div")
      assert block |> LazyHTML.query("code") |> Enum.count() == 1
      assert squish(LazyHTML.text(block)) == "Run mix slipdock.reindex on the server to build it."
    end
  end

  describe "contrast" do
    for theme <- ["light", "dark"], kind <- ~w(info warning error) do
      test "#{theme}: base-content reads on the #{kind} tint over base-100 and base-200" do
        tokens = theme(unquote(theme))

        for surface <- ~w(base-100 base-200) do
          bg = mix(tokens[unquote(kind)], tokens[surface], @tint)

          assert_reads(
            tokens["base-content"],
            bg,
            "#{unquote(theme)} #{unquote(kind)} on #{surface}"
          )
        end
      end
    end

    test "the phone's dark ramp keeps every kind readable" do
      tokens = Map.merge(theme("dark"), phone_ramp())

      for kind <- ~w(info warning error), surface <- ~w(base-100 base-200) do
        bg = mix(tokens[kind], tokens[surface], @tint)
        assert_reads(tokens["base-content"], bg, "phone dark #{kind} on #{surface}")
      end
    end

    test "the old notice, the kind's own colour on its tint, would have failed" do
      # Why the text is base-content: amber on pale amber was the bug.
      light = theme("light")
      bg = mix(light["warning"], light["base-100"], @tint)
      assert contrast(light["warning"], bg) < 4.5
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp callout(opts) do
    {body, opts} = Keyword.pop(opts, :body)
    assigns = %{opts: Map.new(opts), body: body}

    rendered_to_string(~H"""
    <CoreComponents.callout {@opts}>{@body}</CoreComponents.callout>
    """)
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

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

  defp assert_reads(fg, bg, what) do
    ratio = contrast(fg, bg)
    assert ratio >= 4.5, "#{what}: #{Float.round(ratio, 2)}:1, under 4.5:1"
  end

  # A translucent colour over a surface, composited in gamma-encoded sRGB.
  defp mix(fg, bg, alpha) do
    Enum.zip_with(channels(fg), channels(bg), fn f, b -> round(alpha * f + (1 - alpha) * b) end)
    |> Enum.map_join(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> then(&("#" <> &1))
  end

  defp channels("#" <> hex), do: hex |> Base.decode16!(case: :mixed) |> :binary.bin_to_list()

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
    {hi, lo} = Enum.min_max([luminance(a), luminance(b)]) |> then(fn {l, h} -> {h, l} end)
    (hi + 0.05) / (lo + 0.05)
  end
end
