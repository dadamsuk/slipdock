defmodule Slipdock.Fields.Expression do
  @moduledoc """
  Arithmetic over field references: `{reach} * {impact} / {effort}`. Supports
  numbers, `{key}` references, `+ - * /`, unary minus and parentheses. A
  reference to a missing value makes the whole result nil, as does dividing
  by zero.
  """

  @type ast :: number | {:ref, String.t()} | {:neg, ast} | {atom, ast, ast}

  @doc "Parses an expression into an AST, or returns a readable error."
  def parse(text) when is_binary(text) do
    with {:ok, tokens} <- tokenize(String.trim(text)),
         {:ok, ast, []} <- expr(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, [tok | _]} -> {:error, "has unexpected #{describe(tok)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_), do: {:error, "is empty"}

  @doc "The keys the expression refers to."
  def refs({:ref, k}), do: [k]
  def refs({:neg, a}), do: refs(a)
  def refs({_op, a, b}), do: refs(a) ++ refs(b)
  def refs(_), do: []

  @doc "Evaluates the AST with `lookup` (a map of key to number, or a function)."
  def eval(ast, lookup) do
    get = if is_function(lookup, 1), do: lookup, else: &Map.get(lookup, &1)

    try do
      {:ok, do_eval(ast, get)}
    catch
      :missing -> nil
      :div_zero -> nil
    end
    |> case do
      {:ok, v} when is_number(v) -> v * 1.0
      _ -> nil
    end
  end

  defp do_eval(n, _get) when is_number(n), do: n

  defp do_eval({:ref, key}, get) do
    case get.(key) do
      n when is_number(n) -> n
      _ -> throw(:missing)
    end
  end

  defp do_eval({:neg, a}, get), do: -do_eval(a, get)
  defp do_eval({:add, a, b}, get), do: do_eval(a, get) + do_eval(b, get)
  defp do_eval({:sub, a, b}, get), do: do_eval(a, get) - do_eval(b, get)
  defp do_eval({:mul, a, b}, get), do: do_eval(a, get) * do_eval(b, get)

  defp do_eval({:div, a, b}, get) do
    d = do_eval(b, get)
    if d == 0, do: throw(:div_zero), else: do_eval(a, get) / d
  end

  ## Tokens ---------------------------------------------------------------------

  defp tokenize(""), do: {:error, "is empty"}
  defp tokenize(text), do: tokenize(text, [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in ~c" \t\n\r", do: tokenize(rest, acc)

  defp tokenize(<<c, rest::binary>>, acc) when c in ~c"+-*/()",
    do: tokenize(rest, [String.to_atom(<<c>>) | acc])

  defp tokenize(<<"{", rest::binary>>, acc) do
    case String.split(rest, "}", parts: 2) do
      [key, rest] ->
        key = String.trim(key)

        if key =~ ~r/^[a-z][a-z0-9_]*$/,
          do: tokenize(rest, [{:ref, key} | acc]),
          else: {:error, "has a bad field reference {#{key}}"}

      _ ->
        {:error, "has an unclosed {"}
    end
  end

  defp tokenize(<<c, _::binary>> = text, acc) when c in ?0..?9 or c == ?. do
    case Float.parse(text) do
      {n, rest} -> tokenize(rest, [n | acc])
      :error -> {:error, "has a bad number"}
    end
  end

  defp tokenize(<<c, _::binary>>, _acc), do: {:error, "has an unexpected character #{<<c>>}"}

  ## Grammar: expr = term (('+'|'-') term)*; term = factor (('*'|'/') factor)*;
  ## factor = number | ref | '(' expr ')' | '-' factor

  defp expr(tokens) do
    with {:ok, left, rest} <- term(tokens), do: expr_tail(left, rest)
  end

  defp expr_tail(left, [op | rest]) when op in [:+, :-] do
    with {:ok, right, rest} <- term(rest) do
      expr_tail({if(op == :+, do: :add, else: :sub), left, right}, rest)
    end
  end

  defp expr_tail(left, rest), do: {:ok, left, rest}

  defp term(tokens) do
    with {:ok, left, rest} <- factor(tokens), do: term_tail(left, rest)
  end

  defp term_tail(left, [op | rest]) when op in [:*, :/] do
    with {:ok, right, rest} <- factor(rest) do
      term_tail({if(op == :*, do: :mul, else: :div), left, right}, rest)
    end
  end

  defp term_tail(left, rest), do: {:ok, left, rest}

  defp factor([n | rest]) when is_number(n), do: {:ok, n, rest}
  defp factor([{:ref, _} = ref | rest]), do: {:ok, ref, rest}

  defp factor([:- | rest]) do
    with {:ok, a, rest} <- factor(rest), do: {:ok, {:neg, a}, rest}
  end

  defp factor([:"(" | rest]) do
    case expr(rest) do
      {:ok, inner, [:")" | rest]} -> {:ok, inner, rest}
      {:ok, _, _} -> {:error, "is missing a closing parenthesis"}
      error -> error
    end
  end

  defp factor([tok | _]), do: {:error, "has unexpected #{describe(tok)}"}
  defp factor([]), do: {:error, "ends too early"}

  defp describe({:ref, k}), do: "{#{k}}"
  defp describe(n) when is_number(n), do: "number #{n}"
  defp describe(op), do: "“#{op}”"
end
