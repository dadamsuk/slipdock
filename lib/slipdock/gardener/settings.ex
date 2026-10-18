defmodule Slipdock.Gardener.Settings do
  @moduledoc """
  A board's gardening settings (W-1807): for each check, whether it runs and
  its thresholds. Kept in `boards.gardening` as `%{key => %{…}}`, holding
  only what the board has changed; everything else is the check's defaults.
  """

  alias Slipdock.Boards.Board
  alias Slipdock.Repo

  @doc "The settings `check` runs with on `board`: its defaults, with the board's changes over them."
  def for(%Board{gardening: gardening}, check) do
    Map.merge(check.defaults(), Map.get(gardening || %{}, check.key(), %{}))
  end

  @doc "Whether `check` is on for `board`."
  def enabled?(%Board{} = board, check), do: __MODULE__.for(board, check)["enabled"] == true

  @doc """
  Changes `check`'s settings on `board`. `attrs` may hold `"enabled"` and the
  check's own thresholds (anything else is refused): a threshold must be a
  positive number. `{:ok, board}` or `{:error, reason}`.
  """
  def put(%Board{} = board, check, attrs) when is_map(attrs) do
    defaults = check.defaults()
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- known_keys(attrs, defaults),
         {:ok, attrs} <- cast(attrs, defaults) do
      current = Map.get(board.gardening || %{}, check.key(), %{})
      # Only differences from the defaults are kept, so a later change to a
      # default reaches every board that never touched it.
      merged =
        current
        |> Map.merge(attrs)
        |> Map.reject(fn {k, v} -> Map.get(defaults, k) == v end)

      gardening =
        if merged == %{},
          do: Map.delete(board.gardening || %{}, check.key()),
          else: Map.put(board.gardening || %{}, check.key(), merged)

      board |> Ecto.Changeset.change(gardening: gardening) |> Repo.update()
    end
  end

  defp known_keys(attrs, defaults) do
    case Map.keys(attrs) -- Map.keys(defaults) do
      [] -> :ok
      unknown -> {:error, "unknown setting: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp cast(attrs, defaults) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case cast_value(k, v, Map.fetch!(defaults, k)) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
        :error -> {:halt, {:error, "#{k} must be #{expected(Map.fetch!(defaults, k))}"}}
      end
    end)
  end

  defp cast_value(_k, v, d) when is_boolean(d) and is_boolean(v), do: {:ok, v}
  defp cast_value(_k, "true", d) when is_boolean(d), do: {:ok, true}
  defp cast_value(_k, "false", d) when is_boolean(d), do: {:ok, false}
  defp cast_value(_k, v, d) when is_integer(d) and is_integer(v) and v > 0, do: {:ok, v}

  defp cast_value(k, v, d) when is_integer(d) and is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> cast_value(k, n, d)
      _ -> :error
    end
  end

  defp cast_value(_k, v, d) when is_float(d) and is_number(v) and v > 0 and v <= 1,
    do: {:ok, v / 1}

  defp cast_value(k, v, d) when is_float(d) and is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, ""} -> cast_value(k, n, d)
      _ -> :error
    end
  end

  defp cast_value(_k, _v, _d), do: :error

  defp expected(d) when is_boolean(d), do: "true or false"
  defp expected(d) when is_integer(d), do: "a whole number above 0"
  defp expected(d) when is_float(d), do: "a number above 0 and at most 1"
end
