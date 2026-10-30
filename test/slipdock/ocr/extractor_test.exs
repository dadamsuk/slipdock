defmodule Slipdock.OCR.ExtractorTest do
  @moduledoc """
  How a file becomes text, with the programs replaced by a function: which is
  called on what, and what comes of each way they can answer.
  """
  use ExUnit.Case, async: true

  alias Slipdock.OCR.Extractor
  alias Slipdock.TestConfig

  @png <<0x89, "PNG", 13, 10, 26, 10, 0, 0>>

  setup do
    dir = Path.join(System.tmp_dir!(), "extractor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "file.bin")
    File.write!(path, @png)
    %{path: path}
  end

  # `answers` is a function of the program and its args; each call is reported
  # to the test.
  defp programs(answers, opts \\ []) do
    test = self()

    TestConfig.put(
      :ocr,
      [
        run: fn program, args ->
          send(test, {:ran, program, args})
          answers.(program, args)
        end
      ] ++ opts
    )
  end

  describe "kind/2" do
    test "goes by type, and a .pdf is one whatever it was sent as" do
      assert Extractor.kind("application/pdf", "a") == :pdf
      assert Extractor.kind("application/octet-stream", "Scan.PDF") == :pdf
      assert Extractor.kind("image/jpeg", "a.jpg") == :image
      assert Extractor.kind("image/tiff", "a.tif") == :image
    end

    test "leaves everything else alone" do
      assert Extractor.kind("text/plain", "a.txt") == nil
      assert Extractor.kind("image/svg+xml", "a.svg") == nil
      assert Extractor.kind("application/octet-stream", nil) == nil
    end
  end

  test "available?/0 is true with a stand-in for the programs" do
    programs(fn _, _ -> {"", 0} end)
    assert Extractor.available?()
  end

  describe "an image" do
    test "goes to tesseract, in the configured languages", %{path: path} do
      programs(fn "tesseract", _ -> {"  Invoice 42\f", 0} end, langs: "eng+deu")

      assert {:ok, %{text: "Invoice 42", pages: 1, ocr_pages: 1, truncated: false}} =
               Extractor.extract(path, :image)

      assert_received {:ran, "tesseract", [^path, "stdout", "-l", "eng+deu", "quiet"]}
    end

    test "a NUL and broken UTF-8 never reach the database", %{path: path} do
      programs(fn "tesseract", _ -> {"a" <> <<0>> <> "b" <> <<0xFF>> <> "c", 0} end)

      assert {:ok, %{text: "abc"}} = Extractor.extract(path, :image)
    end

    test "no words is an answer, not a failure", %{path: path} do
      programs(fn "tesseract", _ -> {"\n\f", 0} end)
      assert {:ok, %{text: ""}} = Extractor.extract(path, :image)
    end

    test "text sent as an image never reaches tesseract, which would read it as paths", %{
      path: path
    } do
      programs(fn _, _ -> flunk("nothing should run") end)
      File.write!(path, "/data/uploads/12/someone-elses.png\n")

      assert {:error, "the file isn't an image, whatever it was sent as"} =
               Extractor.extract(path, :image)
    end

    test "every kind of image it reads is recognised by its first bytes", %{path: path} do
      programs(fn "tesseract", _ -> {"words", 0} end)

      for start <- [
            @png,
            <<0xFF, 0xD8, 0xFF, 0xE0>>,
            "GIF89a",
            "RIFF" <> <<1, 2, 3, 4>> <> "WEBPVP8 ",
            "II" <> <<42, 0, 8, 0>>,
            "MM" <> <<0, 42, 0, 8>>,
            "BM" <> <<1, 2, 3, 4>>
          ] do
        File.write!(path, start)
        assert {:ok, %{text: "words"}} = Extractor.extract(path, :image)
      end
    end

    test "a file tesseract can't open is the reason", %{path: path} do
      programs(fn "tesseract", _ -> {"", 1} end)
      assert {:error, "the image can't be read"} = Extractor.extract(path, :image)
    end

    test "running out of time says so", %{path: path} do
      programs(fn "tesseract", _ -> {"", 124} end)
      assert {:error, "tesseract ran out of time"} = Extractor.extract(path, :image)
    end

    test "more text than the limit is cut, and says so", %{path: path} do
      programs(fn "tesseract", _ -> {String.duplicate("é", 50), 0} end, max_chars: 10)

      assert {:ok, %{text: text, truncated: true}} = Extractor.extract(path, :image)
      assert text == String.duplicate("é", 10)
    end
  end

  describe "a PDF" do
    @long "This page has a proper text layer, long enough to be believed."

    test "with a text layer is never drawn", %{path: path} do
      programs(fn "pdftotext", _ -> {@long <> "\f" <> @long <> " Two.\f", 0} end)

      assert {:ok, %{text: text, pages: 2, ocr_pages: 0, truncated: false}} =
               Extractor.extract(path, :pdf)

      assert text == @long <> "\n\n" <> @long <> " Two."
      refute_received {:ran, "pdftoppm", _}
      refute_received {:ran, "tesseract", _}
    end

    test "reads a scanned page by drawing that page alone", %{path: path} do
      test = self()

      programs(fn
        "pdftotext", _ ->
          {@long <> "\f  \f", 0}

        "pdftoppm", args ->
          # Tesseract gets the file pdftoppm was told to write.
          send(test, {:base, List.last(args)})
          {"", 0}

        "tesseract", ["/" <> _ = png | _] ->
          assert_received {:base, base}
          assert png == base <> ".png"
          {"Scanned words", 0}
      end)

      assert {:ok, %{text: text, pages: 2, ocr_pages: 1}} = Extractor.extract(path, :pdf)
      assert text == @long <> "\n\nScanned words"

      assert_received {:ran, "pdftoppm", args}
      assert ["-f", "2", "-l", "2"] -- args == []
      refute File.exists?(Path.dirname(List.last(args)))
    end

    test "asks pdftotext for no more pages than the limit, and says when it hit it", %{
      path: path
    } do
      programs(fn "pdftotext", _ -> {@long <> "\f" <> @long <> "\f", 0} end, max_pages: 2)

      assert {:ok, %{pages: 2, truncated: true}} = Extractor.extract(path, :pdf)
      assert_received {:ran, "pdftotext", args}
      assert ["-l", "2"] -- args == []
    end

    test "stops drawing pages at the limit, keeps what it has", %{path: path} do
      programs(
        fn
          "pdftotext", _ -> {"\f\f\f", 0}
          "pdftoppm", _ -> {"", 0}
          "tesseract", _ -> {"Scanned", 0}
        end,
        max_ocr_pages: 2
      )

      assert {:ok, %{text: "Scanned\n\nScanned", ocr_pages: 2, truncated: true}} =
               Extractor.extract(path, :pdf)
    end

    test "stops drawing pages when the time is up", %{path: path} do
      programs(fn "pdftotext", _ -> {"\f\f", 0} end, deadline_ms: -1)

      assert {:ok, %{text: "", ocr_pages: 0, truncated: true}} = Extractor.extract(path, :pdf)
      refute_received {:ran, "pdftoppm", _}
    end

    test "one page it can't draw doesn't lose the others", %{path: path} do
      programs(fn
        "pdftotext", _ -> {@long <> "\f\f", 0}
        "pdftoppm", _ -> {"", 1}
      end)

      assert {:ok, %{text: @long, ocr_pages: 0}} = Extractor.extract(path, :pdf)
    end

    test "a scan with no page that could be read is a failure, not an empty file", %{path: path} do
      programs(fn
        "pdftotext", _ -> {"\f\f", 0}
        "pdftoppm", _ -> {"", 1}
      end)

      assert {:error, "the scanned pages couldn't be read"} = Extractor.extract(path, :pdf)
    end

    test "a locked or damaged PDF is the reason", %{path: path} do
      programs(fn "pdftotext", _ -> {"", 1} end)

      assert {:error, "the PDF can't be read; it may be damaged or locked"} =
               Extractor.extract(path, :pdf)
    end

    test "a PDF with no pages is empty", %{path: path} do
      programs(fn "pdftotext", _ -> {"", 0} end)
      assert {:ok, %{text: "", pages: 0}} = Extractor.extract(path, :pdf)
    end
  end

  test "a file missing from disk or over the limit is not given to any program", %{path: path} do
    programs(fn _, _ -> flunk("nothing should run") end, max_bytes: 2)

    assert {:error, "the file is not on disk"} = Extractor.extract(path <> ".gone", :pdf)
    assert {:error, "the file is too large to read"} = Extractor.extract(path, :image)
  end
end
