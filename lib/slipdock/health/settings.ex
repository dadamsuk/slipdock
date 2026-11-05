defmodule Slipdock.Health.Settings do
  @moduledoc """
  A board tree's health-monitor settings: for each detector, whether it runs
  (`"enabled"`), how many fixes it tries before flagging (`"max_attempts"`)
  and its thresholds. Kept on the root board in `health_settings`, holding
  only what the tree changed; everything else is the detector's defaults.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Slipdock.Repo

  schema "health_settings" do
    field :settings, :map, default: %{}
    belongs_to :board, Slipdock.Boards.Board
    timestamps(type: :utc_datetime)
  end

  @base %{"enabled" => true, "max_attempts" => 2}

  @doc "What every detector has unless it says otherwise."
  def base, do: @base

  @doc "The changes the tree rooted at `root_id` made, `%{key => %{…}}`."
  def changes(root_id) do
    Repo.one(from(s in __MODULE__, where: s.board_id == ^root_id, select: s.settings)) || %{}
  end

  @doc "The settings `detector` runs with, given a tree's `changes`."
  def for(changes, detector) when is_map(changes) do
    @base
    |> Map.merge(detector.defaults())
    |> Map.merge(Map.get(changes, detector.key(), %{}))
  end

  @doc """
  Changes `detector`'s settings on the tree rooted at `root_id`. Only
  `"enabled"` (true or false) and the keys its defaults have (positive
  numbers) are taken. `{:ok, settings}` or `{:error, reason}`.
  """
  def put(root_id, detector, attrs) when is_map(attrs) do
    defaults = Map.merge(@base, detector.defaults())
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- known(attrs, defaults),
         {:ok, attrs} <- cast(attrs, defaults) do
      all = changes(root_id)

      mine =
        all
        |> Map.get(detector.key(), %{})
        |> Map.merge(attrs)
        |> Map.reject(fn {k, v} -> Map.get(defaults, k) == v end)

      all =
        if mine == %{},
          do: Map.delete(all, detector.key()),
          else: Map.put(all, detector.key(), mine)

      now = DateTime.utc_now(:second)

      Repo.insert!(
        %__MODULE__{board_id: root_id, settings: all, inserted_at: now, updated_at: now},
        on_conflict: [set: [settings: all, updated_at: now]],
        conflict_target: :board_id
      )

      {:ok, __MODULE__.for(all, detector)}
    end
  end

  defp known(attrs, defaults) do
    case Map.keys(attrs) -- Map.keys(defaults) do
      [] -> :ok
      unknown -> {:error, "unknown setting: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp cast(attrs, defaults) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case cast_value(v, Map.fetch!(defaults, k)) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
        :error -> {:halt, {:error, "#{k} must be #{what(Map.fetch!(defaults, k))}"}}
      end
    end)
  end

  defp cast_value(v, default) when is_boolean(default) do
    case v do
      b when is_boolean(b) -> {:ok, b}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  defp cast_value(v, default) when is_integer(default) do
    case v do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(String.trim(s)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp cast_value(_v, _default), do: :error

  defp what(default) when is_boolean(default), do: "true or false"
  defp what(_), do: "a whole number above 0"
end
