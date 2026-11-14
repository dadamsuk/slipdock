defmodule SlipdockWeb.Ops.REST do
  @moduledoc """
  Spike #3165: a REST action made from an operation's definition. The
  router's path params are renamed to the definition's (`id` → `card`), the
  rest cast as MCP's are, and any error goes to `FallbackController`.
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
      json(conn, result)
    end
  end
end
