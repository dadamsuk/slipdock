defmodule Slipdock.Boards.FieldDefinition do
  @moduledoc """
  A custom field on a board tree. Kinds:

    * `text` (the default) – `config` may carry `max_length`, the most
      characters a value takes (#3647)
    * `number` – a float; `config` may carry `min`, `max`, `step`, `unit`
    * `rating` – 1 to `config["max"]` (default 5) stars
    * `select` – one of `options`, each `%{"key", "label", "weight", "color"}`;
      the weight is the option's value in formulas. With `config["several"]`
      (Allow several, #3611) a card holds any number of them, kept in option
      order: its formula value is the sum of their weights, and on a swimlane
      axis it sits in each of their lanes
    * `date`
    * `url` – one http(s) link (#3613), kept as text and shown as its host
    * `email` – one email address (#3647), kept as text
    * `checkbox` – on or off: on is stored as the number 1.0 and off as no
      value, so an empty one counts as off; it is 1 or 0 in formulas
    * `person` – several of the board tree's members (#3614), kept as their
      user ids in the order picked; one who has left stays, marked as a
      former member, and can't be picked again
    * `formula` – computed from other fields; `config["mode"]` is
      `"expression"` (an arithmetic expression over `{key}` references) or
      `"weighted"` (each input in `config["weights"]` normalised 0–100 across
      the board's cards, times its weight; negative weights subtract, so
      effort-like inputs pull a score down)

  The `key` is the short name used in formulas.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Text first: it is the type a new field starts as (#3647).
  @kinds [
    {"text", "Text"},
    {"number", "Number"},
    {"rating", "Rating"},
    {"select", "Choice"},
    {"date", "Date"},
    {"url", "URL"},
    {"email", "Email"},
    {"checkbox", "Checkbox"},
    {"person", "Person"},
    {"formula", "Formula"}
  ]

  schema "field_definitions" do
    field :name, :string
    field :key, :string
    field :kind, :string
    field :position, :integer, default: 0
    field :options, {:array, :map}, default: []
    field :config, :map, default: %{}
    field :sum, :boolean, default: false
    # Its value shows on the card front, as a chip (#3609).
    field :show_on_cards, :boolean, default: false

    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  # The kinds whose value is a line of text: filtered on the words it
  # contains, edited in a box. One list, so a new one is added once (#3647).
  @text_kinds ~w(text url email)

  @doc "Whether values of `kind` are text (filtered on words they contain)."
  defguard is_text_kind(kind) when kind in @text_kinds

  def text_kind?(kind), do: kind in @text_kinds
  def kind_keys, do: Enum.map(@kinds, &elem(&1, 0))

  def kind_label(kind) do
    case List.keyfind(@kinds, kind, 0) do
      {_, l} -> l
      nil -> kind
    end
  end

  @doc "Whether values of the field are numbers (usable in formulas and sums)."
  def numeric?(%__MODULE__{kind: k}),
    do: Enum.member?(~w(number rating select checkbox formula), k)

  # The kinds whose values are fixed, so each can be a swimlane lane (#3607).
  # Every other kind is explicitly not an axis: its values are open-ended.
  # A date is bucketed by the view's unit, as due dates are (#3615).
  # A person field has a lane per person it holds (#3614).
  @axis_kinds ~w(rating select date checkbox person)

  @doc """
  Whether the field can be a swimlane axis. Every kind is one or explicitly
  not one, which `Slipdock.Fields.EveryKindTest` holds each kind to.
  """
  def axis?(%__MODULE__{kind: k}), do: Enum.member?(@axis_kinds, k)

  @doc "Whether the field is a choice that allows several options per card (#3611)."
  def several?(%__MODULE__{kind: "select", config: %{"several" => true}}), do: true
  def several?(_), do: false

  @doc "Where option `key` sits in the field's options, or nil when it has no such option."
  def option_index(%__MODULE__{options: options}, key),
    do: Enum.find_index(options || [], &(&1["key"] == key))

  @doc "The highest rating the field takes."
  def rating_max(%__MODULE__{kind: "rating", config: c}), do: int(c["max"], 5)
  def rating_max(_), do: 5

  @doc "The weight (numeric value) of a select option, or nil."
  def option_weight(%__MODULE__{options: options}, key) do
    case Enum.find(options, &(&1["key"] == key)) do
      %{"weight" => w} when is_number(w) -> w * 1.0
      _ -> nil
    end
  end

  def option_label(%__MODULE__{options: options}, key) do
    case Enum.find(options, &(&1["key"] == key)) do
      %{"label" => l} -> l
      _ -> key
    end
  end

  @doc "Turns a name into a formula key: lower case, words joined by underscores."
  def slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end

  def slug(_), do: ""

  def changeset(field, attrs) do
    attrs = normalize(attrs)

    field
    |> cast(attrs, [:name, :key, :kind, :position, :options, :config, :sum, :show_on_cards])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_inclusion(:kind, kind_keys())
    |> put_key()
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]{0,39}$/,
      message: "must be letters, digits and underscores, starting with a letter"
    )
    |> validate_options()
    |> validate_config()
    |> validate_formula()
    |> unique_constraint([:board_id, :key],
      error_key: :key,
      message: "is already used on this board"
    )
  end

  defp put_key(changeset) do
    case get_field(changeset, :key) do
      k when k in [nil, ""] -> put_change(changeset, :key, slug(get_field(changeset, :name)))
      _ -> changeset
    end
  end

  # Options and config arrive from forms with string keys (and index-keyed
  # maps for lists); make them clean string-keyed maps.
  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    attrs
    |> Map.update("options", nil, &normalize_options/1)
    |> Map.update("config", nil, &normalize_config/1)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  def normalize_options(nil), do: nil

  def normalize_options(options) when is_map(options) do
    options
    |> Enum.sort_by(fn {k, _} -> String.to_integer(to_string(k)) end)
    |> Enum.map(fn {_, v} -> v end)
    |> normalize_options()
  end

  def normalize_options(options) when is_list(options) do
    options
    |> Enum.map(fn
      o when is_map(o) ->
        o = Map.new(o, fn {k, v} -> {to_string(k), v} end)
        label = o["label"] |> to_string() |> String.trim()
        key = if Enum.member?([nil, ""], o["key"]), do: slug(label), else: to_string(o["key"])

        %{
          "key" => key,
          "label" => label,
          "weight" => float(o["weight"]),
          "color" => if(Enum.member?(Slipdock.Palette.names(), o["color"]), do: o["color"])
        }

      label when is_binary(label) ->
        %{"key" => slug(label), "label" => String.trim(label), "weight" => nil, "color" => nil}
    end)
    |> Enum.reject(&(&1["label"] == ""))
  end

  def normalize_options(_), do: []

  defp normalize_config(nil), do: nil

  defp normalize_config(config) when is_map(config) do
    config = Map.new(config, fn {k, v} -> {to_string(k), v} end)

    config
    |> Map.take(~w(min max step unit mode expression weights several max_length))
    |> Map.new(fn
      {"several", v} -> {"several", Enum.member?([true, "true", "on", "1"], v)}
      {"max_length", v} -> {"max_length", whole(v)}
      {"weights", w} -> {"weights", normalize_weights(w)}
      {"expression", e} -> {"expression", to_string(e) |> String.trim()}
      {"mode", m} -> {"mode", to_string(m)}
      {"unit", u} -> {"unit", to_string(u) |> String.trim()}
      {k, v} -> {k, float(v)}
    end)
    |> Enum.reject(fn {_, v} -> Enum.member?([nil, ""], v) end)
    |> Map.new()
  end

  defp normalize_config(_), do: %{}

  defp normalize_weights(w) when is_map(w) do
    w
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {_, v} -> v end)
    |> normalize_weights()
  end

  defp normalize_weights(w) when is_list(w) do
    w
    |> Enum.map(fn
      %{} = m ->
        m = Map.new(m, fn {k, v} -> {to_string(k), v} end)
        %{"key" => to_string(m["key"] || ""), "weight" => float(m["weight"]) || 1.0}

      _ ->
        nil
    end)
    |> Enum.reject(&(is_nil(&1) or &1["key"] == ""))
  end

  defp normalize_weights(_), do: []

  defp validate_options(changeset) do
    if get_field(changeset, :kind) == "select" and
         Enum.member?([nil, []], get_field(changeset, :options)),
       do: add_error(changeset, :options, "a choice field needs at least one option"),
       else: changeset
  end

  # What each type's settings may be (#3647): a range that runs forwards, a
  # most characters of at least one, between 2 and 10 stars, and a choice's
  # options each named once.
  defp validate_config(changeset) do
    config = get_field(changeset, :config) || %{}

    case get_field(changeset, :kind) do
      "number" ->
        min = config["min"]
        max = config["max"]

        cond do
          is_number(min) and is_number(max) and min > max ->
            add_error(changeset, :config, "least must not be more than most")

          is_number(config["step"]) and config["step"] <= 0 ->
            add_error(changeset, :config, "step must be more than 0")

          true ->
            changeset
        end

      "text" ->
        case config["max_length"] do
          nil ->
            changeset

          n when is_integer(n) and n >= 1 ->
            changeset

          _ ->
            add_error(changeset, :config, "most characters must be a whole number of at least 1")
        end

      "rating" ->
        case config["max"] do
          nil -> changeset
          n when is_number(n) and n >= 2 and n <= 10 and n == trunc(n) -> changeset
          _ -> add_error(changeset, :config, "stars must be a whole number from 2 to 10")
        end

      "select" ->
        keys = Enum.map(get_field(changeset, :options) || [], & &1["key"])

        if length(keys) == length(Enum.uniq(keys)),
          do: changeset,
          else: add_error(changeset, :options, "each choice needs a different name")

      _ ->
        changeset
    end
  end

  defp validate_formula(changeset) do
    if get_field(changeset, :kind) == "formula" do
      config = get_field(changeset, :config) || %{}

      case config["mode"] || "expression" do
        "expression" ->
          case Slipdock.Fields.Expression.parse(config["expression"] || "") do
            {:ok, _} -> put_change(changeset, :config, Map.put(config, "mode", "expression"))
            {:error, reason} -> add_error(changeset, :config, "formula #{reason}")
          end

        "weighted" ->
          if Enum.member?([nil, []], config["weights"]),
            do: add_error(changeset, :config, "a weighted score needs at least one input"),
            else: changeset

        other ->
          add_error(changeset, :config, "unknown formula mode #{other}")
      end
    else
      changeset
    end
  end

  # A whole number from a form: "120" or 120. Anything else is kept, so the
  # changeset can say what is wrong with it rather than drop it.
  defp whole(n) when is_integer(n), do: n
  defp whole(n) when is_float(n) and n == trunc(n), do: trunc(n)

  defp whole(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, ""} -> i
      _ -> if String.trim(s) == "", do: nil, else: s
    end
  end

  defp whole(other), do: other

  defp float(nil), do: nil
  defp float(""), do: nil
  defp float(n) when is_number(n), do: n * 1.0

  defp float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp float(_), do: nil

  defp int(nil, d), do: d
  defp int(n, _) when is_integer(n), do: n
  defp int(n, _) when is_float(n), do: round(n)

  defp int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> d
    end
  end

  defp int(_, d), do: d
end
