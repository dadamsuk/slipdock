defmodule Slipdock.OCR.Extractor do
  @moduledoc """
  Gets the words out of a file on disk, with programs on this machine, so what
  is in a document never leaves the server:

    * a PDF goes through `pdftotext`, and any page that gives back next to
      nothing is a scan: it is drawn with `pdftoppm` and read by `tesseract`;
    * an image goes straight to `tesseract`.

  Uploads are anybody's bytes, and these programs parse them, so every run has
  a time limit and a low priority, and a document has limits on its pages, its
  text and how long it may take in all. Reaching one keeps what was read and
  says `truncated`. They are the `:ocr` config, for a test to shrink:
  `:langs`, `:timeout_seconds`, `:max_bytes`, `:max_pages`, `:max_ocr_pages`,
  `:max_chars` and `:deadline_ms`.

  `:run` in the same config replaces the programs in tests: a function of the
  program's name and its arguments, answering `{output, exit_status}`.
  `:programs` names what has to be installed, for a test of a machine without.
  """

  @pdf "application/pdf"
  @images ~w(image/png image/jpeg image/gif image/webp image/tiff image/bmp)
  @programs ~w(pdftotext pdftoppm tesseract timeout nice)

  @timeout_seconds 120
  @max_bytes 100 * 1024 * 1024
  @max_pages 500
  @max_ocr_pages 100
  @max_chars 1_000_000
  @deadline_ms 30 * 60 * 1000
  # Fewer characters than this on a PDF page and it is a scan, or a footer on
  # a scan. A real page of text is never this short for long.
  @thin_page 25
  @dpi "200"

  @doc "The content types worth reading. A file named `.pdf` is one whatever it was sent as."
  def types, do: [@pdf | @images]

  @doc "How to read a file of this type and name: `:pdf`, `:image`, or nil for not at all."
  def kind(content_type, name) do
    cond do
      content_type == @pdf -> :pdf
      content_type in @images -> :image
      name |> to_string() |> Path.extname() |> String.downcase() == ".pdf" -> :pdf
      true -> nil
    end
  end

  @doc "Whether this machine has the programs. An image built before #1527 doesn't."
  def available? do
    programs = config()[:programs]

    if is_nil(programs) and is_function(config()[:run], 2),
      do: true,
      else: Enum.all?(programs || @programs, &System.find_executable/1)
  end

  @doc """
  The words in the file at `path`, read as `kind`:
  `{:ok, %{text:, pages:, ocr_pages:, truncated:}}`, or `{:error, reason}` in
  words a person can act on.
  """
  def extract(path, kind) do
    with :ok <- check(path), do: read(path, kind)
  end

  defp check(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} ->
        if size <= limit(:max_bytes, @max_bytes),
          do: :ok,
          else: {:error, "the file is too large to read"}

      _ ->
        {:error, "the file is not on disk"}
    end
  end

  defp read(path, :image) do
    with :ok <- image?(path),
         {:ok, text} <- tesseract(path) do
      {text, truncated?} = cap(clean(text))
      {:ok, %{text: text, pages: 1, ocr_pages: 1, truncated: truncated?}}
    end
  end

  defp read(path, :pdf) do
    max_pages = limit(:max_pages, @max_pages)

    args = ["-enc", "UTF-8", "-q", "-l", "#{max_pages}", path, "-"]

    case run("pdftotext", args) do
      {output, 0} ->
        output |> pages() |> read_pages(path, max_pages)

      {_, status} ->
        {:error,
         failed("pdftotext", status, "the PDF can't be read; it may be damaged or locked")}
    end
  end

  # The content type is whatever the uploader said. Tesseract takes a file it
  # doesn't recognise as a list of paths to read, so an "image" of a few lines
  # of text would have it read other people's files off this disk into the
  # uploader's search results. Only bytes that really open like an image go in.
  defp image?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 12)) do
      {:ok, <<0x89, "PNG", _::binary>>} -> :ok
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> :ok
      {:ok, <<"GIF8", _::binary>>} -> :ok
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> :ok
      {:ok, <<"II", 42, 0, _::binary>>} -> :ok
      {:ok, <<"MM", 0, 42, _::binary>>} -> :ok
      {:ok, <<"BM", _::binary>>} -> :ok
      _ -> {:error, "the file isn't an image, whatever it was sent as"}
    end
  end

  # `pdftotext` ends every page with a form feed, so the last piece is nothing.
  defp pages(output) do
    output
    |> clean_keeping_pages()
    |> String.split("\f")
    |> Enum.drop(-1)
  end

  defp read_pages(pages, path, max_pages) do
    deadline = System.monotonic_time(:millisecond) + limit(:deadline_ms, @deadline_ms)

    state = %{left: limit(:max_ocr_pages, @max_ocr_pages), read: 0, failed: 0, skipped: 0}

    {texts, state} =
      pages
      |> Enum.with_index(1)
      |> Enum.map_reduce(state, fn {text, n}, state ->
        if String.length(String.trim(text)) >= @thin_page,
          do: {text, state},
          else: scanned(text, path, n, state, deadline)
      end)

    if state.read == 0 and state.failed > 0 and Enum.all?(texts, &(String.trim(&1) == "")) do
      {:error, "the scanned pages couldn't be read"}
    else
      {text, cut?} = texts |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> join_pages()

      {:ok,
       %{
         text: text,
         pages: length(pages),
         ocr_pages: state.read,
         truncated: cut? or state.skipped > 0 or length(pages) >= max_pages
       }}
    end
  end

  defp join_pages(texts), do: texts |> Enum.join("\n\n") |> cap()

  defp scanned(text, _path, _n, %{left: 0} = state, _deadline),
    do: {text, %{state | skipped: state.skipped + 1}}

  defp scanned(text, path, n, state, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {text, %{state | skipped: state.skipped + 1}}
    else
      case ocr_page(path, n) do
        {:ok, read} -> {read, %{state | left: state.left - 1, read: state.read + 1}}
        :error -> {text, %{state | left: state.left - 1, failed: state.failed + 1}}
      end
    end
  end

  defp ocr_page(path, n) do
    dir = Path.join(System.tmp_dir!(), "slipdock-ocr-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    base = Path.join(dir, "page")

    try do
      args = ["-q", "-r", @dpi, "-gray", "-png", "-singlefile", "-f", "#{n}", "-l", "#{n}"]

      with {_, 0} <- run("pdftoppm", args ++ [path, base]),
           {:ok, text} <- tesseract(base <> ".png") do
        {:ok, clean(text)}
      else
        _ -> :error
      end
    after
      File.rm_rf(dir)
    end
  end

  defp tesseract(path) do
    langs = config()[:langs] || "eng"

    case run("tesseract", [path, "stdout", "-l", langs, "quiet"]) do
      {output, 0} -> {:ok, output}
      {_, status} -> {:error, failed("tesseract", status, "the image can't be read")}
    end
  end

  defp failed(program, status, reason) do
    if status == 124, do: "#{program} ran out of time", else: reason
  end

  # What came back goes in a text column: Postgres takes neither a NUL nor
  # invalid UTF-8, and a scanner produces both.
  defp clean(text),
    do: text |> clean_keeping_pages() |> String.replace("\f", "\n") |> String.trim()

  defp clean_keeping_pages(text) do
    text |> String.replace_invalid("") |> String.replace(<<0>>, "")
  end

  defp cap(text) do
    max = limit(:max_chars, @max_chars)

    if String.length(text) > max,
      do: {String.slice(text, 0, max), true},
      else: {text, false}
  end

  defp run(program, args) do
    case config()[:run] do
      run when is_function(run, 2) -> run.(program, args)
      _ -> command(program, args)
    end
  end

  # `timeout` answers 124 when it had to stop it. One thread: a server has
  # other work on, and a document is read a page at a time anyway.
  defp command(program, args) do
    seconds = limit(:timeout_seconds, @timeout_seconds)
    wrapped = ["-k", "5", "#{seconds}", "nice", "-n", "10", program | args]

    System.cmd("timeout", wrapped, env: [{"OMP_THREAD_LIMIT", "1"}])
  rescue
    error in ErlangError -> {Exception.message(error), 127}
  end

  defp limit(key, default), do: config()[key] || default

  defp config, do: Slipdock.Config.get(:ocr, [])
end
