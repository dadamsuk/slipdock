defmodule Slipdock.Filters do
  @moduledoc """
  The board toolbar's filters — text, kind, tags, priority, flag, due, stuck,
  driver, origin (#2778), custom fields (#3369), hide completed — and what
  they match. `stuck` and `driver` read
  the card's `state` (`Slipdock.CardState`), which a page never has.

  `matches?/2` reads the thing by shape rather than by struct, so it takes a
  card or a wiki page: a page carries the same facets under the same names
  (see `Slipdock.Wiki.Page`), which is the whole reason the wiki can offer the
  same filter bar the card views do.
  """

  alias Slipdock.Boards.FieldDefinition

  @empty %{
    q: "",
    kinds: [],
    tags: [],
    priority: nil,
    flag: nil,
    due: nil,
    stuck: false,
    driver: nil,
    origin: nil,
    fields: %{},
    hide_completed: false
  }

  @doc "Filters with nothing set."
  def empty, do: @empty

  @doc "Whether any filter is set."
  def any?(filters), do: filters != @empty

  @doc "How many filters are set, for the badge on the button."
  def count(filters) do
    Enum.count(
      [
        filters.q != "",
        filters.kinds != [],
        filters.tags != [],
        not is_nil(filters.priority),
        not is_nil(filters.flag),
        not is_nil(filters.due),
        filters.stuck,
        not is_nil(filters.driver),
        not is_nil(Map.get(filters, :origin)),
        filters.hide_completed
      ],
      & &1
    ) + map_size(fields_of(filters))
  end

  @doc """
  Whether a card or a page passes the filters.

  `kinds` is the one filter that reads the item's *sort* rather than its
  facets: cards, documents, wiki pages, or any mix (see `Slipdock.Kinds`).
  """
  def matches?(item, filters, today \\ Date.utc_today()) do
    q = String.downcase(filters.q)
    tags = tags_of(item)

    Slipdock.Kinds.matches?(item, filters.kinds) and
      (q == "" or
         named?(item, q) or
         String.contains?(String.downcase(item.title), q) or
         String.contains?(String.downcase(text_of(item)), q) or
         Enum.any?(tags, &String.contains?(String.downcase(&1.name), q))) and
      (filters.tags == [] or Enum.any?(tags, &Enum.member?(filters.tags, &1.id))) and
      (is_nil(filters.priority) or item.priority == filters.priority) and
      (is_nil(filters.flag) or Enum.member?(item.flags, filters.flag)) and
      due_matches?(filters.due, item, today) and
      made_and_moved?(item, filters) and
      not (filters.hide_completed and item.completed)
  end

  # Its state (stuck, driver) and its origin (#2778): one helper, so
  # `matches?/3` takes no new branch.
  defp made_and_moved?(item, filters) do
    Slipdock.CardState.matches?(item, filters.stuck, filters.driver) and
      origin_matches?(item, Map.get(filters, :origin)) and
      Enum.all?(fields_of(filters), fn {_id, condition} -> field_matches?(item, condition) end)
  end

  defp fields_of(filters), do: Map.get(filters, :fields) || %{}

  ## Custom fields (#3369) ----------------------------------------------------

  @doc """
  The filters with the condition on custom `field` set from a control's
  `params`, read by the field's kind; a condition left empty is dropped.

    * `select`: `"option"` toggles that option in or out (any of them passes)
    * `rating`: `"min"`, at least that many stars; the same again clears it
    * `number`, `formula`: `"min"` and `"max"`, either or both
    * `date`: `"from"` and `"to"` (ISO dates), either or both
    * `text`: `"text"`, words the value contains, in any case

  An item with no value for the field fails any condition on it.
  """
  def put_field(filters, %FieldDefinition{id: id} = field, params) when is_map(params) do
    current = Map.get(fields_of(filters), id)

    condition =
      field
      |> condition(current, params)
      |> then(&if(empty_condition?(&1), do: nil, else: Map.put(&1, :field, field)))

    fields =
      if condition,
        do: Map.put(fields_of(filters), id, condition),
        else: Map.delete(fields_of(filters), id)

    Map.put(filters, :fields, fields)
  end

  @doc "The condition set on `field`, or nil."
  def field_condition(filters, %FieldDefinition{id: id}), do: Map.get(fields_of(filters), id)

  defp condition(%FieldDefinition{kind: "select"} = field, current, %{"option" => key}) do
    options = (current && current.options) || []
    known? = Enum.any?(field.options, &(&1["key"] == key))

    cond do
      Enum.member?(options, key) -> %{options: List.delete(options, key)}
      known? -> %{options: options ++ [key]}
      true -> %{options: options}
    end
  end

  defp condition(%FieldDefinition{kind: "rating"} = field, current, %{"min" => min}) do
    case parse_number(min) do
      n when is_number(n) and n >= 1 ->
        n = min(round(n), FieldDefinition.rating_max(field))
        if current && current.min == n, do: %{min: nil}, else: %{min: n}

      _ ->
        %{min: nil}
    end
  end

  defp condition(%FieldDefinition{kind: kind}, _current, params)
       when kind in ~w(number formula),
       do: %{min: parse_number(params["min"]), max: parse_number(params["max"])}

  defp condition(%FieldDefinition{kind: "date"}, _current, params),
    do: %{from: parse_date(params["from"]), to: parse_date(params["to"])}

  defp condition(%FieldDefinition{kind: "text"}, _current, params),
    do: %{text: String.trim(to_string(params["text"] || ""))}

  defp condition(_field, current, _params), do: current || %{}

  defp empty_condition?(condition) do
    condition
    |> Map.delete(:field)
    |> Enum.all?(fn {_k, v} -> Enum.member?([nil, "", []], v) end)
  end

  defp field_matches?(item, %{field: field} = condition) do
    value = Slipdock.Fields.value(item, field)
    not is_nil(value) and value_matches?(field.kind, value, condition)
  end

  defp value_matches?("select", key, %{options: options}), do: Enum.member?(options, key)

  defp value_matches?("rating", n, %{min: min}) when is_number(n), do: n >= min

  defp value_matches?(kind, n, condition) when kind in ~w(number formula) and is_number(n),
    do: within?(n, condition.min, condition.max, &(&1 >= &2), &(&1 <= &2))

  defp value_matches?("date", %Date{} = d, condition),
    do:
      within?(d, condition.from, condition.to, &(Date.compare(&1, &2) != :lt), fn a, b ->
        Date.compare(a, b) != :gt
      end)

  defp value_matches?("text", text, %{text: words}) when is_binary(text),
    do: String.contains?(String.downcase(text), String.downcase(words))

  defp value_matches?(_kind, _value, _condition), do: false

  defp within?(value, low, high, at_least, at_most),
    do: (is_nil(low) or at_least.(value, low)) and (is_nil(high) or at_most.(value, high))

  defp parse_number(n) when is_number(n), do: n

  defp parse_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp parse_number(_), do: nil

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(String.trim(s)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  # Who or what made it (#2778): "none" for an item with no origin, which a
  # page always is.
  defp origin_matches?(_item, nil), do: true
  defp origin_matches?(item, "none"), do: is_nil(Map.get(item, :origin))
  defp origin_matches?(item, origin), do: Map.get(item, :origin) == origin

  # A card's description and a page's summary are the same line to a reader
  # searching for a word; `Page.for_board/1` fills `description` in from the
  # summary, and the raw page falls back to it here.
  defp text_of(%{description: text}) when is_binary(text), do: text
  defp text_of(%{summary: text}) when is_binary(text), do: text
  defp text_of(_), do: ""

  # A page answers to its code (`W-31`) as well as its words: typed whole, it
  # finds that page and no other.
  defp code_of(%{code: code}) when is_binary(code), do: String.downcase(code)
  defp code_of(_), do: nil

  # Typed whole, a page's code names that page and a card's id that card.
  defp named?(item, q), do: code_of(item) == String.trim(q) or names_card?(item, q)

  @doc """
  Whether `q` names `item` by its id (`123`, `#123`) or its link
  (`Slipdock.Boards.Links.card_ref/1`). A card answers to its id as well as its
  words, so the search box finds a card by the number it is known by (#2097).
  Only a card: a page is named by its code, and its id is nobody's to type.
  """
  def names_card?(%Slipdock.Boards.Card{id: id}, q) when is_integer(id),
    do: Slipdock.Boards.Links.card_ref(q) == id

  def names_card?(_item, _q), do: false

  defp tags_of(%{tags: tags}) when is_list(tags), do: tags
  defp tags_of(_), do: []

  defp due_matches?(nil, _item, _today), do: true
  defp due_matches?("none", item, _today), do: is_nil(item.due_date)

  defp due_matches?("overdue", %{due_date: %Date{} = d, completed: false}, today),
    do: Date.before?(d, today)

  defp due_matches?("overdue", _item, _today), do: false

  defp due_matches?("week", %{due_date: %Date{} = d, completed: false}, today),
    do: Date.diff(d, today) <= 7

  defp due_matches?("week", _item, _today), do: false
  defp due_matches?(_other, _item, _today), do: true
end
