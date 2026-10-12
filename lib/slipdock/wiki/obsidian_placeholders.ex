defmodule Slipdock.Wiki.ObsidianPlaceholders do
  @moduledoc """
  Obsidian's core template placeholders, understood alongside Slipdock's own
  (W-103 R7.2), so a template written for Obsidian works here unchanged:

    * `{{title}}` — the new page's title
    * `{{date}}` — today, `YYYY-MM-DD`
    * `{{time}}` — now, `HH:mm`
    * `{{date:FORMAT}}`, `{{time:FORMAT}}` — the same, in a Moment.js format,
      as Obsidian writes them: `YYYY YY MMMM MMM MM M DD D dddd ddd HH H hh h
      mm m ss s A a`, and `[literal text]` kept as it is.

  Times are UTC, as Slipdock's own `{{today}}` and `{{now}}` are. Anything
  else in braces is left exactly as written, for Slipdock's placeholders to
  fill or for the reader to see.
  """

  @placeholder ~r/\{\{\s*(title|date|time)(?:\s*:\s*([^}\n]*?))?\s*\}\}/

  @doc """
  Fills the placeholders in `text`. `title` is the new page's title; `now`
  the moment to read the date and time from.
  """
  @spec fill(String.t() | nil, String.t() | nil, DateTime.t()) :: String.t() | nil
  def fill(nil, _title, _now), do: nil

  def fill(text, title, %DateTime{} = now) when is_binary(text) do
    Regex.replace(@placeholder, text, fn whole, name, format ->
      case {name, format} do
        {"title", ""} when is_binary(title) -> title
        {"title", _} -> whole
        {"date", ""} -> format(now, "YYYY-MM-DD")
        {"time", ""} -> format(now, "HH:mm")
        {_, format} -> format(now, format)
      end
    end)
  end

  # Longest tokens first, so `MMMM` is not read as two `MM`s.
  @tokens ~r/\[[^\]]*\]|YYYY|YY|MMMM|MMM|MM|M|DD|D|dddd|ddd|HH|H|hh|h|mm|m|ss|s|A|a/

  @months ~w(January February March April May June July August September October November December)
  @days ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @doc "A date and time in a Moment.js format, the subset Obsidian templates use."
  def format(%DateTime{} = at, format) do
    Regex.replace(@tokens, format, fn token -> token(at, token) end)
  end

  defp token(_at, "[" <> literal), do: String.trim_trailing(literal, "]")
  defp token(at, "YYYY"), do: Integer.to_string(at.year)
  defp token(at, "YY"), do: at.year |> rem(100) |> pad()
  defp token(at, "MMMM"), do: Enum.at(@months, at.month - 1)
  defp token(at, "MMM"), do: @months |> Enum.at(at.month - 1) |> String.slice(0, 3)
  defp token(at, "MM"), do: pad(at.month)
  defp token(at, "M"), do: Integer.to_string(at.month)
  defp token(at, "DD"), do: pad(at.day)
  defp token(at, "D"), do: Integer.to_string(at.day)
  defp token(at, "dddd"), do: Enum.at(@days, Date.day_of_week(at) - 1)
  defp token(at, "ddd"), do: @days |> Enum.at(Date.day_of_week(at) - 1) |> String.slice(0, 3)
  defp token(at, "HH"), do: pad(at.hour)
  defp token(at, "H"), do: Integer.to_string(at.hour)
  defp token(at, "hh"), do: pad(twelve(at.hour))
  defp token(at, "h"), do: Integer.to_string(twelve(at.hour))
  defp token(at, "mm"), do: pad(at.minute)
  defp token(at, "m"), do: Integer.to_string(at.minute)
  defp token(at, "ss"), do: pad(at.second)
  defp token(at, "s"), do: Integer.to_string(at.second)
  defp token(at, "A"), do: if(at.hour < 12, do: "AM", else: "PM")
  defp token(at, "a"), do: if(at.hour < 12, do: "am", else: "pm")

  defp twelve(0), do: 12
  defp twelve(hour) when hour > 12, do: hour - 12
  defp twelve(hour), do: hour

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
