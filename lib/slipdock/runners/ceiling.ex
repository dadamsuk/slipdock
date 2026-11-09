defmodule Slipdock.Runners.Ceiling do
  @moduledoc """
  A machine's ceiling (#2571, W-2541 §2, W-2544 §2): the limits the
  machine wrote to its own local file at `init`, which only a person at the
  machine changes. The daemon reports it; the server keeps it on the machine
  to show (read-only) and to say which fields of a runner's config fall
  outside it. The server never sets it, and the daemon, not the server, is
  what refuses a config outside it.

  - `roots`: the directories a runner's working directory must be under
  - `agents`: the agents a runner may use (`claude`, `codex`, custom names)
  - `max_permission_mode`: the highest permission mode
  - `max_timeout_minutes`: the longest timeout
  - `boards`: the boards the machine serves
  - `executors`: the executors the machine offers
  """

  alias Slipdock.Runners.Config

  @max_items 50

  @doc """
  Cleans a ceiling the daemon reported. Returns `{:ok, map}` (string keys)
  or `{:error, message}`. Every field is required: a ceiling with a gap
  would read as no limit there.
  """
  def build(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, roots} <- list(attrs, "roots", &root/1),
         {:ok, agents} <- list(attrs, "agents", &name/1),
         {:ok, executors} <- list(attrs, "executors", &executor/1),
         {:ok, boards} <- list(attrs, "boards", &board/1),
         {:ok, mode} <- mode(attrs["max_permission_mode"]),
         {:ok, timeout} <- timeout(attrs["max_timeout_minutes"]) do
      {:ok,
       %{
         "roots" => roots,
         "agents" => agents,
         "executors" => executors,
         "boards" => boards,
         "max_permission_mode" => mode,
         "max_timeout_minutes" => timeout
       }}
    end
  end

  def build(_), do: {:error, "the ceiling must be an object"}

  defp list(attrs, key, check) do
    case attrs[key] do
      values when is_list(values) and length(values) <= @max_items ->
        values |> Enum.reduce_while({:ok, []}, &check_item(&1, &2, key, check)) |> uniq()

      values when is_list(values) ->
        {:error, "#{key}: at most #{@max_items}"}

      _ ->
        {:error, "#{key} is required, as a list"}
    end
  end

  defp check_item(value, {:ok, acc}, key, check) do
    case check.(value) do
      {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
      :error -> {:halt, {:error, "#{key}: #{inspect(value)} is not allowed there"}}
    end
  end

  defp uniq({:ok, acc}), do: {:ok, acc |> Enum.reverse() |> Enum.uniq()}
  defp uniq(error), do: error

  defp root(value) when is_binary(value) do
    value = String.trim(value)

    if Config.absolute?(value) and String.length(value) <= 500 and
         not String.match?(value, ~r/[[:cntrl:]]/u) and
         not Enum.member?(Config.segments(value), ".."),
       do: {:ok, value},
       else: :error
  end

  defp root(_), do: :error

  defp name(value) when is_binary(value),
    do: if(String.match?(value, Config.name_format()), do: {:ok, value}, else: :error)

  defp name(_), do: :error

  defp executor(value),
    do: if(Enum.member?(Config.executors(), value), do: {:ok, value}, else: :error)

  defp board(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp board(_), do: :error

  defp mode(value) do
    if Enum.member?(Config.permission_modes(), value),
      do: {:ok, value},
      else:
        {:error,
         "max_permission_mode must be one of #{Enum.join(Config.permission_modes(), ", ")}"}
  end

  defp timeout(value) when is_integer(value) and value > 0 and value <= 1440, do: {:ok, value}

  defp timeout(_),
    do: {:error, "max_timeout_minutes must be a whole number from 1 to #{Config.max_timeout()}"}

  @doc """
  Whether `config` (a config map) fits inside `ceiling` (a ceiling map) for
  a runner on board `board_id`: `:ok`, or `{:error, reasons}`, one line per
  field outside it, for the Machines page to grey out and show. A machine
  that hasn't reported a ceiling (nil) has nothing to compare with: `:ok`,
  and the daemon decides.
  """
  def check(_config, nil, _board_id), do: :ok

  def check(config, ceiling, board_id) do
    reasons =
      [
        not under_root?(config["directory"], ceiling["roots"]) &&
          "directory #{config["directory"]} is not under #{Enum.join(ceiling["roots"], ", ")}",
        not Enum.member?(ceiling["agents"], config["agent"]) &&
          "agent #{config["agent"]} is not one of #{Enum.join(ceiling["agents"], ", ")}",
        rank(config["permission_mode"]) > rank(ceiling["max_permission_mode"]) &&
          "permission mode #{config["permission_mode"]} is above #{ceiling["max_permission_mode"]}",
        config["timeout_minutes"] > ceiling["max_timeout_minutes"] &&
          "timeout #{config["timeout_minutes"]} minutes is over #{ceiling["max_timeout_minutes"]}",
        not Enum.member?(ceiling["executors"], config["executor"]) &&
          "executor #{config["executor"]} is not one this machine offers",
        not Enum.member?(ceiling["boards"], board_id) &&
          "board #{board_id} is not one this machine serves"
      ]
      |> Enum.filter(&is_binary/1)

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  defp rank(mode), do: Enum.find_index(Config.permission_modes(), &(&1 == mode)) || 99

  @doc """
  Whether `dir` is one of `roots` or inside one, segment by segment, so
  `/src-other` is not under `/src`.
  """
  def under_root?(dir, roots) when is_binary(dir) and is_list(roots) do
    parts = Config.segments(dir)
    abs = String.first(dir)

    Enum.any?(roots, fn root ->
      root_parts = Config.segments(root)

      String.first(root) == abs and Enum.take(parts, length(root_parts)) == root_parts
    end)
  end

  def under_root?(_dir, _roots), do: false
end
