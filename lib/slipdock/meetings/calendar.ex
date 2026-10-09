defmodule Slipdock.Meetings.Calendar do
  @moduledoc """
  The parts of a calendar invite (`.ics`) a capture uses: who was invited
  (the strongest hint at who is speaking), when it started, and what it was
  called. Only the first event in the file is read; anything this does not
  understand is ignored rather than refused, since an invite is a hint, not
  the meeting.
  """

  @doc """
  `%{title:, started_at:, attendees: [%{name:, email:}]}` from an invite's
  text, or `{:error, message}` when there is no event in it at all.
  """
  def parse(content) when is_binary(content) do
    lines =
      content
      |> String.replace_prefix("\uFEFF", "")
      |> String.replace(~r/\r\n?/, "\n")
      # RFC 5545 folds long lines: a line starting with a space or a tab
      # continues the one before it.
      |> String.replace(~r/\n[ \t]/, "")
      |> String.split("\n")

    event =
      lines
      |> Enum.drop_while(&(&1 != "BEGIN:VEVENT"))
      |> Enum.take_while(&(&1 != "END:VEVENT"))

    if event == [] do
      {:error, "the invite has no event in it"}
    else
      props = Enum.map(event, &property/1) |> Enum.reject(&is_nil/1)

      {:ok,
       %{
         title: value(props, "SUMMARY"),
         started_at: props |> find("DTSTART") |> datetime(),
         attendees:
           props
           |> Enum.filter(fn {name, _, _} -> name in ["ATTENDEE", "ORGANIZER"] end)
           |> Enum.map(&attendee/1)
           |> Enum.uniq_by(&(&1.email || &1.name))
       }}
    end
  end

  # "ATTENDEE;CN=Sam Smith;ROLE=REQ-PARTICIPANT:mailto:sam@example.com"
  defp property(line) do
    case String.split(line, ":", parts: 2) do
      [head, value] ->
        [name | params] = String.split(head, ";")

        params =
          Map.new(params, fn param ->
            case String.split(param, "=", parts: 2) do
              [k, v] -> {String.upcase(k), String.trim(v, "\"")}
              [k] -> {String.upcase(k), ""}
            end
          end)

        {String.upcase(name), params, unescape(value)}

      _ ->
        nil
    end
  end

  defp find(props, name), do: Enum.find(props, fn {n, _, _} -> n == name end)

  defp value(props, name) do
    case find(props, name) do
      {_, _, v} -> v
      nil -> nil
    end
  end

  defp attendee({_, params, value}) do
    email =
      case Regex.run(~r/^mailto:(.+)$/i, value) do
        [_, address] -> String.downcase(String.trim(address))
        nil -> nil
      end

    %{name: params["CN"], email: email}
  end

  # 20261007T100000Z (UTC), 20261007T100000 with a TZID (read as UTC: the
  # zone database is not this module's business, and an hour's error in a
  # meeting's start resolves no date wrongly), or a bare date.
  defp datetime(nil), do: nil

  defp datetime({_, _params, value}) do
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/, value) do
      [_, y, m, d | time] ->
        [h, mi, s] =
          case time do
            [h, mi, s] -> [h, mi, s]
            _ -> ["0", "0", "0"]
          end

        with {:ok, date} <- Date.new(int(y), int(m), int(d)),
             {:ok, time} <- Time.new(int(h), int(mi), int(s)),
             {:ok, dt} <- DateTime.new(date, time) do
          dt
        else
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp int(s), do: String.to_integer(s)

  defp unescape(value) do
    value
    |> String.replace("\\n", " ")
    |> String.replace("\\N", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\;", ";")
    |> String.replace("\\\\", "\\")
  end
end
