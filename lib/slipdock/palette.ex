defmodule Slipdock.Palette do
  @moduledoc """
  Named colours shared by boards, columns, tags and card covers: pastel
  tints in the light theme, muted in the dark one. Every class string is
  written out in full so Tailwind can find it.
  """

  @colors [
    {"slate", "Slate", "bg-slate-300 dark:bg-slate-400",
     "bg-slate-100 text-slate-700 dark:bg-slate-400/20 dark:text-slate-200",
     "border-slate-300 dark:border-slate-400",
     "from-slate-200 to-slate-300 dark:from-slate-400/60 dark:to-slate-500/60"},
    {"red", "Red", "bg-red-300 dark:bg-red-400",
     "bg-red-100 text-red-700 dark:bg-red-400/20 dark:text-red-200",
     "border-red-300 dark:border-red-400",
     "from-red-200 to-rose-300 dark:from-red-400/60 dark:to-rose-500/60"},
    {"orange", "Orange", "bg-orange-300 dark:bg-orange-400",
     "bg-orange-100 text-orange-700 dark:bg-orange-400/20 dark:text-orange-200",
     "border-orange-300 dark:border-orange-400",
     "from-orange-200 to-amber-300 dark:from-orange-400/60 dark:to-amber-500/60"},
    {"amber", "Amber", "bg-amber-300 dark:bg-amber-400",
     "bg-amber-100 text-amber-700 dark:bg-amber-400/20 dark:text-amber-200",
     "border-amber-300 dark:border-amber-400",
     "from-amber-200 to-yellow-300 dark:from-amber-400/60 dark:to-yellow-500/60"},
    {"lime", "Lime", "bg-lime-300 dark:bg-lime-400",
     "bg-lime-100 text-lime-700 dark:bg-lime-400/20 dark:text-lime-200",
     "border-lime-300 dark:border-lime-400",
     "from-lime-200 to-green-300 dark:from-lime-400/60 dark:to-green-500/60"},
    {"emerald", "Emerald", "bg-emerald-300 dark:bg-emerald-400",
     "bg-emerald-100 text-emerald-700 dark:bg-emerald-400/20 dark:text-emerald-200",
     "border-emerald-300 dark:border-emerald-400",
     "from-emerald-200 to-teal-300 dark:from-emerald-400/60 dark:to-teal-500/60"},
    {"teal", "Teal", "bg-teal-300 dark:bg-teal-400",
     "bg-teal-100 text-teal-700 dark:bg-teal-400/20 dark:text-teal-200",
     "border-teal-300 dark:border-teal-400",
     "from-teal-200 to-cyan-300 dark:from-teal-400/60 dark:to-cyan-500/60"},
    {"sky", "Sky", "bg-sky-300 dark:bg-sky-400",
     "bg-sky-100 text-sky-700 dark:bg-sky-400/20 dark:text-sky-200",
     "border-sky-300 dark:border-sky-400",
     "from-sky-200 to-blue-300 dark:from-sky-400/60 dark:to-blue-500/60"},
    {"indigo", "Indigo", "bg-indigo-300 dark:bg-indigo-400",
     "bg-indigo-100 text-indigo-700 dark:bg-indigo-400/20 dark:text-indigo-200",
     "border-indigo-300 dark:border-indigo-400",
     "from-indigo-200 to-violet-300 dark:from-indigo-400/60 dark:to-violet-500/60"},
    {"violet", "Violet", "bg-violet-300 dark:bg-violet-400",
     "bg-violet-100 text-violet-700 dark:bg-violet-400/20 dark:text-violet-200",
     "border-violet-300 dark:border-violet-400",
     "from-violet-200 to-purple-300 dark:from-violet-400/60 dark:to-purple-500/60"},
    {"fuchsia", "Fuchsia", "bg-fuchsia-300 dark:bg-fuchsia-400",
     "bg-fuchsia-100 text-fuchsia-700 dark:bg-fuchsia-400/20 dark:text-fuchsia-200",
     "border-fuchsia-300 dark:border-fuchsia-400",
     "from-fuchsia-200 to-pink-300 dark:from-fuchsia-400/60 dark:to-pink-500/60"},
    {"rose", "Rose", "bg-rose-300 dark:bg-rose-400",
     "bg-rose-100 text-rose-700 dark:bg-rose-400/20 dark:text-rose-200",
     "border-rose-300 dark:border-rose-400",
     "from-rose-200 to-red-300 dark:from-rose-400/60 dark:to-red-500/60"}
  ]

  # Text in the colour: an icon tinted by it (#792). Written out in full,
  # like the rest, so Tailwind finds every one.
  @text %{
    "slate" => "text-slate-500 dark:text-slate-300",
    "red" => "text-red-500 dark:text-red-300",
    "orange" => "text-orange-500 dark:text-orange-300",
    "amber" => "text-amber-500 dark:text-amber-300",
    "lime" => "text-lime-500 dark:text-lime-300",
    "emerald" => "text-emerald-500 dark:text-emerald-300",
    "teal" => "text-teal-500 dark:text-teal-300",
    "sky" => "text-sky-500 dark:text-sky-300",
    "indigo" => "text-indigo-500 dark:text-indigo-300",
    "violet" => "text-violet-500 dark:text-violet-300",
    "fuchsia" => "text-fuchsia-500 dark:text-fuchsia-300",
    "rose" => "text-rose-500 dark:text-rose-300"
  }

  # Tailwind 4's own values (oklch: lightness %, chroma, hue) for the steps
  # `chip/1` paints with: 100 fill and 700 text in the light theme, 400 at
  # 20% fill and 200 text in the dark. Kept so a test can work out the
  # contrast of an avatar's initials from the colours themselves (#1696).
  @tones %{
    "slate" => %{
      100 => {96.8, 0.007, 247.896},
      200 => {92.9, 0.013, 255.508},
      400 => {70.4, 0.04, 256.788},
      700 => {37.2, 0.044, 257.287}
    },
    "red" => %{
      100 => {93.6, 0.032, 17.717},
      200 => {88.5, 0.062, 18.334},
      400 => {70.4, 0.191, 22.216},
      700 => {50.5, 0.213, 27.518}
    },
    "orange" => %{
      100 => {95.4, 0.038, 75.164},
      200 => {90.1, 0.076, 70.697},
      400 => {75, 0.183, 55.934},
      700 => {55.3, 0.195, 38.402}
    },
    "amber" => %{
      100 => {96.2, 0.059, 95.617},
      200 => {92.4, 0.12, 95.746},
      400 => {82.8, 0.189, 84.429},
      700 => {55.5, 0.163, 48.998}
    },
    "lime" => %{
      100 => {96.7, 0.067, 122.328},
      200 => {93.8, 0.127, 124.321},
      400 => {84.1, 0.238, 128.85},
      700 => {53.2, 0.157, 131.589}
    },
    "emerald" => %{
      100 => {95, 0.052, 163.051},
      200 => {90.5, 0.093, 164.15},
      400 => {76.5, 0.177, 163.223},
      700 => {50.8, 0.118, 165.612}
    },
    "teal" => %{
      100 => {95.3, 0.051, 180.801},
      200 => {91, 0.096, 180.426},
      400 => {77.7, 0.152, 181.912},
      700 => {51.1, 0.096, 186.391}
    },
    "sky" => %{
      100 => {95.1, 0.026, 236.824},
      200 => {90.1, 0.058, 230.902},
      400 => {74.6, 0.16, 232.661},
      700 => {50, 0.134, 242.749}
    },
    "indigo" => %{
      100 => {93, 0.034, 272.788},
      200 => {87, 0.065, 274.039},
      400 => {67.3, 0.182, 276.935},
      700 => {45.7, 0.24, 277.023}
    },
    "violet" => %{
      100 => {94.3, 0.029, 294.588},
      200 => {89.4, 0.057, 293.283},
      400 => {70.2, 0.183, 293.541},
      700 => {49.1, 0.27, 292.581}
    },
    "fuchsia" => %{
      100 => {95.2, 0.037, 318.852},
      200 => {90.3, 0.076, 319.62},
      400 => {74, 0.238, 322.16},
      700 => {51.8, 0.253, 323.949}
    },
    "rose" => %{
      100 => {94.1, 0.03, 12.58},
      200 => {89.2, 0.058, 10.001},
      400 => {71.2, 0.194, 13.428},
      700 => {51.4, 0.222, 16.935}
    }
  }

  # People get a colour of their own, but never slate: grey reads as nobody.
  @people Enum.map(@colors, &elem(&1, 0)) -- ["slate"]

  def names, do: Enum.map(@colors, &elem(&1, 0))

  def all, do: Enum.map(@colors, fn {n, l, _, _, _, _} -> {n, l} end)

  def label(name), do: find(name) |> elem(1)
  def dot(name), do: find(name) |> elem(2)
  def chip(name), do: find(name) |> elem(3)
  def border(name), do: find(name) |> elem(4)
  def gradient(name), do: find(name) |> elem(5)

  def text(name), do: Map.get(@text, name, @text["slate"])

  @doc "The oklch `{lightness %, chroma, hue}` of a colour at a Tailwind step (100, 200, 400, 700)."
  def tone(name, step), do: @tones |> Map.get(name, @tones["slate"]) |> Map.fetch!(step)

  @doc """
  A person's colour, the same everywhere they appear: picked by hashing
  their user id, so it never depends on the page or the order people are
  listed in. No id (someone not saved, a deleted author) is slate.
  """
  def person_colour(nil), do: "slate"
  def person_colour(id), do: Enum.at(@people, :erlang.phash2(id, length(@people)))

  @doc "The classes for a person's avatar: their colour as a chip tint, initials in its text colour."
  def person(id), do: id |> person_colour() |> chip()

  defp find(name) do
    Enum.find(@colors, hd(@colors), &(elem(&1, 0) == name))
  end
end
