defmodule SlipdockCLI.FS do
  @moduledoc """
  The file calls the vault code makes, made so that a name with a character
  past U+FFFF in it — an emoji, mostly — works on Windows too.

  Erlang gets those names wrong on Windows, both ways (erl_unicode.c, as of
  OTP 29): a directory listing hands back each UTF-16 unit as a character of
  its own, so an emoji arrives as two lone surrogates that are not Unicode at
  all; and a name handed back is cut to 16 bits a character, so the right
  name opens the wrong file. What does round-trip is a list of the UTF-16
  units themselves. So here a listed name has its surrogate pairs joined into
  the character they spell, and a path going out is spelled in UTF-16 units
  when, and only when, it needs to be. Elixir's `File` turns every path into
  a string first, which a lone surrogate cannot be, so on Windows these call
  `:file` directly. Everywhere else they are `File`'s own.
  """

  @doc """
  `path` as Erlang on `os` will open the right file by: a list of UTF-16
  units on Windows if anything in it is past U+FFFF, else `path` itself.
  """
  def native(path, os \\ :os.type())

  def native(path, {:win32, _}) when is_binary(path) do
    chars = String.to_charlist(path)
    if Enum.any?(chars, &(&1 > 0xFFFF)), do: Enum.flat_map(chars, &utf16_units/1), else: path
  end

  def native(path, _os), do: path

  defp utf16_units(c) when c > 0xFFFF do
    c = c - 0x10000
    [0xD800 + Bitwise.bsr(c, 10), 0xDC00 + Bitwise.band(c, 0x3FF)]
  end

  defp utf16_units(c), do: [c]

  @doc """
  A name as Windows' Erlang lists it, as the string it spells: each surrogate
  pair joined into one character. `:error` for a name with a surrogate that
  has no partner, which Windows allows and no string can hold.
  """
  def from_native(name) when is_binary(name), do: {:ok, name}

  def from_native(name) when is_list(name) do
    case join(name, []) do
      :error -> :error
      chars -> {:ok, List.to_string(chars)}
    end
  end

  defp join([hi, lo | rest], acc) when hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF,
    do: join(rest, [0x10000 + Bitwise.bsl(hi - 0xD800, 10) + (lo - 0xDC00) | acc])

  defp join([c | _], _acc) when c in 0xD800..0xDFFF, do: :error
  defp join([c | rest], acc), do: join(rest, [c | acc])
  defp join([], acc), do: Enum.reverse(acc)

  defp windows?, do: match?({:win32, _}, :os.type())
  defp n(path), do: native(path)

  @doc """
  `File.ls/1`, with names as strings. A name no string can spell is left out
  and said so on stderr, rather than ending the whole walk.
  """
  def ls(path) do
    if windows?() do
      with {:ok, names} <- :file.list_dir(n(path)) do
        {:ok,
         Enum.flat_map(names, fn name ->
           case from_native(name) do
             {:ok, string} ->
               [string]

             :error ->
               IO.puts(:stderr, "skipped a file in #{path}: its name is not valid Unicode")
               []
           end
         end)}
      end
    else
      File.ls(path)
    end
  end

  def read(path), do: if(windows?(), do: :file.read_file(n(path)), else: File.read(path))

  def read!(path) do
    case read(path) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  def write(path, bytes),
    do: if(windows?(), do: :file.write_file(n(path), bytes), else: File.write(path, bytes))

  def write!(path, bytes) do
    case write(path, bytes) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write to file", path: path
    end
  end

  def stat(path, opts \\ []) do
    if windows?() do
      with {:ok, info} <- :file.read_file_info(n(path), opts),
           do: {:ok, File.Stat.from_record(info)}
    else
      File.stat(path, opts)
    end
  end

  def exists?(path), do: match?({:ok, _}, stat(path))
  def dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, stat(path))

  def open(path, modes),
    do: if(windows?(), do: :file.open(n(path), modes), else: File.open(path, modes))

  def close(device), do: File.close(device)

  def rename(from, to),
    do: if(windows?(), do: :file.rename(n(from), n(to)), else: File.rename(from, to))

  def rename!(from, to) do
    case rename(from, to) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.RenameError, reason: reason, action: "rename", source: from, destination: to
    end
  end

  def rm(path), do: if(windows?(), do: :file.delete(n(path)), else: File.rm(path))

  def rm!(path) do
    case rm(path) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "remove file", path: path
    end
  end

  def rmdir(path), do: if(windows?(), do: :file.del_dir(n(path)), else: File.rmdir(path))

  def mkdir_p(path) do
    if windows?() do
      cond do
        dir?(path) ->
          :ok

        Path.dirname(path) == path ->
          {:error, :enoent}

        true ->
          with :ok <- mkdir_p(Path.dirname(path)) do
            case :file.make_dir(n(path)) do
              {:error, :eexist} -> :ok
              other -> other
            end
          end
      end
    else
      File.mkdir_p(path)
    end
  end

  def mkdir_p!(path) do
    case mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory (with -p)", path: path
    end
  end
end
