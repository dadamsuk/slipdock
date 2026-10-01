defmodule Slipdock.Search.Vector do
  @moduledoc """
  The arithmetic behind semantic search: vectors as packed binaries, and the
  similarity between two of them.

  A vector is stored as its dimensions in order, each a 32-bit little-endian
  float — 3 KB for the 768 dimensions we ask for, against 13 KB for the same
  numbers as JSON, and no parsing on the way back in.

  Every vector is unit length by the time it gets here (see
  `Slipdock.AI.Embeddings`), so cosine similarity is just the dot product and
  nothing has to be divided at query time. `similarity/2` is what search
  runs over every candidate row, so it matters that it is quick: it walks
  both binaries four floats at a time, which is roughly four times faster
  than one at a time for the cost of one extra clause.

  There is no index and no approximation — the whole candidate set is
  scored. At this app's size (a few thousand chunks) that is a handful of
  milliseconds and always exact; if the corpus ever reaches six figures,
  this module is the seam where an ANN index or sqlite-vec would go, and
  nothing above it would change.
  """

  @doc "Packs a list of floats into the stored binary form."
  @spec pack([number]) :: binary
  def pack(floats) when is_list(floats) do
    for f <- floats, into: <<>>, do: <<f * 1.0::float-32-little>>
  end

  @doc "Unpacks a stored binary back into a list of floats."
  @spec unpack(binary) :: [float]
  def unpack(binary) when is_binary(binary) do
    for <<f::float-32-little <- binary>>, do: f
  end

  @doc "How many dimensions a packed vector holds."
  @spec size(binary) :: non_neg_integer
  def size(binary) when is_binary(binary), do: div(byte_size(binary), 4)

  @doc """
  Cosine similarity of two packed vectors, from -1.0 to 1.0. Vectors of
  different lengths score 0.0 rather than raising: that only happens when
  the index holds rows from an older model, and a stale row should sink
  rather than break the search.
  """
  @spec similarity(binary, binary) :: float
  def similarity(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: dot(a, b, 0.0)

  def similarity(_, _), do: 0.0

  defp dot(
         <<a1::float-32-little, a2::float-32-little, a3::float-32-little, a4::float-32-little,
           rest_a::binary>>,
         <<b1::float-32-little, b2::float-32-little, b3::float-32-little, b4::float-32-little,
           rest_b::binary>>,
         acc
       ) do
    dot(rest_a, rest_b, acc + a1 * b1 + a2 * b2 + a3 * b3 + a4 * b4)
  end

  defp dot(<<a::float-32-little, rest_a::binary>>, <<b::float-32-little, rest_b::binary>>, acc) do
    dot(rest_a, rest_b, acc + a * b)
  end

  defp dot(_, _, acc), do: acc
end
