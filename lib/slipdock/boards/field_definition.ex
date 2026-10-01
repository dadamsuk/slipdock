defmodule Slipdock.Boards.FieldDefinition do
  @moduledoc """
  A custom field on a board tree. Kinds:

    * `number` – a float; `config` may carry `min`, `max`, `step`, `unit`
    * `rating` – 1 to `config["max"]` (default 5) stars
    * `select` – one of `options`, each `%{"key", "label", "weight", "color"}`;
      the weight is the option's value in formulas
    * `date`, `text`
    * `formula` – computed from other fields; `config["mode"]` is
      `"expression"` (an arithmetic expression over `{key}` references) or
      `"weighted"` (each input in `config["weights"]` normalised 0–100 across
      the board's cards, times its weight; negative weights subtract, so
      effort-like inputs pull a score down)

  The `key` is the short name used in formulas.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds [
    {"number", "Number"},
    {"rating", "Rating"},
    {"select", "Choice"},
    {"date", "Date"},
    {"text", "Text"},
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

    belongs_to :board, Slipdock.Boards.Board

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def kind_keys, do: Enum.map(@kinds, &elem(&1, 0))

  def kind_label(kind) do
    case List.keyfind(@kinds, kind, 0) do
      {_, l} -> l
      nil -> kind
    end
  end

  @doc "Whether values of the field are numbers (usable in formulas and sums)."
  def numeric?(%__MODULE__{kind: k}), do: k in ~w(number rating select formula)

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
    |> cast(attrs, [:name, :key, :kind, :position, :options, :config, :sum])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_inclusion(:kind, kind_keys())
    |> put_key()
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]{0,39}$/,
      message: "must be letters, digits and underscores, starting with a letter"
    )
    |> validate_options()
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
        key = if o["key"] in [nil, ""], do: slug(label), else: to_string(o["key"])

        %{
          "key" => key,
          "label" => label,
          "weight" => float(o["weight"]),
          "color" => if(o["color"] in Slipdock.Palette.names(), do: o["color"])
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
    |> Map.take(~w(min max step unit mode expression weights))
    |> Map.new(fn
      {"weights", w} -> {"weights", normalize_weights(w)}
      {"expression", e} -> {"expression", to_string(e) |> String.trim()}
      {"mode", m} -> {"mode", to_string(m)}
      {"unit", u} -> {"unit", to_string(u) |> String.trim()}
      {k, v} -> {k, float(v)}
    end)
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
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
    if get_field(changeset, :kind) == "select" and get_field(changeset, :options) in [nil, []],
      do: add_error(changeset, :options, "a choice field needs at least one option"),
      else: changeset
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
          if config["weights"] in [nil, []],
            do: add_error(changeset, :config, "a weighted score needs at least one input"),
            else: changeset

        other ->
          add_error(changeset, :config, "unknown formula mode #{other}")
      end
    else
      changeset
    end
  end

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
