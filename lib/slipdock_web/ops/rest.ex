defmodule SlipdockWeb.Ops.REST do
  @moduledoc """
  A REST action made from an operation's definition. The
  router's path params are renamed to the definition's (`id` → `card`), the
  rest cast as MCP's are, and any error goes to `FallbackController`. The
  status is the definition's `status` (default 200).

  An action on another route that is the same operation with one param
  settled (`restore` for `archive_card`) puts that param in `params` before
  calling `run/3`.
  """

  import Phoenix.Controller, only: [json: 2]

  def run(conn, op, params) do
    params =
      Enum.reduce(op.definition().params, params, fn
        %{in_path: key, name: name}, acc -> Map.put(acc, name, Map.get(params, key))
        _, acc -> acc
      end)

    with {:ok, cast} <- SlipdockWeb.Ops.cast(op, params),
         {:ok, result} <- op.run(cast, conn) do
      conn |> Plug.Conn.put_status(status(op.definition()[:status], result)) |> json(result)
    end
  end

  defp status(nil, _result), do: :ok
  defp status(fun, result) when is_function(fun, 1), do: fun.(result)
  defp status(status, _result), do: status
end
