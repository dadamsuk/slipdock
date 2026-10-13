defmodule Slipdock.Wiki.Excalidraw.LZString do
  @moduledoc """
  `LZString.compressToBase64` and `decompressFromBase64`, ported from
  lz-string 1.5, which is what Obsidian's Excalidraw plugin wraps a drawing
  in (its ```compressed-json block). Like the JavaScript, it works on UTF-16
  code units, so text outside the Basic Multilingual Plane comes out the
  same bytes the plugin writes. Checked against vectors made by the npm
  package itself (`test/support/fixtures/lz_string_vectors.json`).
  """

  import Bitwise

  @alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
  @values @alphabet |> String.graphemes() |> Enum.with_index() |> Map.new()

  ## Compressing ----------------------------------------------------------------

  @doc "The string compressed and written as base64, padded as lz-string pads it."
  @spec compress_to_base64(String.t()) :: String.t()
  def compress_to_base64(""), do: ""

  def compress_to_base64(string) when is_binary(string) do
    out = compress(units(string))

    case rem(byte_size(out), 4) do
      0 -> out
      1 -> out <> "==="
      2 -> out <> "=="
      3 -> out <> "="
    end
  end

  defp compress(units) do
    state = %{
      dict: %{},
      to_create: MapSet.new(),
      w: "",
      enlarge_in: 2,
      dict_size: 3,
      num_bits: 2,
      out: [],
      val: 0,
      pos: 0
    }

    state =
      Enum.reduce(units, state, fn unit, s ->
        c = <<unit::16>>

        s =
          if Map.has_key?(s.dict, c),
            do: s,
            else: %{
              s
              | dict: Map.put(s.dict, c, s.dict_size),
                dict_size: s.dict_size + 1,
                to_create: MapSet.put(s.to_create, c)
            }

        wc = s.w <> c

        if Map.has_key?(s.dict, wc) do
          %{s | w: wc}
        else
          s = emit_w(s)
          %{s | dict: Map.put(s.dict, wc, s.dict_size), dict_size: s.dict_size + 1, w: c}
        end
      end)

    state = if state.w == "", do: state, else: emit_w(state)
    state = write(state, 2, state.num_bits)

    state |> flush() |> Map.fetch!(:out) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp emit_w(%{w: <<first::16, _::binary>> = w} = s) do
    s =
      if MapSet.member?(s.to_create, w) do
        s =
          if first < 256,
            do: s |> write(0, s.num_bits) |> write(first, 8),
            else: s |> write(1, s.num_bits) |> write(first, 16)

        %{enlarge(s) | to_create: MapSet.delete(s.to_create, w)}
      else
        write(s, Map.fetch!(s.dict, w), s.num_bits)
      end

    enlarge(s)
  end

  defp enlarge(%{enlarge_in: 1} = s),
    do: %{s | enlarge_in: 1 <<< s.num_bits, num_bits: s.num_bits + 1}

  defp enlarge(s), do: %{s | enlarge_in: s.enlarge_in - 1}

  # `n` bits of `value`, lowest first, six to a character.
  defp write(s, _value, 0), do: s

  defp write(s, value, n) do
    val = s.val <<< 1 ||| (value &&& 1)

    s =
      if s.pos == 5,
        do: %{s | out: [char(val) | s.out], val: 0, pos: 0},
        else: %{s | val: val, pos: s.pos + 1}

    write(s, value >>> 1, n - 1)
  end

  defp flush(s) do
    val = s.val <<< 1

    if s.pos == 5,
      do: %{s | out: [char(val) | s.out]},
      else: flush(%{s | val: val, pos: s.pos + 1})
  end

  defp char(value), do: binary_part(@alphabet, value, 1)

  defp units(string) do
    for <<unit::16 <- :unicode.characters_to_binary(string, :utf8, {:utf16, :big})>>, do: unit
  end

  ## Decompressing --------------------------------------------------------------

  @doc """
  The string lz-string compressed, or `:error` when the input is not
  something it wrote. Whitespace is ignored, since the plugin cuts the
  base64 into lines.
  """
  @spec decompress_from_base64(String.t()) :: {:ok, String.t()} | :error
  def decompress_from_base64(input) when is_binary(input) do
    values =
      input
      |> String.replace(~r/\s+/, "")
      |> String.graphemes()
      |> Enum.map(&Map.get(@values, &1, 0))
      |> List.to_tuple()

    if tuple_size(values) == 0, do: :error, else: decompress(values)
  rescue
    _ -> :error
  end

  defp decompress(values) do
    reader = %{values: values, val: elem(values, 0), pos: 32, index: 1}
    {first, reader} = read(reader, 2)

    with {:ok, c, reader} <- literal(first, reader) do
      dict = %{0 => 0, 1 => 1, 2 => 2, 3 => c}
      loop(reader, dict, 4, 4, 3, c, [c])
    end
  end

  defp literal(0, reader), do: read_char(reader, 8)
  defp literal(1, reader), do: read_char(reader, 16)
  defp literal(_, _reader), do: :error

  defp read_char(reader, bits) do
    {code, reader} = read(reader, bits)
    {:ok, <<code::16>>, reader}
  end

  defp loop(reader, dict, dict_size, enlarge_in, num_bits, w, result) do
    if reader.index > tuple_size(reader.values) do
      :error
    else
      {code, reader} = read(reader, num_bits)

      {code, dict, dict_size, enlarge_in, reader} =
        case code do
          k when k in [0, 1] ->
            {:ok, c, reader} = read_char(reader, if(k == 0, do: 8, else: 16))
            {dict_size, Map.put(dict, dict_size, c), dict_size + 1, enlarge_in - 1, reader}

          _ ->
            {code, dict, dict_size, enlarge_in, reader}
        end

      if code == 2 do
        result |> Enum.reverse() |> IO.iodata_to_binary() |> to_utf8()
      else
        {enlarge_in, num_bits} = bump(enlarge_in, num_bits)

        entry =
          case dict do
            %{^code => entry} when is_binary(entry) -> entry
            _ when code == dict_size -> w <> binary_part(w, 0, 2)
            _ -> nil
          end

        if entry do
          dict = Map.put(dict, dict_size, w <> binary_part(entry, 0, 2))
          {enlarge_in, num_bits} = bump(enlarge_in - 1, num_bits)
          loop(reader, dict, dict_size + 1, enlarge_in, num_bits, entry, [entry | result])
        else
          :error
        end
      end
    end
  end

  defp bump(0, num_bits), do: {1 <<< num_bits, num_bits + 1}
  defp bump(enlarge_in, num_bits), do: {enlarge_in, num_bits}

  defp read(reader, n), do: read(reader, n, 0, 1)

  defp read(reader, 0, bits, _power), do: {bits, reader}

  defp read(reader, n, bits, power) do
    bit = if (reader.val &&& reader.pos) > 0, do: power, else: 0
    pos = reader.pos >>> 1

    reader =
      if pos == 0 do
        next =
          if reader.index < tuple_size(reader.values),
            do: elem(reader.values, reader.index),
            else: 0

        %{reader | pos: 32, val: next, index: reader.index + 1}
      else
        %{reader | pos: pos}
      end

    read(reader, n - 1, bits ||| bit, power <<< 1)
  end

  defp to_utf8(utf16) do
    case :unicode.characters_to_binary(utf16, {:utf16, :big}, :utf8) do
      text when is_binary(text) -> {:ok, text}
      _ -> :error
    end
  end
end
