defmodule Slipdock.AI.Embeddings do
  @moduledoc """
  Turns text into vectors, through the OpenAI-compatible `/embeddings`
  endpoint of whatever the server's AI provider is (OpenRouter, or a local
  model server — see `Slipdock.AI.provider/1`). The counterpart to `Slipdock.AI` (which does chat
  completions); everything semantic search stores comes through here.

  Configured under `config :slipdock, :ai`:

    * `:embed_model` — the embedding model id (`SLIPDOCK_AI_EMBED_MODEL`),
      default `openai/text-embedding-3-small`. An `embed_model` stored for
      the system user (Account → AI model) wins, since a local endpoint will
      not have OpenRouter's
    * `:embed_dimensions` — how many dimensions to ask for
      (`SLIPDOCK_AI_EMBED_DIMENSIONS`), default 768. Only Matryoshka models
      honour this; `nil` leaves it to the model.

  Vectors come back **normalised to unit length**, so the cosine similarity
  of two of them is their dot product and `Slipdock.Search.Vector` never has
  to divide. Both the model and the dimension are stored alongside every
  embedding, because changing either invalidates the whole index.
  """

  require Logger

  alias Slipdock.AI

  # OpenRouter accepts large batches; this keeps one request well inside the
  # token ceiling of the smaller models while still amortising the round trip.
  @batch 64

  @doc """
  The embedding model in use. Indexing is one shared index, so this is the
  system provider's choice (see `Slipdock.AI.Keys.system_settings/0`) rather
  than any one person's — and it is stored with every vector, because
  changing it invalidates them all.
  """
  def model do
    Slipdock.AI.Keys.system_settings().embed_model || config()[:embed_model] ||
      "openai/text-embedding-3-small"
  end

  @doc "How many dimensions vectors are asked for, or nil for the model's own."
  def dimensions, do: config()[:embed_dimensions]

  @doc """
  Whether embeddings can be made at all. Indexing is unattended work, so it
  uses the system key (see `Slipdock.AI.Keys.system_key/0`) rather than any one
  person's.
  """
  def configured?, do: AI.configured?()

  @doc """
  Embeds one string. Returns `{:ok, vector}` (a list of floats, unit length)
  or `{:error, message}`.
  """
  def embed(text) when is_binary(text) do
    case embed_all([text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:ok, _} -> {:error, "The embedding model returned the wrong number of vectors."}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Embeds a list of strings, in batches, preserving order. Returns
  `{:ok, vectors}` or `{:error, message}`; one failed batch fails the lot,
  since a partial result would silently leave holes in the index.
  """
  def embed_all([]), do: {:ok, []}

  def embed_all(texts) when is_list(texts) do
    with {:ok, provider} <- AI.provider([]) do
      texts
      |> Enum.map(&trim/1)
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
        case post(batch, provider) do
          {:ok, vectors} -> {:cont, {:ok, acc ++ vectors}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp post(batch, provider) do
    body =
      %{model: model(), input: batch, encoding_format: "float"}
      |> maybe_dimensions(dimensions())

    started = System.monotonic_time(:millisecond)

    case Req.post(AI.request(provider), url: "/embeddings", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        Logger.info(
          "Embedded #{length(batch)} chunks with #{model()} in " <>
            "#{System.monotonic_time(:millisecond) - started}ms"
        )

        vectors =
          data
          # The spec says the order matches the input, but the index is given
          # so it costs nothing to be sure.
          |> Enum.sort_by(&(&1["index"] || 0))
          |> Enum.map(&normalise(&1["embedding"]))

        if length(vectors) == length(batch) and Enum.all?(vectors, &is_list/1) do
          {:ok, vectors}
        else
          {:error,
           "The embedding model returned #{length(vectors)} vectors for #{length(batch)} inputs."}
        end

      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.warning("Embedding call returned no data: #{inspect(body)}")
        {:error, "The embedding model returned nothing."}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Embedding call failed with #{status}: #{inspect(body)}")
        {:error, AI.api_error(status, body)}

      {:error, exception} ->
        Logger.warning("Embedding call failed: #{Exception.message(exception)}")
        {:error, "Couldn't reach the embedding model (#{Exception.message(exception)})."}
    end
  end

  defp maybe_dimensions(body, nil), do: body
  defp maybe_dimensions(body, dims) when is_integer(dims), do: Map.put(body, :dimensions, dims)

  # An empty string is rejected by most providers, and a chunk longer than the
  # model's context is truncated by them anyway — better to do it here, on a
  # character budget generous enough for any card, so the request is predictable.
  @max_chars 24_000
  defp trim(text) do
    case text |> to_string() |> String.trim() |> String.slice(0, @max_chars) do
      "" -> " "
      trimmed -> trimmed
    end
  end

  # Unit length, so cosine similarity is a plain dot product later.
  defp normalise(embedding) when is_list(embedding) do
    norm = embedding |> Enum.reduce(0.0, &(&2 + &1 * &1)) |> :math.sqrt()

    if norm > 0.0, do: Enum.map(embedding, &(&1 / norm)), else: embedding
  end

  defp normalise(_), do: nil

  defp config, do: Application.get_env(:slipdock, :ai, [])
end
