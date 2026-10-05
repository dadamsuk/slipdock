defmodule SlipdockWeb.MCP.Args do
  @moduledoc """
  Reading a tool's arguments, and answering in the shape `SlipdockWeb.MCP.Tool`
  expects. A client's model writes these arguments, so every mistake gets a
  sentence it can act on rather than a crash.
  """

  @doc """
  What `SlipdockWeb.API.Authorize` reads from a conn — the user and the token
  — for a call that has no conn. Visibility through MCP is then exactly what
  the HTTP API allows the same token, because it is the same check.
  """
  def auth(%{user: user, token: token}), do: %{assigns: %{current_user: user, api_token: token}}

  @doc "A required string argument, trimmed."
  def required(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{key} is required"}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, to_string(value)}

      nil ->
        {:error, "#{key} is required"}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  @doc "An optional string argument; nil when absent or blank."
  def optional(args, key) do
    case args[key] do
      nil ->
        {:ok, nil}

      value when is_integer(value) ->
        {:ok, to_string(value)}

      value when is_binary(value) ->
        {:ok, if(String.trim(value) == "", do: nil, else: String.trim(value))}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  @doc "An optional boolean argument."
  def boolean(args, key, default \\ nil) do
    case args[key] do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  @doc "An optional positive integer, capped at `max`."
  def limit(args, key, default, max) do
    case args[key] do
      nil -> {:ok, default}
      n when is_integer(n) and n > 0 -> {:ok, min(n, max)}
      _ -> {:error, "#{key} must be a positive whole number"}
    end
  end

  @doc "A required id: a whole number, or a string of one (`\"#129\"` too)."
  def id(args, key) do
    case args[key] do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s |> String.trim() |> String.trim_leading("#")) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{key} must be a card number, like 129"}
        end

      nil ->
        {:error, "#{key} is required"}

      _ ->
        {:error, "#{key} must be a card number, like 129"}
    end
  end

  @doc """
  The API's `{:error, status, message}` refusals, as a tool's error text. A
  thing that is not there, or not the reader's to see, reads the same.
  """
  def refusal({:error, :not_found, what}), do: {:error, "no #{what} you can see matches that"}
  def refusal({:error, _status, message}) when is_binary(message), do: {:error, message}
  def refusal({:error, message}) when is_binary(message), do: {:error, message}
  def refusal(other), do: other
end
