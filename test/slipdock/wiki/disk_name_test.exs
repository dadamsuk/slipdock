defmodule Slipdock.Wiki.DiskNameTest do
  use ExUnit.Case, async: true

  alias Slipdock.Wiki.DiskName

  describe "clean/1" do
    test "turns separators and Windows' forbidden characters into a dash" do
      assert DiskName.clean(~S(a/b\c:d*e?f"g<h>i|j)) == "a-b-c-d-e-f-g-h-i-j"
    end

    test "drops what breaks a link, and control characters" do
      assert DiskName.clean("Note #1 ^x [draft]\u0007") == "Note 1 x draft"
    end

    test "collapses whitespace" do
      assert DiskName.clean("  a \t b\n c  ") == "a b c"
    end

    test "strips leading dots, and trailing dots and spaces" do
      assert DiskName.clean("..hidden") == "hidden"
      assert DiskName.clean("etc. . ") == "etc"
      assert DiskName.clean("..") == ""
    end

    test "never shortens" do
      long = String.duplicate("word ", 40) |> String.trim()
      assert DiskName.clean(long) == long
    end

    test "gives a reserved name a trailing underscore, any case" do
      for name <- ~w(CON prn Aux NUL COM1 com9 LPT1 lpt9) do
        assert DiskName.clean(name) == name <> "_"
      end

      assert DiskName.clean("CONSOLE") == "CONSOLE"
      assert DiskName.clean("COM10") == "COM10"
    end

    test "catches a reserved name left once the end is tidied" do
      assert DiskName.clean("NUL.") == "NUL_"
    end
  end

  describe "disk_name/3" do
    test "leaves a name within the bound alone" do
      name = String.duplicate("a", 60)
      assert DiskName.disk_name(name) == name
    end

    test "cuts at a word when that keeps at least half, marking the cut" do
      name = String.duplicate("word ", 20)
      cut = DiskName.disk_name(name)

      assert String.ends_with?(cut, "word…")
      assert String.length(cut) <= 60
    end

    test "cuts hard when the last word boundary is under half way" do
      name = "short " <> String.duplicate("x", 100)
      cut = DiskName.disk_name(name)

      assert String.length(cut) == 60
      assert String.starts_with?(cut, "short xxx")
      assert String.ends_with?(cut, "x…")
    end

    test "a cut never leaves a dot, space or dash before the mark" do
      name = String.duplicate("a", 40) <> " - . " <> String.duplicate("b", 40)
      cut = DiskName.disk_name(name)

      assert cut == String.duplicate("a", 40) <> "…"
    end

    test "falls back when nothing is left" do
      assert DiskName.disk_name("###") == "Untitled"
      assert DiskName.disk_name("...", "Card 12") == "Card 12"
    end

    test "counts characters, not bytes" do
      cut = DiskName.disk_name(String.duplicate("é", 80))

      assert String.length(cut) == 60
      assert String.valid?(cut)
    end
  end

  describe "assign/2" do
    test "the oldest keeps the plain name, later ones are numbered in order" do
      assert DiskName.assign([{1, "Note"}, {2, "Note"}, {3, "Note"}]) ==
               %{1 => "Note", 2 => "Note (2)", 3 => "Note (3)"}
    end

    test "compares case aside" do
      assert DiskName.assign([{1, "Note", ".md"}, {2, "note", ".md"}]) ==
               %{1 => "Note.md", 2 => "note (2).md"}
    end

    test "keeps the extension outside the bound and the number inside it" do
      name = String.duplicate("a", 70)

      assert %{1 => first, 2 => second} =
               DiskName.assign([{1, name, ".pdf"}, {2, name, ".pdf"}])

      assert String.length(Path.basename(first, ".pdf")) == 60
      assert String.ends_with?(second, " (2).pdf")
      assert String.length(Path.basename(second, ".pdf")) <= 60
    end

    test "names that differ only past the bound still come apart" do
      a = String.duplicate("x", 70) <> " one"
      b = String.duplicate("x", 70) <> " two"
      names = DiskName.assign([{1, a}, {2, b}])

      assert names[1] != names[2]
    end

    test "a directory and a file of one name don't clash; two of a kind do" do
      assert DiskName.assign([{:dir, "Note"}, {:file, "Note", ".md"}]) ==
               %{dir: "Note", file: "Note.md"}

      assert DiskName.assign([{:a, "Note", ".md"}], ["note.md"]) == %{a: "Note (2).md"}
    end

    test "adding a newer sibling renumbers nothing" do
      before = DiskName.assign([{1, "Note"}, {2, "Note"}])
      later = DiskName.assign([{1, "Note"}, {2, "Note"}, {3, "NOTE"}])

      assert Map.take(later, [1, 2]) == before
    end

    test "steps past a sibling that is really called the numbered name" do
      assert DiskName.assign([{1, "Note"}, {2, "Note (2)"}, {3, "Note"}]) ==
               %{1 => "Note", 2 => "Note (2)", 3 => "Note (3)"}
    end

    test "an empty name takes its fallback, and clashes like any other" do
      assert DiskName.assign([{1, {"###", "Card 7"}}, {2, "???"}, {3, "!"}]) ==
               %{1 => "Card 7", 2 => "-", 3 => "!"}

      assert DiskName.assign([{1, "###"}, {2, "[]"}]) == %{1 => "Untitled", 2 => "Untitled (2)"}
    end
  end
end
