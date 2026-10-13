defmodule SlipdockCLI.FSTest do
  @moduledoc """
  Names past U+FFFF on Windows, where Erlang lists them as lone surrogates
  and opens them cut to 16 bits: the spelling each way, worked out here for
  `{:win32, :nt}` whatever this machine is; and the calls themselves, which
  off Windows are `File`'s, on a folder with an emoji in it.
  """
  use ExUnit.Case, async: true

  alias SlipdockCLI.FS

  @win {:win32, :nt}

  describe "native/2" do
    test "on Windows, a path with an emoji goes out as UTF-16 units" do
      # 🎉 is U+1F389: D83C DF89 in UTF-16.
      assert FS.native("C:/v/🎉 Party.md", @win) ==
               ~c"C:/v/" ++ [0xD83C, 0xDF89] ++ ~c" Party.md"
    end

    test "on Windows, a path with nothing past U+FFFF is left as it is" do
      assert FS.native("C:/v/Café — notes.md", @win) == "C:/v/Café — notes.md"
    end

    test "anywhere else, every path is left as it is" do
      assert FS.native("/v/🎉.md", {:unix, :linux}) == "/v/🎉.md"
    end
  end

  describe "from_native/1" do
    test "joins each surrogate pair into the character it spells" do
      assert FS.from_native([0xD83C, 0xDF89] ++ ~c" Party.md") == {:ok, "🎉 Party.md"}
      assert FS.from_native([0xD83D, 0xDE00, 0xD83D, 0xDE80]) == {:ok, "😀🚀"}
    end

    test "is the reverse of native/2" do
      for name <- ["🎉 Party.md", "a😀b🚀c", "plain.md", "Ünïcödé.md", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢"] do
        native = FS.native(name, @win)

        assert FS.from_native(if is_binary(native), do: String.to_charlist(native), else: native) ==
                 {:ok, name}
      end
    end

    test "a surrogate with no partner is no string at all" do
      assert FS.from_native([0xD83C] ++ ~c"x.md") == :error
      assert FS.from_native(~c"x" ++ [0xDF89]) == :error
      assert FS.from_native([0xDF89, 0xD83C]) == :error
    end

    test "a name already a string is kept" do
      assert FS.from_native("🎉.md") == {:ok, "🎉.md"}
    end
  end

  describe "the calls, on a folder with an emoji in it" do
    setup do
      dir = Path.join(System.tmp_dir!(), "slipdock-fs-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "make, write, list, read, stat, rename and remove", %{dir: dir} do
      folder = Path.join(dir, "🎉 Party")
      assert FS.mkdir_p!(Path.join(folder, "deeper")) == :ok
      assert FS.mkdir_p(folder) == :ok

      note = Path.join(folder, "😀 note.md")
      assert FS.write!(note, "hi") == :ok
      assert FS.read!(note) == "hi"
      assert FS.exists?(note)
      assert FS.dir?(folder)
      refute FS.dir?(note)
      assert {:ok, %File.Stat{type: :regular, size: 2}} = FS.stat(note, time: :posix)
      assert {:ok, names} = FS.ls(folder)
      assert Enum.sort(names) == ["deeper", "😀 note.md"]

      moved = Path.join(folder, "🚀 moved.md")
      assert FS.rename!(note, moved) == :ok
      refute FS.exists?(note)
      assert {:ok, device} = FS.open(moved, [:read, :binary])
      assert IO.binread(device, :eof) == "hi"
      assert FS.close(device) == :ok

      assert FS.rm!(moved) == :ok
      assert FS.rmdir(Path.join(folder, "deeper")) == :ok
      assert FS.ls(folder) == {:ok, []}
    end

    test "the ! forms raise with the path, as File's do", %{dir: dir} do
      missing = Path.join(dir, "🎉 nope.md")
      assert_raise File.Error, ~r/🎉 nope.md/, fn -> FS.read!(missing) end
      assert_raise File.Error, fn -> FS.rm!(missing) end
      assert_raise File.RenameError, fn -> FS.rename!(missing, missing <> ".x") end
      assert FS.read(missing) == {:error, :enoent}
      assert FS.ls(missing) == {:error, :enoent}
    end
  end
end
