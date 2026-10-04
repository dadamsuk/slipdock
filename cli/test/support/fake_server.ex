defmodule SlipdockCLI.FakeServer do
  @moduledoc """
  Just enough of an HTTP server to answer the CLI: each request gets the
  next canned `{status, body}` in turn, and is reported to the test process
  as `{:request, method, path, body}` so the test can see what was sent.
  """

  def start(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    test = self()
    pid = spawn_link(fn -> serve(listen, responses, test) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    "http://127.0.0.1:#{port}"
  end

  defp serve(_listen, [], _test), do: :ok

  defp serve(listen, [{status, body} | rest], test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {method, path, request_body} = read_request(socket)
    send(test, {:request, method, path, request_body})

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(socket)
    serve(listen, rest, test)
  end

  defp read_request(socket, acc \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> data

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [request_line | headers] = String.split(head, "\r\n")
        [method, path, _] = String.split(request_line, " ")

        length =
          Enum.find_value(headers, 0, fn h ->
            case String.split(h, ":", parts: 2) do
              [k, v] ->
                if String.downcase(k) == "content-length", do: String.to_integer(String.trim(v))

              _ ->
                nil
            end
          end)

        {method, path, read_body(socket, body, length)}

      [_] ->
        read_request(socket, acc)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end
end
