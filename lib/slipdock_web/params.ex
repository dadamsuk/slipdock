defmodule SlipdockWeb.Params do
  @moduledoc """
  Reading ids out of what a client sent. A LiveView event or a request can
  carry anything — a stale page, a hand-made websocket frame — so a value that
  isn't an id comes back as `nil` for the caller to refuse politely, instead
  of `String.to_integer/1` or a `get!` crashing the socket or answering 500.
  """

  @doc "`value` as a positive integer id, or nil."
  def id(value) when is_integer(value) and value > 0, do: value

  def id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  def id(_), do: nil

  @doc "`value` as any integer — a vote count, say — or nil."
  def int(value) when is_integer(value), do: value

  def int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def int(_), do: nil
end
