defmodule Slipdock.PaletteTest do
  @moduledoc """
  A person's colour (#1696): stable for a user id, never slate for a real
  person, and readable on the brand surfaces (#1702). The contrast is worked out from the palette's own
  oklch values, the way a browser paints them: the light theme's 700 text on
  a 100 fill, the dark theme's 200 text on 400 at 20% over every surface an
  avatar sits on.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Palette

  # The themes' surfaces, read from assets/css/app.css (#1702): daisyUI's
  # base-100/200/300 in each theme, and the phone's stretched dark ramp.
  @css File.read!("assets/css/app.css")
  @themes String.split(@css, ~s(@plugin "daisyui/packages/bundle/daisyui-theme" {))
  @surface ~r/--color-base-(?:100|200|300):\s*(#[0-9A-Fa-f]{6});/
  @light_surfaces for t <- @themes,
                      t =~ ~s(name: "light";),
                      [_, hex] <- Regex.scan(@surface, hd(String.split(t, "\n}"))),
                      do: hex
  @phone_ramp Regex.run(~r/@media \(width < 40rem\) \{\s*\[data-theme="dark"\] \{(.*?)\}/s, @css)
  @dark_surfaces for(
                   t <- @themes,
                   t =~ ~s(name: "dark";),
                   [_, hex] <- Regex.scan(@surface, hd(String.split(t, "\n}"))),
                   do: hex
                 ) ++
                   for([_, hex] <- Regex.scan(@surface, List.last(@phone_ramp)), do: hex)

  test "reads three light surfaces and six dark ones from app.css" do
    assert length(@light_surfaces) == 3
    assert length(@dark_surfaces) == 6
  end

  describe "person_colour/1" do
    test "is the same for the same id, every time" do
      for id <- [1, 2, 42, 1_000_003] do
        assert Palette.person_colour(id) == Palette.person_colour(id)
      end

      # Pinned, so a change to the hash (which would recolour everybody)
      # can't slip through.
      assert Enum.map(1..6, &Palette.person_colour/1) ==
               Enum.map(1..6, &Enum.at(Palette.names() -- ["slate"], :erlang.phash2(&1, 11)))
    end

    test "spreads people over every colour but slate" do
      colours = 1..500 |> Enum.map(&Palette.person_colour/1) |> Enum.uniq() |> Enum.sort()
      assert colours == Enum.sort(Palette.names() -- ["slate"])
    end

    test "is slate for nobody" do
      assert Palette.person_colour(nil) == "slate"
      assert Palette.person(nil) == Palette.chip("slate")
    end

    test "person/1 is that colour's chip tint, with 700 text in light and 200 in dark" do
      for id <- 1..40 do
        colour = Palette.person_colour(id)
        classes = Palette.person(id)
        assert classes == Palette.chip(colour)
        assert classes =~ "bg-#{colour}-100 text-#{colour}-700"
        assert classes =~ "dark:bg-#{colour}-400/20 dark:text-#{colour}-200"
      end
    end
  end

  describe "tone/2" do
    test "has every step the chips paint with, for every colour" do
      for name <- Palette.names(), step <- [100, 200, 400, 700] do
        assert {l, c, h} = Palette.tone(name, step)
        assert l > 0 and l < 100 and c >= 0 and h >= 0
      end
    end

    test "an unknown colour falls back to slate's" do
      assert Palette.tone("mauve", 700) == Palette.tone("slate", 700)
    end
  end

  describe "contrast" do
    test "initials reach 4.5:1 in the light theme, for every person colour" do
      # The light fill is opaque, so the surface under it doesn't matter.
      for name <- Palette.names() do
        ratio = contrast(rgb(Palette.tone(name, 700)), rgb(Palette.tone(name, 100)))
        assert ratio >= 4.5, "#{name}: #{Float.round(ratio, 2)}:1 in light"
      end
    end

    test "initials reach 4.5:1 in the dark theme, over every surface" do
      for name <- Palette.names(), surface <- @dark_surfaces do
        fill = over(rgb(Palette.tone(name, 400)), 0.2, rgb(surface))
        ratio = contrast(rgb(Palette.tone(name, 200)), fill)
        assert ratio >= 4.5, "#{name} on #{inspect(surface)}: #{Float.round(ratio, 2)}:1 in dark"
      end
    end

    test "the old avatar (98% text on a 20% tint of itself) fails, so the check can fail" do
      # secondary-content on secondary/20 over the light base: near white on near white.
      text = rgb({98, 0.01, 300})
      fill = over(rgb({65, 0.2, 300}), 0.2, rgb(hd(@light_surfaces)))
      assert contrast(text, fill) < 1.5
    end
  end

  # A theme's hex surface → linear sRGB.
  defp rgb("#" <> hex) do
    hex
    |> Base.decode16!(case: :mixed)
    |> :binary.bin_to_list()
    |> Enum.map(&decode(&1 / 255))
  end

  # oklch → linear sRGB, clamped to the gamut the way a browser clips it.
  defp rgb({l, c, h}) do
    l = l / 100
    a = c * :math.cos(h * :math.pi() / 180)
    b = c * :math.sin(h * :math.pi() / 180)
    l_ = :math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    m_ = :math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    s_ = :math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

    [
      4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
      -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
      -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
    ]
    |> Enum.map(&min(1.0, max(0.0, &1)))
  end

  # A translucent fill composited over a surface, as browsers do: in
  # gamma-encoded sRGB.
  defp over(fg, alpha, bg) do
    Enum.zip_with(fg, bg, fn f, g -> decode(alpha * encode(f) + (1 - alpha) * encode(g)) end)
  end

  defp encode(x) when x <= 0.0031308, do: 12.92 * x
  defp encode(x), do: 1.055 * :math.pow(x, 1 / 2.4) - 0.055
  defp decode(x) when x <= 0.04045, do: x / 12.92
  defp decode(x), do: :math.pow((x + 0.055) / 1.055, 2.4)

  defp luminance([r, g, b]), do: 0.2126 * r + 0.7152 * g + 0.0722 * b

  defp contrast(a, b) do
    {la, lb} = {luminance(a), luminance(b)}
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end
end
