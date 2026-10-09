defmodule Slipdock.AIStub do
  @moduledoc """
  Stands in for OpenRouter in tests: `config :slipdock, :ai` routes `Req`
  through `Req.Test`, and these helpers script the answers. A stub is seen by
  the test and whatever it starts (LiveViews, tasks), which find it through
  `$callers`; `share/0` is only for code that runs in a process started at
  boot — the search indexer — and makes the test `async: false`.

  All three endpoints the app uses go through one stub, told apart by path:
  `/chat/completions` (see `reply_with/1` and `reply_sequence/1`),
  `/embeddings` (always answered, see `fake_vector/2`) and `/models` (see
  `stub_models/1`, always answered with `default_models/0`).
  """

  @doc """
  Lets every process use the stubs set by this test, including ones started
  at boot such as `Slipdock.Search.Indexer`. Global, so only in sync tests.
  """
  def share(_context \\ %{}) do
    Req.Test.set_req_test_to_shared()
    ExUnit.Callbacks.on_exit(fn -> Req.Test.set_req_test_to_private() end)
    :ok
  end

  @doc """
  Answers the next calls with `content` (a string, or a map encoded as
  JSON). Each request's decoded body is sent to the test process as
  `{:ai_request, body}` so prompts can be asserted on.
  """
  def reply_with(content), do: reply_sequence([content])

  @doc """
  Scripts a series of chat answers, one per call, the last repeating once
  the list runs out. Each entry is a string, a map (encoded as JSON), or
  `{:tool_calls, [{name, args_map}]}` for a turn where the model asks for a
  tool instead of answering, or `{:cut_off, text}` for an answer that ran
  out of tokens part-way — which is how `Slipdock.AI.Researcher` is driven.
  """
  def reply_sequence(replies) when is_list(replies) and replies != [] do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> replies end)

    Req.Test.stub(Slipdock.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      cond do
        embeddings?(conn) ->
          send(test_pid, {:embed_request, decoded})
          Req.Test.json(conn, embeddings_body(decoded))

        models?(conn) ->
          Req.Test.json(conn, %{"data" => default_models()})

        true ->
          send(test_pid, {:ai_request, decoded})
          Req.Test.json(conn, chat_body(next(agent)))
      end
    end)
  end

  @doc """
  Answers embedding calls only; a chat call fails. For tests about the index
  and the search, where no model should be asked to say anything.
  """
  def stub_embeddings do
    test_pid = self()

    Req.Test.stub(Slipdock.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      cond do
        embeddings?(conn) ->
          send(test_pid, {:embed_request, decoded})
          Req.Test.json(conn, embeddings_body(decoded))

        models?(conn) ->
          Req.Test.json(conn, %{"data" => default_models()})

        true ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{"error" => %{"message" => "no chat answer was scripted"}})
      end
    end)
  end

  @doc """
  Answers `GET /models` with `models` — a list of ids, or of maps in the
  shape an OpenAI-compatible server returns. Chat and embedding calls fail,
  as with `stub_embeddings/0`, so a test about the model picker says so.
  """
  def stub_models(models) do
    data =
      Enum.map(models, fn
        id when is_binary(id) -> %{"id" => id}
        %{} = model -> model
      end)

    Req.Test.stub(Slipdock.AI, fn conn ->
      if models?(conn) do
        Req.Test.json(conn, %{"data" => data})
      else
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"message" => "only the model list was stubbed"}})
      end
    end)
  end

  @doc "The models every stub lists unless told otherwise."
  def default_models do
    [
      %{"id" => "test/model", "name" => "Test Model"},
      %{"id" => "test/other-model"},
      %{"id" => "test/text-embedding-small"}
    ]
  end

  @doc "Fails the next calls with an HTTP status and an OpenRouter-style error."
  def fail_with(status, message) do
    Req.Test.stub(Slipdock.AI, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => %{"message" => message, "code" => status}})
    end)
  end

  @dimensions 64

  @doc """
  A deterministic stand-in for a real embedding: a bag of words, one
  dimension per hashed token.

  It is not semantic — "car" and "automobile" land in unrelated dimensions —
  but it has the one property the tests need, which is that texts sharing
  words score higher against each other than texts that don't. That makes
  ranking, the relevance floor and the keyword boost all testable without a
  network call, and keeps the tests honest about the plumbing rather than
  about the model's judgement.
  """
  def fake_vector(text, dimensions \\ @dimensions) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reduce(List.duplicate(0.0, dimensions), fn word, acc ->
      index = :erlang.phash2(word, dimensions)
      List.update_at(acc, index, &(&1 + 1.0))
    end)
  end

  ## Response bodies ----------------------------------------------------------

  defp embeddings?(conn), do: String.ends_with?(conn.request_path, "/embeddings")

  defp models?(conn), do: String.ends_with?(conn.request_path, "/models")

  defp embeddings_body(%{"input" => input} = body) do
    inputs = List.wrap(input)
    dimensions = body["dimensions"] || @dimensions

    %{
      "object" => "list",
      "model" => body["model"],
      "data" =>
        inputs
        |> Enum.with_index()
        |> Enum.map(fn {text, i} ->
          %{"object" => "embedding", "index" => i, "embedding" => fake_vector(text, dimensions)}
        end),
      "usage" => %{"prompt_tokens" => length(inputs) * 10, "total_tokens" => length(inputs) * 10}
    }
  end

  defp chat_body({:tool_calls, calls}) do
    tool_calls =
      calls
      |> Enum.with_index()
      |> Enum.map(fn {{name, args}, i} ->
        %{
          "id" => "call_#{i}",
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
        }
      end)

    envelope(%{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls})
  end

  # An answer that hit the token limit: what the model had written so far,
  # with `finish_reason: "length"`.
  defp chat_body({:cut_off, text}) do
    %{"role" => "assistant", "content" => text}
    |> envelope()
    |> update_in(["choices"], fn [choice] -> [Map.put(choice, "finish_reason", "length")] end)
  end

  defp chat_body(content),
    do: envelope(%{"role" => "assistant", "content" => encode(content)})

  defp envelope(message) do
    %{
      "id" => "gen-test",
      "model" => "test/model",
      "choices" => [%{"message" => message}],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
    }
  end

  # The last scripted answer stands for every call after it, so a test only
  # has to script the turns it cares about.
  defp next(agent) do
    Agent.get_and_update(agent, fn
      [only] -> {only, [only]}
      [head | tail] -> {head, tail}
    end)
  end

  defp encode(content) when is_binary(content), do: content
  defp encode(content), do: Jason.encode!(content)
end
