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

  def names, do: Enum.map(@colors, &elem(&1, 0))

  def all, do: Enum.map(@colors, fn {n, l, _, _, _, _} -> {n, l} end)

  def label(name), do: find(name) |> elem(1)
  def dot(name), do: find(name) |> elem(2)
  def chip(name), do: find(name) |> elem(3)
  def border(name), do: find(name) |> elem(4)
  def gradient(name), do: find(name) |> elem(5)

  defp find(name) do
    Enum.find(@colors, hd(@colors), &(elem(&1, 0) == name))
  end
end
