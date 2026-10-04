defmodule Slipdock.Fields do
  @moduledoc """
  Custom fields on a board tree: their definitions, the values cards hold,
  formulas computed from those values, and the RICE / ICE / value-effort
  presets that set a scoring scheme up in one go.

  Values are read from a card's preloaded `field_values`; formula results
  live in the card's virtual `computed` map (field id to number), filled by
  `decorate/2` for a board's cards at once, since a weighted score
  normalises each input across the whole board.
  """

  import Ecto.Query

  alias Slipdock.Boards.{Board, Card, FieldDefinition, FieldValue, Owned}
  alias Slipdock.Wiki.Page
  alias Slipdock.Fields.Expression
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

  def get_field!(id), do: Repo.get!(FieldDefinition, id)

  @doc "Finds a field on the tree by id or key/name (case-insensitive)."
  def find_field(fields, ref) when is_list(fields) do
    ref = to_string(ref) |> String.trim()
    down = String.downcase(ref)

    Enum.find(fields, fn f ->
      to_string(f.id) == ref or f.key == down or String.downcase(f.name) == down
    end)
  end

  def create_field(%Board{} = board, attrs) do
    root_id = Board.root_id(board)

    position =
      Repo.one(from(f in FieldDefinition, where: f.board_id == ^root_id, select: max(f.position))) ||
        -1

    %FieldDefinition{board_id: root_id, position: position + 1}
    |> FieldDefinition.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn _ -> Slipdock.Boards.broadcast_tree(root_id) end)
  end

  def update_field(%FieldDefinition{} = field, attrs) do
    field
    |> FieldDefinition.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn f -> Slipdock.Boards.broadcast_tree(f.board_id) end)
  end

  def delete_field(%FieldDefinition{} = field) do
    Repo.delete(field)
    |> tap_ok(fn f -> Slipdock.Boards.broadcast_tree(f.board_id) end)
  end

  @doc """
  Sets a preset up on the tree: creates each input field that isn't there
  yet (matched by key) and the formula field. Returns the formula field.
  """
  def install_preset(%Board{} = board, key) do
    case Enum.find(@presets, &(&1.key == key)) do
      nil ->
        {:error, :unknown_preset}

      preset ->
        root_id = Board.root_id(board)
        existing = list_fields(root_id)

        Enum.each(preset.inputs, fn input ->
          unless Enum.any?(existing, &(&1.key == input.key)) do
            {:ok, _} =
              create_field(board, %{
                "name" => input.name,
                "key" => input.key,
                "kind" => input.kind,
                "config" => input.config
              })
          end
        end)

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

  ## Values ---------------------------------------------------------------------

  @doc """
  The stored value for `field` (number, option key, date or text), or nil.

  Takes a card or a wiki page: a page carries the board's custom fields too,
  in the same table (see `Slipdock.Boards.Owned`), so these match on shape.
  """
  def value(%{computed: computed}, %FieldDefinition{kind: "formula", id: id}),
    do: Map.get(computed || %{}, id)

  def value(%{field_values: values}, %FieldDefinition{id: id}) when is_list(values) do
    case Enum.find(values, &(&1.field_id == id)) do
      nil -> nil
      v -> FieldValue.get(v)
    end
  end

  def value(_, _), do: nil

  @doc "The value for `field` as a number: numbers and ratings as they are, options by weight."
  def numeric(card, %FieldDefinition{kind: "select"} = field) do
    case value(card, field) do
      nil -> nil
      key -> FieldDefinition.option_weight(field, key)
    end
  end

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

  def format(%FieldDefinition{kind: "select"} = field, key),
    do: FieldDefinition.option_label(field, key)

  def format(%FieldDefinition{kind: "rating"}, n) when is_number(n), do: "#{round(n)}"
  def format(%FieldDefinition{kind: "date"}, %Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")
  def format(%FieldDefinition{kind: "text"}, t), do: t

  def format(%FieldDefinition{config: config}, n) when is_number(n) do
    text =
      if n == trunc(n),
        do: Integer.to_string(trunc(n)),
        else: :erlang.float_to_binary(n * 1.0, decimals: 2)

    unit = config["unit"]
    if unit in [nil, ""], do: text, else: "#{text} #{unit}"
  end

  def format(_, other), do: to_string(other)

  @doc """
  Stores `raw` (from a form or the API) as the card's — or the page's — value
  for `field`; an empty value clears it. Returns `{:ok, reloaded}`, or
  `{:error, message}`.
  """
  def set_value(_owner, %FieldDefinition{kind: "formula"}, _raw),
    do: {:error, "A formula is computed, not set."}

  def set_value(owner, %FieldDefinition{} = field, raw) do
    case cast(field, raw) do
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
          on_conflict: {:replace, [:number, :text, :date, :option, :updated_at]},
          conflict_target: conflict_target(owner)
        )
        |> case do
          {:ok, _} -> after_set(owner, field, attrs)
          {:error, cs} -> {:error, "Couldn't save #{field.name}: #{inspect(cs.errors)}"}
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

    Slipdock.Boards.log_activity_for(
      card,
      "card",
      if(shown,
        do: "set #{field.name} on “#{card.title}” to #{shown}",
        else: "cleared #{field.name} on “#{card.title}”"
      )
    )

    Slipdock.Boards.broadcast_tree(Slipdock.Boards.root_of_board(card.board_id))
    reload(card)
  end

  defp reload(%Page{id: id}), do: {:ok, Slipdock.Wiki.get_page!(id)}
  defp reload(%Card{id: id}), do: {:ok, Slipdock.Boards.get_card!(id)}

  # What to store for a raw value, by kind. Empty means "clear".
  defp cast(_field, raw) when raw in [nil, ""], do: {:ok, nil}

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

  defp cast(%FieldDefinition{kind: "select", options: options} = field, raw) do
    key = to_string(raw)

    cond do
      Enum.any?(options, &(&1["key"] == key)) ->
        {:ok, %{option: key}}

      match = Enum.find(options, &(String.downcase(&1["label"]) == String.downcase(key))) ->
        {:ok, %{option: match["key"]}}

      true ->
        {:error, "#{field.name} has no option “#{key}”."}
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
    formulas = Enum.filter(fields, &(&1.kind == "formula"))

    if formulas == [] do
      Enum.map(cards, &Map.merge(&1, %{computed: %{}, scores: %{}}))
    else
      cards = Enum.map(cards, &Map.merge(&1, %{computed: %{}, scores: %{}}))
      by_key = Map.new(fields, &{&1.key, &1})

      Enum.reduce(formulas, cards, fn formula, cards ->
        results = compute_formula(formula, cards, by_key)

        Enum.map(cards, fn card ->
          value = Map.get(results, card.id)

          %{
            card
            | computed: Map.put(card.computed, formula.id, value),
              scores: Map.put(card.scores, formula.key, value)
          }
        end)
      end)
    end
  end

  def decorate(cards, _), do: cards

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
      Map.merge(card, %{computed: %{}, scores: %{}})
    end
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end
