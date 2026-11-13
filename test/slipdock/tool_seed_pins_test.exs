defmodule Slipdock.ToolSeedPinsTest do
  @moduledoc """
  A built-in Tool's version says which seed a board holds (#2908): the
  Handbook Tool's seed text changed twice within 1.8.0 with no bump (#2601,
  #2065), and after that the version no longer said. So each Tool's seed is
  pinned here as a digest beside its version, and neither moves without the
  other: a seed changed under the same version fails, saying to bump it.

  To re-pin after a meant change: bump the Tool's `@version` (and give the
  old seed an upgrade path, as `Handbook.seed_body/2` does), run this file,
  and copy the pair the failure prints into `@pins`.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Handbook
  alias Slipdock.Sweep

  @file Path.relative_to_cwd(__ENV__.file)

  # {the Tool's version, the SHA-256 of its seed}.
  @pins %{
    "handbook" => {"1.9.1", "b20d3ee9417d66ddc084a1cc60b2abfb8fd29eab838090b7934ff77504ef68ed"},
    "sweep" => {"1.2.0", "4f909bba15a250fcf53912f9a5b9b7486dcb4495a28eb1e64191f550c677fe64"}
  }

  # What an install puts on a board. The Handbook's blueprint holds every
  # page with its front matter and rules skeleton, Before you push and A
  # runner machine among them, and the three cards. The Sweep's page changes
  # with the board's areas, so it is taken empty and with a row, and its
  # card's bar is a seed of its own.
  defp seed("handbook"), do: Handbook.blueprint()

  defp seed("sweep") do
    [
      Sweep.blueprint(),
      Sweep.blueprint([{"An area", ["lib/app/**", "test/app/**"]}]),
      Sweep.card_bar("W-1")
    ]
  end

  defp version("handbook"), do: Handbook.version()
  defp version("sweep"), do: Sweep.version()

  @doc false
  # The digest of a seed: the same for the same text on any OTP, whatever
  # order a map's keys come in.
  def digest(seed) do
    :crypto.hash(:sha256, canonical(seed)) |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    pairs =
      for {key, value} <- Enum.sort(Map.to_list(map)), do: [canonical(key), canonical(value)]

    ["{", pairs, "}"]
  end

  defp canonical(list) when is_list(list), do: ["[", Enum.map(list, &canonical/1), "]"]
  defp canonical(tuple) when is_tuple(tuple), do: canonical(Tuple.to_list(tuple))
  defp canonical(nil), do: "~"

  defp canonical(text) when is_binary(text),
    do: [Integer.to_string(byte_size(text)), ":", text]

  @doc false
  # Whether a Tool as it is now (`{version, digest}`) is the one pinned:
  # `:ok`, or `{:error, what to do}`.
  def check(tool, {version, digest}, {version, digest}) when is_binary(tool), do: :ok

  def check(tool, {version, _pinned}, {version, digest}) do
    {:error,
     "The #{tool} Tool's seed text changed and its version is still #{version}. " <>
       "Bump @version, so the version says which seed a board holds, then pin " <>
       ~s(#{inspect(tool)} => {"<the new version>", #{inspect(digest)}} in #{@file}.)}
  end

  def check(tool, {pinned, _}, {version, digest}) do
    {:error,
     "The #{tool} Tool's version went from #{pinned} to #{version}. " <>
       "Pin #{inspect(tool)} => #{inspect({version, digest})} in #{@file}."}
  end

  for tool <- ["handbook", "sweep"] do
    test "the #{tool} Tool's seed is the one pinned for its version" do
      tool = unquote(tool)

      case check(tool, Map.fetch!(@pins, tool), {version(tool), digest(seed(tool))}) do
        :ok -> :ok
        {:error, what} -> flunk(what)
      end
    end
  end

  test "every built-in Tool with a version has a pin" do
    assert Enum.sort(Map.keys(@pins)) == Enum.sort([Handbook.name(), Sweep.name()])
  end

  describe "check/3" do
    test "passes the pinned version and digest" do
      assert check("handbook", {"1.9.1", "aa"}, {"1.9.1", "aa"}) == :ok
    end

    test "a seed changed under the same version fails, asking for a bump" do
      assert {:error, what} = check("handbook", {"1.9.1", "aa"}, {"1.9.1", "bb"})
      assert what =~ "seed text changed"
      assert what =~ "still 1.9.1"
      assert what =~ "Bump @version"
      assert what =~ ~s("bb")
    end

    test "a version changed without the pin fails, with the pair to pin" do
      for digest <- ["aa", "bb"] do
        assert {:error, what} = check("sweep", {"1.2.0", "aa"}, {"1.3.0", digest})
        assert what =~ "from 1.2.0 to 1.3.0"
        assert what =~ ~s("sweep" => {"1.3.0", "#{digest}"})
        refute what =~ "Bump"
      end
    end
  end

  describe "digest/1" do
    test "changes with one character of a page's body" do
      seed = Handbook.blueprint()
      [index | rest] = seed["pages"]
      edited = %{seed | "pages" => [%{index | "body" => index["body"] <> "."} | rest]}

      assert digest(edited) != digest(seed)
      assert digest(seed) == digest(Handbook.blueprint())
    end

    test "changes with a card's description, and with the Sweep's lenses row" do
      seed = Handbook.blueprint()
      [card | rest] = seed["cards"]
      edited = %{seed | "cards" => [%{card | "description" => card["description"] <> " "} | rest]}
      assert digest(edited) != digest(seed)

      assert digest(seed("sweep")) != digest([Sweep.blueprint(), Sweep.card_bar("W-1")])
    end

    test "tells text moved between two fields from text left where it was" do
      assert digest(%{"a" => "xy", "b" => ""}) != digest(%{"a" => "x", "b" => "y"})
      assert digest(["ab"]) != digest(["a", "b"])
      assert digest(%{"a" => nil}) != digest(%{"a" => ""})
    end

    test "doesn't depend on the order a map was built in" do
      assert digest(Map.new([{"a", "1"}, {"b", "2"}])) ==
               digest(Map.new([{"b", "2"}, {"a", "1"}]))
    end
  end
end
