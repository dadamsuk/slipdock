defmodule SlipdockWeb.Ops do
  @moduledoc """
  The operations defined once (#3183) (see
  `SlipdockWeb.Ops.Op`), and what each surface is made from them: casting
  params, the MCP input schema, the CLI's manifest and the guide's reference.
  """

  alias SlipdockWeb.Ops

  @ops [Ops.MoveCard, Ops.ArchiveCard, Ops.DeleteCard, Ops.LeaveHandoff, Ops.VerifyCard]

  def all, do: @ops

  @doc """
  Casts raw params (REST's or MCP's, string keys) by the definition. MCP's
  (`surface` `:mcp`) include the definition's `confirm`, cast but not
  required here: the operation's `confirm/2` says what a missing one means.
  """
  def cast(op, raw, surface \\ :rest) do
    Enum.reduce_while(params(op, surface), {:ok, %{}}, fn param, {:ok, acc} ->
      case cast_one(param, Map.get(raw, param.name, param[:default])) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
        {:error, message} -> {:halt, {:error, :bad_request, message}}
      end
    end)
  end

  # The params a surface takes: MCP's have the definition's `confirm` too.
  defp params(op, :rest), do: op.definition().params

  defp params(op, :mcp) do
    case op.definition()[:confirm] do
      nil -> op.definition().params
      confirm -> op.definition().params ++ [Map.put(confirm, :name, "confirm")]
    end
  end

  defp cast_one(%{required: true, name: name}, nil), do: {:error, "#{name} is required"}
  defp cast_one(_param, nil), do: {:ok, nil}
  defp cast_one(%{type: :any}, v), do: {:ok, v}
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
      else: {:error, "#{n} must be #{either(values)}"}
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

  # "a, b or c"
  defp either([one]), do: one
  defp either(values), do: Enum.join(Enum.drop(values, -1), ", ") <> " or " <> List.last(values)

  @doc """
  The MCP `inputSchema`, from the params: the definition's `confirm`, when
  it has one, is among them and required.
  """
  def input_schema(op) do
    params = params(op, :mcp)
    confirm = if op.definition()[:confirm], do: ["confirm"], else: []

    %{
      type: "object",
      # Atom keys, as every hand-written tool's schema has them (the names
      # are the definitions', never a caller's).
      properties: Map.new(params, &{String.to_atom(&1.name), json_schema(&1)}),
      required: for(%{required: true, name: n} <- params, do: n) ++ confirm,
      additionalProperties: false
    }
  end

  defp json_schema(param) do
    base =
      case param.type do
        :any -> Map.fetch!(param, :schema)
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

      ordered(
        name: d.name,
        summary: d.summary,
        verb: d.verb |> to_string() |> String.upcase(),
        path: d.path,
        writes: d.writes?,
        params:
          Enum.map(d.params, fn p ->
            ordered(
              name: p.name,
              type: type_name(p.type),
              required: Map.get(p, :required, false),
              in_path: p[:in_path],
              default: p[:default]
            )
          end),
        cli: cli(d[:cli])
      )
    end
  end

  defp cli(nil), do: nil

  defp cli(cli) do
    ordered(
      command: cli.command,
      positional: cli.positional,
      flags:
        cli.flags
        |> Enum.sort()
        |> Enum.map(fn {flag, spec} ->
          {flag, ordered(param: spec.param, value: spec[:value])}
        end)
        |> Jason.OrderedObject.new()
    )
  end

  @doc """
  The manifest as JSON, keys in the order written above (not map order), so
  `cli/priv/ops.json` only changes when a definition does.
  """
  def manifest_json, do: Jason.encode!(manifest(), pretty: true) <> "\n"

  # Keys in the order given; a nil value is left out.
  defp ordered(pairs), do: pairs |> Enum.reject(&is_nil(elem(&1, 1))) |> Jason.OrderedObject.new()

  defp type_name({:enum, values}), do: ordered(enum: values)
  defp type_name(t), do: to_string(t)

  @doc "The guide's reference line for each operation, params and all."
  def reference do
    Enum.map_join(@ops, "\n", fn op ->
      d = op.definition()

      "- `#{d.verb |> to_string() |> String.upcase()} #{d.path}` — #{d.summary} " <>
        takes(Enum.reject(d.params, & &1[:in_path])) <> "Needs #{permission(d.permission)}."
    end)
  end

  defp takes([]), do: ""
  defp takes(params), do: "Takes #{Enum.map_join(params, ", ", &param_word/1)}. "

  defp param_word(%{default: default, name: name}) when not is_nil(default),
    do: "`#{name}` (default `#{default}`)"

  defp param_word(%{name: name}), do: "`#{name}`"

  defp permission({subject, :owner}), do: "to own the #{subject}"
  defp permission({subject, need}), do: "#{need} on the #{subject}"
end
