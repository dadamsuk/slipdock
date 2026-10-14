defmodule Slipdock.Wiki.Icons do
  @moduledoc """
  The icons a wiki folder or page can wear in place of its plain one (#792),
  and the classes that draw them.

  A curated set of the app's own Heroicons rather than any name at all, so
  every one of them is in the stylesheet: Tailwind only builds the classes it
  can find written out, which is why each is spelt in full here and why
  `assets/css/app.css` reads this file. Stored without the `hero-` prefix.

  The colour that goes with an icon is a `Slipdock.Palette` name, which tints
  the icon and the name beside it.
  """

  @icons [
    {"star", "hero-star"},
    {"heart", "hero-heart"},
    {"bookmark", "hero-bookmark"},
    {"flag", "hero-flag"},
    {"bolt", "hero-bolt"},
    {"fire", "hero-fire"},
    {"light-bulb", "hero-light-bulb"},
    {"sparkles", "hero-sparkles"},
    {"rocket-launch", "hero-rocket-launch"},
    {"beaker", "hero-beaker"},
    {"book-open", "hero-book-open"},
    {"academic-cap", "hero-academic-cap"},
    {"briefcase", "hero-briefcase"},
    {"calendar", "hero-calendar"},
    {"chat-bubble-left-right", "hero-chat-bubble-left-right"},
    {"check-circle", "hero-check-circle"},
    {"clipboard-document-list", "hero-clipboard-document-list"},
    {"code-bracket", "hero-code-bracket"},
    {"cog-6-tooth", "hero-cog-6-tooth"},
    {"cube", "hero-cube"},
    {"currency-dollar", "hero-currency-dollar"},
    {"document-text", "hero-document-text"},
    {"exclamation-triangle", "hero-exclamation-triangle"},
    {"globe-alt", "hero-globe-alt"},
    {"home", "hero-home"},
    {"inbox", "hero-inbox"},
    {"key", "hero-key"},
    {"lock-closed", "hero-lock-closed"},
    {"map", "hero-map"},
    {"megaphone", "hero-megaphone"},
    {"musical-note", "hero-musical-note"},
    {"photo", "hero-photo"},
    {"puzzle-piece", "hero-puzzle-piece"},
    {"shield-check", "hero-shield-check"},
    {"tag", "hero-tag"},
    {"trophy", "hero-trophy"},
    {"user-group", "hero-user-group"},
    {"wrench-screwdriver", "hero-wrench-screwdriver"},
    {"archive-box", "hero-archive-box"},
    {"folder", "hero-folder"}
  ]

  @doc "Every icon name that may be chosen, in the order a picker shows them."
  def names, do: Enum.map(@icons, &elem(&1, 0))

  @doc "The class that draws `name`, or nil for a name not in the set."
  def class(nil), do: nil

  def class(name) do
    case List.keyfind(@icons, name, 0) do
      {_, class} -> class
      nil -> nil
    end
  end

  @doc """
  The class drawing a folder's or page's icon: its own when it has one, the
  plain one for its kind otherwise.
  """
  def class(icon, :folder), do: class(icon) || "hero-folder"
  def class(icon, :page), do: class(icon) || "hero-document-text"

  @doc "The text colour tinting an icon in `color`, or nil for none."
  def tint(nil), do: nil
  def tint(""), do: nil

  def tint(color) do
    if color in Slipdock.Palette.names(), do: Slipdock.Palette.text(color)
  end

  @doc """
  Checks and tidies a changeset's `icon` and `color`: a blank one is none,
  and anything else has to be in the set.
  """
  def validate(changeset) do
    import Ecto.Changeset

    changeset
    |> update_change(:icon, &blank_to_nil/1)
    |> update_change(:color, &blank_to_nil/1)
    |> validate_inclusion(:icon, names(), message: "is not one of the wiki's icons")
    |> validate_inclusion(:color, Slipdock.Palette.names())
  end

  defp blank_to_nil(value) when value in ["", "none"], do: nil
  defp blank_to_nil(value), do: value
end
