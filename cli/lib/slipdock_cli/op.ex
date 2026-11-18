defmodule SlipdockCLI.Op do
  @moduledoc """
  A CLI command made from the server's definition
  of the operation. `priv/ops.json` is `SlipdockWeb.Ops.manifest_json/0`
  (held to it by the app's `OpsTest`), read at compile time: the route, the
  params and how argv maps onto them come from there, not from this client.
  What the command prints stays here, hand-written.
  """

  alias SlipdockCLI.HTTP

  @path Path.expand("../../priv/ops.json", __DIR__)
  @external_resource @path
  # By command; an operation the CLI has no command for has no `cli`.
  @ops @path
       |> File.read!()
       |> JSON.decode!()
       |> Enum.filter(& &1["cli"])
       |> Map.new(&{&1["cli"]["command"], &1})

  def ops, do: @ops

  @doc """
  The request a command makes: `{verb, path, body}`. Positional words fill
  the definition's `positional` params in order (a trailing `name...` takes
  the rest, joined by spaces); flags map onto params by the definition's
  `flags`. Path params go into the path, the rest into the body: for a GET,
  the query string (`HTTP.get/2`).
  """
  def request(command, words, opts) do
    op = Map.fetch!(@ops, command)

    params =
      Map.merge(positional(op["cli"]["positional"], words), flags(op["cli"]["flags"], opts))

    path =
      Enum.reduce(op["params"], op["path"], fn
        %{"in_path" => key, "name" => name}, path ->
          String.replace(path, ":" <> key, HTTP.seg(to_string(Map.fetch!(params, name))))

        _, path ->
          path
      end)

    body = Map.drop(params, for(%{"in_path" => _, "name" => n} <- op["params"], do: n))

    {op["verb"] |> String.downcase() |> String.to_atom(), String.replace_prefix(path, "/api", ""),
     body}
  end

  @doc "Makes the request: what `HTTP.<verb>` answers."
  def run(command, words, opts) do
    {verb, path, body} = request(command, words, opts)
    apply(HTTP, verb, [path, body])
  end

  defp positional(names, words) do
    {params, _} =
      Enum.reduce(names, {%{}, words}, fn
        _name, {acc, []} ->
          {acc, []}

        name, {acc, rest} ->
          if String.ends_with?(name, "...") do
            {Map.put(acc, String.trim_trailing(name, "..."), Enum.join(rest, " ")), []}
          else
            [word | rest] = rest
            {Map.put(acc, name, word), rest}
          end
      end)

    params
  end

  defp flags(flags, opts) do
    Enum.reduce(flags, %{}, fn {flag, spec}, acc ->
      case opts[String.to_atom(flag)] do
        nil -> acc
        false -> acc
        value -> Map.put(acc, spec["param"], Map.get(spec, "value", value))
      end
    end)
  end
end
