defmodule Slipdock.QuickAdd do
  @moduledoc """
  Parses the one-line "type and press Enter" card syntax used by the quick
  add rows: the title with commands mixed in.

      Write the launch post due: tomorrow start: today #high #todo #docs @dan

    * `due: <date>` / `start: <date>` – today, tomorrow, mon…sun (the next
      one), next week/month, next monday, in 3 days / 2 weeks, +3d / +2w,
      eow / eom, 2026-10-01, 1 oct, oct 1, 1/10
    * `#word` – a priority (low, medium, high, critical), a flag (flagged,
      blocked, review, waiting, starred), a list on the board (`#todo` is
      "To Do", `#in-progress` is "In Progress") or a tag, in that order
    * `@name` – an assignee, by name or email prefix
    * `; <text>` – everything after the first semicolon is a comment on the
      new card, taken as written (commands in it are not read)

  `parse/3` returns what was recognised; nothing is written.
  """

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Column, Tag}

  @type result :: %{
          title: String.t(),
          attrs: map,
          column: Column.t() | nil,
          tags: [Tag.t()],
          assignee: User.t() | nil,
          comment: String.t() | nil,
          unknown: [String.t()],
          chips: [{atom, String.t()}]
        }

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @weekdays ~w(mon tue wed thu fri sat sun)

  @date_phrase ~S"""
  \d{4}-\d{2}-\d{2}
  |\d{1,2}[/.]\d{1,2}(?:[/.]\d{2,4})?
  |\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*(?:\s+\d{4})?
  |(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2}(?:st|nd|rd|th)?(?:\s+\d{4})?
  |today|tod|tomorrow|tom|tmrw|yesterday
  |next\s+(?:week|month|mon|tue|wed|thu|fri|sat|sun)[a-z]*
  |(?:this\s+)?(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*
  |in\s+\d+\s*(?:d|days?|w|weeks?|m|months?)
  |\+\d+\s*(?:d|w|m)?
  |eow|eom|none|clear
  """

  @date_regex Regex.compile!(
                "(?<![\\w#@])(due|start|by|from)\\s*:?\\s*(" <>
                  String.replace(@date_phrase, ~r/\s*\n\s*/, "") <> ")(?![\\w-])",
                "i"
              )

  @doc """
  Parses `text` against `board` (its columns and tags). Options: `:today`,
  `:users` (who `@name` may name), `:columns` (override the lists `#word`
  resolves against, e.g. a sub-board's).
  """
  @spec parse(String.t(), map, keyword) :: result
  def parse(text, board, opts \\ []) do
    today = opts[:today] || Date.utc_today()
    columns = opts[:columns] || Map.get(board, :columns) || []
    tags = if is_list(Map.get(board, :tags)), do: board.tags, else: []
    users = opts[:users] || []
    {text, comment} = split_comment(text)

    acc = %{
      attrs: %{},
      column: nil,
      tags: [],
      assignee: nil,
      comment: comment,
      unknown: [],
      chips: []
    }

    {text, acc} = take_dates(text, acc, today)
    {text, acc} = take_mentions(text, acc, users)
    {text, acc} = take_hashes(text, acc, columns, tags)
    acc = if comment, do: chip(acc, :comment, "Comment"), else: acc

    Map.put(acc, :title, text |> String.replace(~r/\s+/, " ") |> String.trim())
  end

  @doc "Whether the text contains anything beyond a plain title."
  def commands?(%{attrs: attrs, column: col, tags: tags, assignee: a, unknown: u} = parsed),
    do:
      attrs != %{} or not is_nil(col) or tags != [] or not is_nil(a) or u != [] or
        not is_nil(parsed[:comment])

  @doc """
  Splits a line at its first semicolon: `{title, comment}`, the comment nil
  when there is nothing after it.
  """
  @spec split_comment(String.t()) :: {String.t(), String.t() | nil}
  def split_comment(text) do
    case String.split(text, ";", parts: 2) do
      [title, comment] ->
        case String.trim(comment) do
          "" -> {title, nil}
          comment -> {title, comment}
        end

      [title] ->
        {title, nil}
    end
  end

  ## Dates ------------------------------------------------------------------

  defp take_dates(text, acc, today) do
    Regex.scan(@date_regex, text)
    |> Enum.reduce({text, acc}, fn [whole, key, phrase], {text, acc} ->
      field = if String.downcase(key) in ["due", "by"], do: "due_date", else: "start_date"

      case parse_date(String.downcase(phrase), today) do
        {:ok, nil} ->
          {String.replace(text, whole, " ", global: false),
           acc
           |> put_attr(field, nil)
           |> chip(:date, "#{label(field)}: none")}

        {:ok, date} ->
          {String.replace(text, whole, " ", global: false),
           acc
           |> put_attr(field, Date.to_iso8601(date))
           |> chip(:date, "#{label(field)} #{Calendar.strftime(date, "%a %-d %b")}")}

        :error ->
          {text, acc}
      end
    end)
  end

  defp label("due_date"), do: "Due"
  defp label("start_date"), do: "Start"

  @doc "Resolves a date phrase (see the moduledoc) relative to `today`."
  @spec parse_date(String.t(), Date.t()) :: {:ok, Date.t() | nil} | :error
  def parse_date(phrase, today) do
    phrase = phrase |> String.downcase() |> String.trim()

    cond do
      phrase in ["none", "clear"] -> {:ok, nil}
      phrase in ["today", "tod"] -> {:ok, today}
      phrase in ["tomorrow", "tom", "tmrw"] -> {:ok, Date.add(today, 1)}
      phrase == "yesterday" -> {:ok, Date.add(today, -1)}
      phrase == "eow" -> {:ok, Date.end_of_week(today)}
      phrase == "eom" -> {:ok, Date.end_of_month(today)}
      phrase == "next week" -> {:ok, Date.add(Date.beginning_of_week(today), 7)}
      phrase == "next month" -> {:ok, Date.beginning_of_month(Date.shift(today, month: 1))}
      true -> parse_date_forms(phrase, today)
    end
  end

  defp parse_date_forms(phrase, today) do
    cond do
      m = Regex.run(~r/^next\s+([a-z]+)$/, phrase) ->
        [_, day] = m
        weekday(day, today, :next)

      m = Regex.run(~r/^(?:this\s+)?([a-z]+)$/, phrase) ->
        [_, day] = m
        weekday(day, today, :this)

      m = Regex.run(~r/^in\s+(\d+)\s*([a-z]+)$/, phrase) ->
        [_, n, unit] = m
        {:ok, add_unit(today, String.to_integer(n), unit)}

      m = Regex.run(~r/^\+(\d+)\s*([a-z]*)$/, phrase) ->
        [_, n, unit] = m
        {:ok, add_unit(today, String.to_integer(n), if(unit == "", do: "d", else: unit))}

      m = Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})$/, phrase) ->
        [_, y, mo, d] = m
        new_date(y, mo, d)

      m = Regex.run(~r/^(\d{1,2})[\/.](\d{1,2})(?:[\/.](\d{2,4}))?$/, phrase) ->
        [_, d, mo | rest] = m
        year = year_from(List.first(rest), today)
        upcoming(year, String.to_integer(mo), String.to_integer(d), today, rest != [])

      m = Regex.run(~r/^(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)(?:\s+(\d{4}))?$/, phrase) ->
        [_, d, mon | rest] = m
        month_day(mon, d, List.first(rest), today)

      m = Regex.run(~r/^([a-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+(\d{4}))?$/, phrase) ->
        [_, mon, d | rest] = m
        month_day(mon, d, List.first(rest), today)

      true ->
        :error
    end
  end

  defp weekday(name, today, which) do
    case Enum.find_index(@weekdays, &String.starts_with?(name, &1)) do
      nil ->
        :error

      idx ->
        wanted = idx + 1
        current = Date.day_of_week(today)
        ahead = rem(wanted - current + 7, 7)
        # "friday" is the coming Friday (today if it is Friday); "next friday"
        # is the same day unless that is today, then it is a week away.
        days = if which == :next and ahead == 0, do: 7, else: ahead
        {:ok, Date.add(today, days)}
    end
  end

  defp add_unit(today, n, unit) do
    cond do
      String.starts_with?(unit, "w") -> Date.add(today, 7 * n)
      String.starts_with?(unit, "m") -> Date.shift(today, month: n)
      true -> Date.add(today, n)
    end
  end

  defp month_day(mon, d, year, today) do
    case Enum.find_index(@months, &String.starts_with?(mon, &1)) do
      nil ->
        :error

      idx ->
        upcoming(year_from(year, today), idx + 1, String.to_integer(d), today, not is_nil(year))
    end
  end

  # A day and month without a year mean the next such date, this year or next.
  defp upcoming(year, month, day, today, explicit_year?) do
    case Date.new(year, month, day) do
      {:ok, date} ->
        if not explicit_year? and Date.compare(date, today) == :lt,
          do: Date.new(year + 1, month, day),
          else: {:ok, date}

      _ ->
        :error
    end
  end

  defp year_from(nil, today), do: today.year
  defp year_from(y, _today) when byte_size(y) == 2, do: 2000 + String.to_integer(y)
  defp year_from(y, _today), do: String.to_integer(y)

  defp new_date(y, mo, d) do
    case Date.new(String.to_integer(y), String.to_integer(mo), String.to_integer(d)) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  ## @mentions ---------------------------------------------------------------

  defp take_mentions(text, acc, users) do
    Regex.scan(~r/(?<!\w)@([\w.-]+)/, text)
    |> Enum.reduce({text, acc}, fn [whole, name], {text, acc} ->
      case find_user(name, users) do
        nil ->
          {text, acc}

        user ->
          # Each @name goes on the card; the first is the lead, which is
          # also all a page — with its one assignee — takes.
          ids = Enum.uniq((acc.attrs["assignee_ids"] || []) ++ [user.id])

          {String.replace(text, whole, " ", global: false),
           acc
           |> put_attr("assignee_id", List.first(ids))
           |> put_attr("assignee_ids", ids)
           |> Map.update(:assignee, user, &(&1 || user))
           |> chip(:assignee, User.display_name(user))}
      end
    end)
  end

  @doc """
  Finds the user `ref` names: an email, a display name, or the start of
  either. Shared with `Slipdock.QuickAdd.Capture`, which resolves the names a
  model comes back with the same way.
  """
  def find_user(ref, users) do
    r = String.downcase(ref)

    Enum.find(users, fn u ->
      String.downcase(u.email) == r or norm(User.display_name(u)) == norm(r)
    end) ||
      Enum.find(users, fn u ->
        String.starts_with?(String.downcase(u.email), r) or
          String.starts_with?(norm(User.display_name(u)), norm(r)) or
          Enum.any?(
            String.split(String.downcase(User.display_name(u))),
            &String.starts_with?(&1, r)
          )
      end)
  end

  ## #commands ---------------------------------------------------------------

  defp take_hashes(text, acc, columns, tags) do
    Regex.scan(~r/(?<![\w&])#([\w-]+)/, text)
    |> Enum.reduce({text, acc}, fn [whole, word], {text, acc} ->
      key = String.downcase(word)

      resolved =
        cond do
          key in Card.priorities() ->
            acc |> put_attr("priority", key) |> chip(:priority, key)

          key in Card.flags() ->
            flags = Enum.uniq(Map.get(acc.attrs, "flags", []) ++ [key])
            acc |> put_attr("flags", flags) |> chip(:flag, key)

          column = Enum.find(columns, &(norm(&1.name) == norm(key))) ->
            acc |> Map.put(:column, column) |> chip(:column, column.name)

          tag = Enum.find(tags, &(norm(&1.name) == norm(key))) ->
            acc |> Map.update!(:tags, &Enum.uniq(&1 ++ [tag])) |> chip(:tag, tag.name)

          true ->
            nil
        end

      case resolved do
        nil -> {text, Map.update!(acc, :unknown, &Enum.uniq(&1 ++ [whole]))}
        acc -> {String.replace(text, whole, " ", global: false), acc}
      end
    end)
  end

  defp norm(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp put_attr(acc, key, value), do: Map.update!(acc, :attrs, &Map.put(&1, key, value))
  defp chip(acc, kind, text), do: Map.update!(acc, :chips, &(&1 ++ [{kind, text}]))
end
