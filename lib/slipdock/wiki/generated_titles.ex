defmodule Slipdock.Wiki.GeneratedTitles do
  @moduledoc """
  Titles for what processes write in numbers (W-2201 §Names): distinct,
  short, and saying nothing the folder already says. Pure, so a migration can
  call them as readily as the code that writes the pages.
  """

  alias Slipdock.Wiki.DiskName

  @pass_log ~r/\A\s*pass log\s+#?(\d+)(?=[\s:\-–—]|\z)(.*)\z/isu
  @stamp ~r/\((\d{4}-\d{2}-\d{2})(?:[ T](\d{2})[:.\-](\d{2})(?:[:.\-]\d{2})?)?\)\s*\z/u

  @fired_part 80

  @doc """
  The title a page written as a pass log has now, from the one it had, as
  the page's title or as its name on disk: `Pass <n> (<YYYY-MM-DD HH.MM>)`,
  with no time or no date when it had none. Nil for anything else, a title
  already in the new form among them, so running it twice changes nothing.

      iex> pass_log("Pass log #1004: Allow archived cards (2026-10-16 16:33)")
      "Pass 1004 (2026-10-16 16.33)"
      iex> pass_log("Pass log #775- Fix it (2026-10-18)")
      "Pass 775 (2026-10-18)"
      iex> pass_log("Pass log #775: Fix it")
      "Pass 775"
      iex> pass_log("Release notes")
      nil
  """
  def pass_log(title) when is_binary(title) do
    case Regex.run(@pass_log, title, capture: :all_but_first) do
      [n, rest] -> "Pass #{n}" <> stamp(rest)
      nil -> nil
    end
  end

  def pass_log(_title), do: nil

  defp stamp(rest) do
    case Regex.run(@stamp, rest, capture: :all_but_first) do
      [date, hours, minutes] -> " (#{date} #{hours}.#{minutes})"
      [date] -> " (#{date})"
      nil -> ""
    end
  end

  @doc """
  What an automation calls what it makes when its rule gave no title:
  `<rule>: <card> <YYYY-MM-DD>`, or `<rule> <YYYY-MM-DD>` with no card to
  speak of. `card` is the triggering card's short name or title.
  """
  def fired(rule, card, %Date{} = date) do
    rule =
      case String.trim(to_string(rule)) do
        "" -> "Automation"
        name -> DiskName.shorten(name, @fired_part)
      end

    case String.trim(to_string(card)) do
      "" -> "#{rule} #{date}"
      name -> "#{rule}: #{DiskName.shorten(name, @fired_part)} #{date}"
    end
  end
end
