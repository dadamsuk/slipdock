defmodule Slipdock.Fields do
  @moduledoc """
  Custom fields on a board tree: their definitions, the values cards hold,
  formulas computed from those values, and the RICE / ICE / value-effort
  presets that set a scoring scheme up in one go.

  Values are read from a card's preloaded `field_values`; formula results
  live in the card's virtual `computed` map (field id to number), filled by
  `decorate/2` for a board's cards at once, since a weighted score
  normalises each input across the whole board. `computed` holds each
  checkbox too, as 1.0 or 0.0, so an empty one reads as off.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, FieldDefinition, FieldValue, Owned}
  alias Slipdock.Wiki.Page
  alias Slipdock.Fields.{Expression, People}
  alias Slipdock.Policy
  alias Slipdock.Repo

  @presets [
    %{
      key: "rice",
      name: "RICE",
      blurb: "Reach × Impact × Confidence ÷ Effort",
      inputs: [
        %{key: "reach", name: "Reach", kind: "number", config: %{"min" => 0, "unit" => "people"}},
        %{key: "impact", name: "Impact", kind: "rating", config: %{"max" => 5}},
        %{
          key: "confidence",
          name: "Confidence",
          kind: "number",
          config: %{"min" => 0, "max" => 100, "unit" => "%"}
        },
        %{
          key: "effort",
          name: "Effort",
          kind: "number",
          config: %{"min" => 0.5, "unit" => "weeks"}
        }
      ],
      expression: "{reach} * {impact} * ({confidence} / 100) / {effort}"
    },
    %{
      key: "ice",
      name: "ICE",
      blurb: "Impact × Confidence × Ease, each 1–10",
      inputs: [
        %{key: "impact", name: "Impact", kind: "rating", config: %{"max" => 10}},
        %{key: "confidence", name: "Confidence", kind: "rating", config: %{"max" => 10}},
        %{key: "ease", name: "Ease", kind: "rating", config: %{"max" => 10}}
      ],
      expression: "{impact} * {confidence} * {ease}"
    },
    %{
      key: "value_effort",
      name: "Value ÷ Effort",
      blurb: "Value and effort on 1–5, and the matrix on swimlanes",
      inputs: [
        %{key: "value", name: "Value", kind: "rating", config: %{"max" => 5}},
        %{key: "effort", name: "Effort", kind: "rating", config: %{"max" => 5}}
      ],
      expression: "{value} / {effort}"
    }
  ]

  # Built-in numeric references a formula may use besides custom fields.
  @builtin_refs [{"votes", "Votes"}, {"subcards", "Subcards (leaves)"}, {"done", "Subcards done"}]

  def presets, do: @presets
  def builtin_refs, do: @builtin_refs

  ## Definitions ----------------------------------------------------------------

  @doc "The fields of the tree rooted at `root_id`, in position order."
  def list_fields(root_id) do
    Repo.all(
      from(f in FieldDefinition,
        where: f.board_id == ^root_id,
        order_by: [asc: f.position, asc: f.id]
      )
    )
  end

  @doc """
  The field `id` if it is on the tree rooted at `root_id`, or nil: for ids a
  client sent.
  """
  def get_board_field(root_id, id) do
    case Slipdock.Boards.Shared.to_id(id) do
      nil -> nil
      id -> Repo.one(from(f in FieldDefinition, where: f.id == ^id and f.board_id == ^root_id))
    end
  end

  @doc "Finds a field on the tree by id or key/name (case-insensitive)."
  def find_field(fields, ref) when is_list(fields) do
    ref = to_string(ref) |> String.trim()
    down = String.downcase(ref)

    Enum.find(fields, fn f ->
      to_string(f.id) == ref or f.key == down or String.downcase(f.name) == down
    end)
  end

  @doc """
  Adds a field to `board`'s tree. Fields are the tree's, kept on its root,
  so every change to one asks write on the root (`Slipdock.Policy`,
  `:edit_field`), as tags do (#2751).
  """
  def create_field(%Board{} = board, attrs) do
    with :ok <- Policy.authorize(:edit_field, board), do: insert_field(board, attrs)
  end

  defp insert_field(board, attrs) do
    root_id = Board.root_id(board)

    position =
      Repo.one(from(f in FieldDefinition, where: f.board_id == ^root_id, select: max(f.position))) ||
        -1

    %FieldDefinition{board_id: root_id, position: position + 1}
    |> FieldDefinition.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn _ -> Slipdock.Boards.PubSub.broadcast_tree(root_id) end)
  end

  @doc """
  Changes a field. Switching a choice field's Allow several (#3611) on turns
  each value into a list of one; switching it off keeps each card's (and
  page's) first option in the field's option order. Board settings asks
  first when a card holds several (`several_held?/1`); this doesn't.
  """
  def update_field(%FieldDefinition{} = field, attrs) do
    with :ok <- Policy.authorize(:edit_field, field), do: save_field(field, attrs)
  end

  defp save_field(field, attrs) do
    Repo.transaction(fn ->
      case field |> FieldDefinition.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          reshape_values(field, updated)
          updated

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
    |> tap_ok(fn f -> Slipdock.Boards.PubSub.broadcast_tree(f.board_id) end)
  end

  # The values of a choice field moved to the column its new shape reads:
  # `options` when it allows several, `option` when it holds one.
  defp reshape_values(old, new) do
    case {FieldDefinition.several?(old), FieldDefinition.several?(new)} do
      {false, true} ->
        from(v in FieldValue,
          where: v.field_id == ^new.id and not is_nil(v.option),
          update: [set: [options: fragment("ARRAY[?]::varchar[]", v.option), option: nil]]
        )
        |> Repo.update_all([])

      {true, false} ->
        to_single(new)

      _ ->
        :ok
    end
  end

  # Each value keeps its first option in the field's option order; an option
  # the field no longer has goes after the ones it has.
  defp to_single(field) do
    from(v in FieldValue, where: v.field_id == ^field.id and not is_nil(v.options))
    |> Repo.all()
    |> Enum.group_by(fn v -> first_option(field, v.options) end, & &1.id)
    |> Enum.each(fn {key, ids} ->
      Repo.update_all(from(v in FieldValue, where: v.id in ^ids),
        set: [option: key, options: nil]
      )
    end)
  end

  defp first_option(field, keys) do
    keys
    |> Enum.sort_by(&(FieldDefinition.option_index(field, &1) || length(field.options)))
    |> List.first()
  end

  @doc """
  Whether any card or page holds more than one option of `field`, so
  switching its Allow several off would drop some (#3611).
  """
  def several_held?(%FieldDefinition{id: id}) do
    Repo.exists?(
      from(v in FieldValue,
        where: v.field_id == ^id and fragment("cardinality(?) > 1", v.options)
      )
    )
  end

  def delete_field(%FieldDefinition{} = field) do
    with :ok <- Policy.authorize(:edit_field, field), do: drop_field(field)
  end

  defp drop_field(field) do
    Repo.delete(field)
    |> tap_ok(fn f -> Slipdock.Boards.PubSub.broadcast_tree(f.board_id) end)
  end

  @doc """
  Sets a preset up on the tree: creates each input field that isn't there
  yet (matched by key) and the formula field. Returns the formula field.
  """
  def install_preset(%Board{} = board, key) do
    with :ok <- Policy.authorize(:edit_field, board), do: install(board, key)
  end

  defp install(board, key) do
    case Enum.find(@presets, &(&1.key == key)) do
      nil ->
        {:error, :unknown_preset}

      preset ->
        root_id = Board.root_id(board)
        existing = list_fields(root_id)

        preset.inputs
        |> Enum.reject(fn input -> Enum.any?(existing, &(&1.key == input.key)) end)
        |> Enum.each(&({:ok, _} = create_input(board, &1)))

        case Enum.find(existing, &(&1.key == preset.key)) do
          nil ->
            create_field(board, %{
              "name" => preset.name,
              "key" => preset.key,
              "kind" => "formula",
              "config" => %{"mode" => "expression", "expression" => preset.expression}
            })

          field ->
            {:ok, field}
        end
    end
  end

  defp create_input(board, input) do
    create_field(board, %{
      "name" => input.name,
      "key" => input.key,
      "kind" => input.kind,
      "config" => input.config
    })
  end

  ## Values ---------------------------------------------------------------------

  @doc """
  The stored value for `field` (number, option key, date or text), or nil.
  A choice field that allows several gives the list of its option keys, in
  the field's option order (#3611).

  Takes a card or a wiki page: a page carries the board's custom fields too,
  in the same table (see `Slipdock.Boards.Owned`), so these match on shape.
  """
  def value(%{computed: computed}, %FieldDefinition{kind: "formula", id: id}),
    do: Map.get(computed || %{}, id)

  def value(%{field_values: values}, %FieldDefinition{id: id} = field) when is_list(values) do
    case Enum.find(values, &(&1.field_id == id)) do
      nil -> nil
      v -> shaped(field, FieldValue.get(v))
    end
  end

  def value(_, _), do: nil

  # A value read in the shape its field has now: a card moved from another
  # tree may bring one option to a field that allows several, or several to
  # one that holds one.
  defp shaped(%FieldDefinition{kind: "select"} = field, value) do
    case {FieldDefinition.several?(field), value} do
      {true, key} when is_binary(key) -> [key]
      {false, [first | _]} -> first
      _ -> value
    end
  end

  defp shaped(_field, value), do: value

  @doc "The value for `field` as a number: numbers and ratings as they are, options by weight."
  # Several options are the sum of their weights (#3611); nil when none has one.
  def numeric(card, %FieldDefinition{kind: "select"} = field) do
    case value(card, field) do
      nil ->
        nil

      keys when is_list(keys) ->
        case keys
             |> Enum.map(&FieldDefinition.option_weight(field, &1))
             |> Enum.reject(&is_nil/1) do
          [] -> nil
          weights -> Enum.sum(weights)
        end

      key ->
        FieldDefinition.option_weight(field, key)
    end
  end

  # A checkbox is 1 when on and 0 otherwise: an empty one counts as off.
  def numeric(card, %FieldDefinition{kind: "checkbox"} = field),
    do: if(value(card, field) == 1.0, do: 1.0, else: 0.0)

  def numeric(card, %FieldDefinition{kind: kind} = field)
      when kind in ~w(number rating formula) do
    case value(card, field) do
      n when is_number(n) -> n * 1.0
      _ -> nil
    end
  end

  def numeric(_, _), do: nil

  @doc "A value shown as text."
  def format(_field, nil), do: nil

  # Several options are their labels, in option order (#3611).
  def format(%FieldDefinition{kind: "select"}, []), do: nil

  def format(%FieldDefinition{kind: "select"} = field, keys) when is_list(keys),
    do: Enum.map_join(keys, ", ", &FieldDefinition.option_label(field, &1))

  def format(%FieldDefinition{kind: "select"} = field, key),
    do: FieldDefinition.option_label(field, key)

  # A person field's people by name, a former member marked (#3614).
  def format(%FieldDefinition{kind: "person"} = field, ids) when is_list(ids) do
    case People.people(field, ids) do
      [] -> nil
      people -> Enum.map_join(people, ", ", &People.label/1)
    end
  end

  def format(%FieldDefinition{kind: "rating"}, n) when is_number(n), do: "#{round(n)}"
  def format(%FieldDefinition{kind: "date"}, %Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")
  def format(%FieldDefinition{kind: "text"}, t), do: t
  def format(%FieldDefinition{kind: "url"}, url) when is_binary(url), do: url_host(url)
  # On reads "Yes"; off is shown as nothing, as an empty field is.
  def format(%FieldDefinition{kind: "checkbox"}, n), do: if(n == 1.0, do: "Yes")

  def format(%FieldDefinition{config: config}, n) when is_number(n) do
    text =
      if n == trunc(n),
        do: Integer.to_string(trunc(n)),
        else: :erlang.float_to_binary(n * 1.0, decimals: 2)

    with_unit(text, config["unit"])
  end

  def format(_, other), do: to_string(other)

  # A unit is written after the number with a space ("12 people"), apart
  # from the signs that sit against it: "80%", not "80 %" (#1698).
  defp with_unit(text, unit) when unit in [nil, ""], do: text
  defp with_unit(text, unit), do: if(tight_unit?(unit), do: text <> unit, else: "#{text} #{unit}")

  @doc """
  Whether `unit` is a sign that sits against its number ("80%", "12°"),
  rather than a word written after it with a space ("12 people").
  """
  def tight_unit?(unit), do: Enum.member?(~w(% ‰ ° ′ ″), unit)

  @doc """
  Whether `url` is a link a URL field takes (#3613): http or https, with a
  host, and nothing else (no `javascript:`, `mailto:` or bare words), so a
  stored value is always safe to put in an `href`.
  """
  def web_link?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  def web_link?(_), do: false

  @doc """
  Whether a value written straight to storage, not through `set_value/3`
  (an import), keeps to `field`'s kind: `:ok`, or `{:error, message}` in
  the words a form gets. A URL field's text must be an http(s) link
  (#3613); other kinds have no check here yet.
  """
  def check_stored(%FieldDefinition{kind: "url"} = field, %{text: text}) do
    if is_nil(text) or web_link?(text),
      do: :ok,
      else: {:error, url_refusal(field)}
  end

  # A person field's ids must each be a current member of the tree (#3614):
  # an imported document's people are another tree's.
  def check_stored(%FieldDefinition{kind: "person"} = field, %{options: ids}) when is_list(ids) do
    case People.cast(field, ids, []) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def check_stored(%FieldDefinition{}, _attrs), do: :ok

  defp url_refusal(field),
    do: "#{field.name} needs an http or https link, like https://example.com."

  @doc "A URL field's value as it is shown: its host, without a leading `www.`."
  def url_host(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" ->
        String.replace_prefix(host, "www.", "")

      _ ->
        url
    end
  end

  @doc """
  Stores `raw` (from a form or the API) as the card's — or the page's — value
  for `field`; an empty value clears it. Returns `{:ok, reloaded}`, or
  `{:error, message}`.
  """
  def set_value(_owner, %FieldDefinition{kind: "formula"}, _raw),
    do: {:error, "A formula is computed, not set."}

  def set_value(owner, %FieldDefinition{} = field, raw) do
    with :ok <- Policy.authorize(:set_field_value, owner), do: put_value(owner, field, raw)
  end

  defp put_value(owner, field, raw) do
    case cast_for(owner, field, raw) do
      {:ok, nil} ->
        FieldValue
        |> where(^owner_clause(owner))
        |> where([v], v.field_id == ^field.id)
        |> Repo.delete_all()

        after_set(owner, field, nil)

      {:ok, attrs} ->
        %FieldValue{field_id: field.id}
        |> struct!(Owned.owner_key(owner))
        |> FieldValue.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:number, :text, :date, :option, :options, :updated_at]},
          conflict_target: conflict_target(owner)
        )
        |> case do
          {:ok, _} ->
            after_set(owner, field, attrs)

          {:error, cs} ->
            {:error, "Couldn't save #{field.name}: #{Slipdock.ChangesetErrors.message(cs)}"}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp owner_clause(%Page{id: id}), do: dynamic([v], v.page_id == ^id)
  defp owner_clause(%{id: id}), do: dynamic([v], v.card_id == ^id)

  defp conflict_target(%Page{}), do: [:page_id, :field_id]
  defp conflict_target(_), do: [:card_id, :field_id]

  defp after_set(card, field, attrs) do
    shown = attrs && format(field, attrs |> Map.values() |> Enum.find(&(not is_nil(&1))))

    Slipdock.Boards.ActivityLog.log_activity_for(
      card,
      "card",
      if(shown,
        do: "set #{field.name} on “#{card.title}” to #{shown}",
        else: "cleared #{field.name} on “#{card.title}”"
      )
    )

    Slipdock.Boards.PubSub.broadcast_tree(Slipdock.Boards.root_of_board(card.board_id))
    reload(card)
  end

  defp reload(%Page{id: id}), do: {:ok, Slipdock.Wiki.get_page!(id)}
  defp reload(%Card{id: id}), do: {:ok, Slipdock.Boards.Cards.get_card!(id)}

  # A person field (#3614) reads who the owner holds now: a former member
  # already there may stay, and nobody else who has left may be added.
  defp cast_for(owner, %FieldDefinition{kind: "person"} = field, raw) do
    case People.cast(field, raw, held_ids(owner, field)) do
      {:ok, []} -> {:ok, nil}
      {:ok, ids} -> {:ok, %{options: ids}}
      error -> error
    end
  end

  defp cast_for(_owner, field, raw), do: cast(field, raw)

  defp held_ids(owner, field) do
    FieldValue
    |> where(^owner_clause(owner))
    |> where([v], v.field_id == ^field.id)
    |> select([v], v.options)
    |> Repo.one()
    |> List.wrap()
  end

  # What to store for a raw value, by kind. Empty means "clear".
  defp cast(_field, raw) when raw in [nil, "", []], do: {:ok, nil}

  defp cast(%FieldDefinition{kind: "number", config: config} = field, raw) do
    with {:ok, n} <- number(raw),
         :ok <- within(n, config["min"], config["max"], field.name) do
      {:ok, %{number: n}}
    end
  end

  defp cast(%FieldDefinition{kind: "rating"} = field, raw) do
    max = FieldDefinition.rating_max(field)

    with {:ok, n} <- number(raw),
         :ok <- within(n, 1, max, field.name) do
      {:ok, %{number: round(n) * 1.0}}
    end
  end

  # Allow several (#3611): keys or labels, a list or a comma-separated
  # string, stored in the field's option order without repeats.
  defp cast(%FieldDefinition{kind: "select", config: %{"several" => true}} = field, raw) do
    raw
    |> several_refs(field)
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, keys} ->
      case option_key(field, ref) do
        nil -> {:halt, {:error, "#{field.name} has no option “#{ref}”."}}
        key -> {:cont, {:ok, [key | keys]}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:ok, nil}

      {:ok, keys} ->
        {:ok, %{options: for(o <- field.options, Enum.member?(keys, o["key"]), do: o["key"])}}

      error ->
        error
    end
  end

  # One choice: a list of one is that option, a list of more is refused.
  defp cast(%FieldDefinition{kind: "select"} = field, [one]), do: cast(field, one)

  defp cast(%FieldDefinition{kind: "select"} = field, raw) when is_list(raw),
    do: {:error, "#{field.name} takes one option."}

  defp cast(%FieldDefinition{kind: "select"} = field, raw) do
    key = to_string(raw)

    case option_key(field, key) do
      nil -> {:error, "#{field.name} has no option “#{key}”."}
      key -> {:ok, %{option: key}}
    end
  end

  defp cast(%FieldDefinition{kind: "date"} = field, raw) do
    case raw do
      %Date{} = d ->
        {:ok, %{date: d}}

      s when is_binary(s) ->
        case Date.from_iso8601(String.trim(s)) do
          {:ok, d} -> {:ok, %{date: d}}
          _ -> {:error, "#{field.name} needs a date like 2027-03-31."}
        end

      _ ->
        {:error, "#{field.name} needs a date."}
    end
  end

  defp cast(%FieldDefinition{kind: "text"}, raw), do: {:ok, %{text: String.trim(to_string(raw))}}

  defp cast(%FieldDefinition{kind: "url"} = field, raw) do
    url = raw |> to_string() |> String.trim()

    if web_link?(url),
      do: {:ok, %{text: url}},
      else: {:error, url_refusal(field)}
  end

  # On is stored as 1.0; off clears the value, so off and empty are one.
  defp cast(%FieldDefinition{kind: "checkbox"} = field, raw) do
    case parse_checked(raw) do
      true -> {:ok, %{number: 1.0}}
      false -> {:ok, nil}
      nil -> {:error, "#{field.name} takes true or false."}
    end
  end

  # An option named by its key, or its label in any case; nil when there is none.
  defp option_key(%FieldDefinition{options: options}, ref) do
    ref = String.trim(to_string(ref))
    down = String.downcase(ref)

    case Enum.find(options, &(&1["key"] == ref)) ||
           Enum.find(options, &(String.downcase(&1["label"]) == down)) do
      nil -> nil
      option -> option["key"]
    end
  end

  # The options a raw value names: each of a list's items, or a string's
  # comma-separated parts (unless the whole string is an option, whose label
  # has a comma in it). Blanks, which a form's empty box sends, are dropped.
  defp several_refs(raw, _field) when is_list(raw),
    do: raw |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == ""))

  defp several_refs(raw, field) do
    raw = to_string(raw)

    if option_key(field, raw),
      do: [raw],
      else: raw |> String.split(",") |> several_refs(field)
  end

  @checked_on ~w(true 1 1.0 on yes)
  @checked_off ~w(false 0 0.0 off no)

  @doc """
  Reads a checkbox's raw value: `true` or `false`, from a boolean, the
  numbers 1 and 0, or `"true"`/`"false"`, `"1"`/`"0"` (`"1.0"`/`"0.0"`,
  the keys of its swimlanes), `"on"`/`"off"` or `"yes"`/`"no"` in any case;
  nil for anything else.
  """
  def parse_checked(b) when is_boolean(b), do: b
  def parse_checked(n) when is_number(n) and (n == 1 or n == 0), do: n == 1

  def parse_checked(s) when is_binary(s) do
    word = s |> String.trim() |> String.downcase()

    cond do
      Enum.member?(@checked_on, word) -> true
      Enum.member?(@checked_off, word) -> false
      true -> nil
    end
  end

  def parse_checked(_), do: nil

  @doc """
  A stored value as the API, MCP and a page's `fields` give it: a checkbox
  as `true` when on (off has no value, so it is left out), a person field
  as its people (`%{"id", "name", "email"}`, and `"former"` for one who has
  left), any other kind as it is.
  """
  def external(%FieldDefinition{kind: "checkbox"}, value), do: if(value == 1.0, do: true)
  # A person field is its people, shaped as a card's assignees, with
  # `former` true for one who has left the board (#3614).
  def external(%FieldDefinition{kind: "person"} = field, ids) when is_list(ids) do
    for person <- People.people(field, ids) do
      base = %{"id" => person.id, "name" => person.name, "email" => person.email}
      if person.former, do: Map.put(base, "former", true), else: base
    end
  end

  def external(_field, value), do: value

  defp number(n) when is_number(n), do: {:ok, n * 1.0}

  defp number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "That isn't a number."}
    end
  end

  defp number(_), do: {:error, "That isn't a number."}

  defp within(n, min, max, name) do
    cond do
      is_number(min) and n < min -> {:error, "#{name} must be at least #{trim(min)}."}
      is_number(max) and n > max -> {:error, "#{name} must be at most #{trim(max)}."}
      true -> :ok
    end
  end

  defp trim(n) when is_float(n) and n == trunc(n), do: trunc(n)
  defp trim(n), do: n

  ## Formulas -------------------------------------------------------------------

  @doc """
  Computes every formula field for `cards` (with `field_values` loaded) and
  returns them with `computed` set. Formulas are evaluated in position
  order, so a formula may use one defined before it.
  """
  def decorate(cards, fields) when is_list(cards) and is_list(fields) do
    cards
    |> compute_formulas(fields)
    |> Enum.map(&put_checkboxes(&1, fields))
    |> Enum.map(&put_front_fields(&1, fields))
  end

  def decorate(cards, _), do: cards

  @doc """
  The values a card's front shows (#3609): `[{field, text}]` for each field
  switched to Show on cards, in field order, leaving out the ones it has no
  value for.
  """
  def front_fields(card, fields) do
    # A field the card has no value for formats to nil, which the binding
    # filters out; an empty text is stored as no value, so there is no "".
    for %FieldDefinition{show_on_cards: true} = field <- fields,
        text = front_text(field, value(card, field)),
        do: {field, text}
  end

  # A checked checkbox's chip names its field ("✓ Paid"); an unchecked one has none.
  defp front_text(%FieldDefinition{kind: "checkbox", name: name}, value),
    do: if(value == 1.0, do: "✓ #{name}")

  defp front_text(field, value), do: format(field, value)

  # Every checkbox as a number in `computed`, 1.0 or 0.0, so a sort, a
  # swimlane axis and a view's kept filter read an empty one as off (#3612).
  # `value/2` still gives what is stored.
  defp put_checkboxes(item, fields) do
    checkboxes =
      for %FieldDefinition{kind: "checkbox"} = field <- fields,
          into: %{},
          do: {field.id, numeric(item, field)}

    Map.put(item, :computed, Map.merge(Map.get(item, :computed) || %{}, checkboxes))
  end

  # Only a card has them; a page placed on the board shows no field chips.
  defp put_front_fields(%Card{} = card, fields),
    do: %{card | front_fields: front_fields(card, fields)}

  defp put_front_fields(item, _fields), do: item

  defp compute_formulas(cards, fields) do
    cards = Enum.map(cards, &Map.merge(&1, %{computed: %{}, scores: %{}}))
    by_key = Map.new(fields, &{&1.key, &1})

    fields
    |> Enum.filter(&(&1.kind == "formula"))
    |> Enum.reduce(cards, &apply_formula(&1, &2, by_key))
  end

  defp apply_formula(formula, cards, by_key) do
    results = compute_formula(formula, cards, by_key)
    Enum.map(cards, &put_formula_value(&1, formula, Map.get(results, &1.id)))
  end

  defp put_formula_value(card, formula, value) do
    %{
      card
      | computed: Map.put(card.computed, formula.id, value),
        scores: Map.put(card.scores, formula.key, value)
    }
  end

  # Computes `formula` for every card: a map of card id to value (or nil).
  defp compute_formula(%FieldDefinition{config: config}, cards, by_key) do
    case config["mode"] || "expression" do
      "weighted" ->
        weights = config["weights"] || []

        norms =
          Map.new(weights, fn %{"key" => key} ->
            values = Enum.map(cards, &{&1.id, lookup(&1, key, by_key)})
            present = for {_, v} <- values, is_number(v), do: v
            {min, max} = Enum.min_max(present, fn -> {0.0, 0.0} end)

            {key,
             Map.new(values, fn
               {id, v} when is_number(v) ->
                 {id, if(max == min, do: 100.0, else: (v - min) / (max - min) * 100)}

               {id, _} ->
                 {id, nil}
             end)}
          end)

        total_weight = weights |> Enum.map(&abs(&1["weight"])) |> Enum.sum()

        Map.new(cards, fn card ->
          parts = Enum.map(weights, fn %{"key" => k, "weight" => w} -> {w, norms[k][card.id]} end)

          value =
            if total_weight == 0 or Enum.any?(parts, fn {_, n} -> is_nil(n) end),
              do: nil,
              else: Enum.reduce(parts, 0.0, fn {w, n}, acc -> acc + w * n end) / total_weight

          {card.id, value}
        end)

      _ ->
        case Expression.parse(config["expression"] || "") do
          {:ok, ast} ->
            Map.new(cards, fn card ->
              {card.id, Expression.eval(ast, &lookup(card, &1, by_key))}
            end)

          {:error, _} ->
            Map.new(cards, &{&1.id, nil})
        end
    end
  end

  # A formula reference: a custom field by key, or a built-in.
  defp lookup(card, "votes", _), do: Card.vote_total(card) * 1.0

  defp lookup(card, "subcards", _) do
    case Card.progress(card) do
      {_, total} -> total * 1.0
      nil -> 0.0
    end
  end

  defp lookup(card, "done", _) do
    case Card.progress(card) do
      {done, _} -> done * 1.0
      nil -> 0.0
    end
  end

  defp lookup(card, key, by_key) do
    case Map.get(by_key, key) do
      nil -> nil
      field -> numeric(card, field)
    end
  end

  @doc """
  Decorates one card on its own: formulas that normalise across the board
  need the board's other cards, so their values are fetched.
  """
  def decorate_one(%Card{} = card, fields) do
    if Enum.any?(fields, &(&1.kind == "formula")) do
      peers =
        from(c in Card,
          where: c.board_id == ^card.board_id and is_nil(c.archived_at) and c.id != ^card.id,
          select: [:id, :board_id, :completed],
          preload: [:field_values, :votes]
        )
        |> Repo.all()

      [card | peers] |> decorate(fields) |> hd()
    else
      card
      |> Map.merge(%{computed: %{}, scores: %{}})
      |> put_checkboxes(fields)
      |> put_front_fields(fields)
    end
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end
