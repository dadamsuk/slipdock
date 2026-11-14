defmodule SlipdockWeb.Ops do
  @moduledoc """
  Spike #3165 (never merged): the operations defined once (see
  `SlipdockWeb.Ops.Op`), and what each surface is made from them: casting
  params, the MCP input schema, the CLI's manifest and the guide's reference.
  """

  alias SlipdockWeb.Ops

  @ops [Ops.MoveCard]

  def all, do: @ops

  @doc "Casts raw params (REST's or MCP's, string keys) by the definition."
  def cast(op, raw) do
    Enum.reduce_while(op.definition().params, {:ok, %{}}, fn param, {:ok, acc} ->
      case cast_one(param, Map.get(raw, param.name, param[:default])) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
        {:error, message} -> {:halt, {:error, :bad_request, message}}
      end
    end)
  end

  defp cast_one(%{required: true, name: name}, nil), do: {:error, "#{name} is required"}
  defp cast_one(_param, nil), do: {:ok, nil}
  defp cast_one(%{type: :integer, name: n}, v), do: integer(n, v)
  defp cast_one(%{type: :boolean}, v) when is_boolean(v), do: {:ok, v}
  defp cast_one(%{type: :boolean}, v) when v in ["true", "false"], do: {:ok, v == "true"}

  defp cast_one(%{type: :string} = p, v) when is_binary(v) do
    case String.trim(v) do
      "" -> cast_one(p, nil)
      s -> {:ok, s}
    end
  end

  defp cast_one(%{type: :string} = p, v) when is_integer(v), do: cast_one(p, to_string(v))

  defp cast_one(%{type: {:enum, values}, name: n}, v) do
    if Enum.member?(values, v),
      do: {:ok, v},
      else: {:error, "#{n} must be #{Enum.join(values, " or ")}"}
  end

  defp cast_one(%{type: :position}, v) when v in ["top", "bottom"],
    do: {:ok, String.to_existing_atom(v)}

  defp cast_one(%{type: :position, name: n}, v) do
    case integer(n, v) do
      {:ok, i} when i >= 0 -> {:ok, i}
      _ -> {:error, "#{n} must be top, bottom or a place in the list (0 is the top)"}
    end
  end

  defp cast_one(%{name: n, type: t}, _), do: {:error, "#{n} must be #{type_word(t)}"}

  defp integer(_n, v) when is_integer(v), do: {:ok, v}

  defp integer(n, v) when is_binary(v) do
    case Integer.parse(String.trim_leading(v, "#")) do
      {i, ""} -> {:ok, i}
      _ -> {:error, "#{n} must be a number"}
    end
  end

  defp integer(n, _), do: {:error, "#{n} must be a number"}

  defp type_word(:boolean), do: "true or false"
  defp type_word(_), do: "a string"

  @doc "The MCP `inputSchema`, from the params."
  def input_schema(op) do
    params = op.definition().params

    %{
      type: "object",
      properties: Map.new(params, &{&1.name, json_schema(&1)}),
      required: for(%{required: true, name: n} <- params, do: n),
      additionalProperties: false
    }
  end

  defp json_schema(param) do
    base =
      case param.type do
        :integer -> %{type: "integer"}
        :boolean -> %{type: "boolean"}
        :string -> %{type: "string"}
        {:enum, values} -> %{type: "string", enum: values}
        :position -> %{type: ["string", "integer"]}
      end

    case param[:doc] do
      nil -> base
      doc -> Map.put(base, :description, doc)
    end
  end

  @doc """
  What the CLI is built from: every operation's route, params and argv
  mapping, as JSON. `cli/priv/ops.json` is this, checked by `OpsTest`.
  """
  def manifest do
    for op <- @ops do
      d = op.definition()

      %{
        name: d.name,
        summary: d.summary,
        verb: d.verb |> to_string() |> String.upcase(),
        path: d.path,
        writes: d.writes?,
        params:
          Enum.map(d.params, fn p ->
            %{name: p.name, type: type_name(p.type), required: Map.get(p, :required, false)}
            |> put_if(:in_path, p[:in_path])
            |> put_if(:default, p[:default])
          end),
        cli: d.cli
      }
    end
  end

  def manifest_json, do: Jason.encode!(manifest(), pretty: true) <> "\n"

  defp type_name({:enum, values}), do: %{enum: values}
  defp type_name(t), do: to_string(t)

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  @doc "The guide's reference line for each operation, params and all."
  def reference do
    Enum.map_join(@ops, "\n", fn op ->
      d = op.definition()

      params =
        d.params
        |> Enum.reject(& &1[:in_path])
        |> Enum.map_join(", ", &param_word/1)

      "- `#{d.verb |> to_string() |> String.upcase()} #{d.path}` — #{d.summary} " <>
        "Takes #{params}. Needs #{permission(d.permission)}."
    end)
  end

  defp param_word(%{default: default, name: name}) when not is_nil(default),
    do: "`#{name}` (default `#{default}`)"

  defp param_word(%{name: name}), do: "`#{name}`"

  defp permission({subject, need}), do: "#{need} on the #{subject}"
end
