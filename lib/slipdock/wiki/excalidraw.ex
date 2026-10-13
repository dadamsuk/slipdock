defmodule Slipdock.Wiki.Excalidraw do
  @moduledoc """
  Excalidraw drawings, in the two shapes a vault holds them (W-103 R5):

    * a `.excalidraw` file: the scene as JSON, kept as a wiki file;
    * a `.excalidraw.md` note, as Obsidian's Excalidraw plugin writes it: a
      page whose front matter says `excalidraw-plugin: parsed`, with the
      drawing's text under `## Text Elements` (so Obsidian can search and
      link it) and the scene in a fenced block under `## Drawing` — either
      ```json, or ```compressed-json, which is `LZString.compressToBase64`
      cut into lines of 256 (see `Slipdock.Wiki.Excalidraw.LZString`).

  A drawing is saved back in the shape it was read in, so the plugin can go
  on editing it: the scene block is replaced in the same encoding and the
  text section rewritten from the scene, and everything else in the note —
  front matter, prose before the data, embedded files, element links — is
  left exactly as it was.
  """

  alias Slipdock.Wiki.Excalidraw.LZString
  alias Slipdock.Wiki.Page

  @drawing ~r/^(#+ Drawing\n```)(compressed-json|json)\n(.*?)\n```/ms
  @text_elements ~r/^(#+ Text Elements\n)(.*?)(?=^%%$|^#+ |\z)/ms
  @embedded_files ~r/^#+ Embedded Files\n(.*?)(?=^%%$|^#+ |\z)/ms

  @doc "True for a name that is a drawing: `x.excalidraw` or `x.excalidraw.md`."
  def name?(name) when is_binary(name),
    do: String.match?(String.downcase(name), ~r/\.excalidraw(\.md)?\z/)

  def name?(_), do: false

  @doc """
  True for a page that is the plugin's drawing: its file is `x.excalidraw.md`
  or its front matter has the plugin's key.
  """
  def page?(%Page{file_name: file_name, front_matter: front_matter}) do
    name?(file_name) or
      (is_binary(front_matter) and Regex.match?(~r/^excalidraw-plugin:/m, front_matter))
  end

  def page?(_), do: false

  @doc """
  The scene in a `.excalidraw.md` body, with how it was encoded and the
  files the note embeds by link (`id => "[[image.png]]"`'s target).
  """
  @spec parse_markdown(String.t() | nil) ::
          {:ok, %{scene: map, format: :compressed | :json, links: %{String.t() => String.t()}}}
          | :error
  def parse_markdown(body) when is_binary(body) do
    with [_, _, kind, data] <- Regex.run(@drawing, body),
         {:ok, json} <- decode_block(kind, data),
         {:ok, scene} <- scene(json) do
      {:ok, %{scene: scene, format: format(kind), links: embedded_links(body)}}
    else
      _ -> :error
    end
  end

  def parse_markdown(_), do: :error

  @doc "The scene in a `.excalidraw` file's JSON."
  @spec parse_json(binary) :: {:ok, map} | :error
  def parse_json(json) when is_binary(json), do: scene(json)

  defp decode_block("json", data), do: {:ok, data}
  defp decode_block("compressed-json", data), do: LZString.decompress_from_base64(data)

  defp format("json"), do: :json
  defp format("compressed-json"), do: :compressed

  defp scene(json) do
    case Jason.decode(json) do
      {:ok, %{"elements" => elements} = scene} when is_list(elements) -> {:ok, scene}
      _ -> :error
    end
  end

  defp embedded_links(body) do
    case Regex.run(@embedded_files, body) do
      [_, section] ->
        for [_, id, target] <- Regex.scan(~r/^([\w-]+):\s*!?\[\[([^\]|#]+)/m, section),
            into: %{},
            do: {id, String.trim(target)}

      _ ->
        %{}
    end
  end

  @doc """
  The text a scene shows, one string per text element still in it, in the
  order they were drawn — what search indexes and what `## Text Elements`
  lists.
  """
  @spec texts(map) :: [{String.t(), String.t()}]
  def texts(%{"elements" => elements}) when is_list(elements) do
    for %{"type" => "text", "id" => id} = element <- elements,
        element["isDeleted"] != true,
        text = element["originalText"] || element["text"],
        is_binary(text) and String.trim(text) != "",
        do: {id, text}
  end

  def texts(_), do: []

  @doc "The text of a drawing as prose: each text element on its own line."
  def plain_text(scene), do: scene |> texts() |> Enum.map_join("\n", &elem(&1, 1))

  @doc """
  The body of a `.excalidraw.md` note with `json` (the scene, as the editor
  serialised it) in place of the drawing it held, in the encoding it had,
  and `## Text Elements` rewritten to match. Everything else is kept.
  """
  @spec write_markdown(String.t(), String.t()) :: {:ok, String.t()} | :error
  def write_markdown(body, json) when is_binary(body) and is_binary(json) do
    with {:ok, scene} <- scene(json),
         [_, _, kind, _] <- Regex.run(@drawing, body) do
      data =
        case kind do
          "json" -> json
          "compressed-json" -> chunk(LZString.compress_to_base64(json))
        end

      body =
        body
        |> replace_once(@drawing, fn _, head, kind, _ ->
          head <> kind <> "\n" <> data <> "\n```"
        end)
        |> replace_once(@text_elements, fn _, head, _ -> head <> text_section(scene) end)

      {:ok, body}
    else
      _ -> :error
    end
  end

  def write_markdown(_, _), do: :error

  @doc "A `.excalidraw` file's JSON, checked to be a scene."
  @spec write_json(String.t()) :: {:ok, String.t()} | :error
  def write_json(json) when is_binary(json) do
    case scene(json) do
      {:ok, _} -> {:ok, json}
      :error -> :error
    end
  end

  def write_json(_), do: :error

  # The plugin's lines: 256 characters, a blank line between.
  defp chunk(base64) do
    base64
    |> String.graphemes()
    |> Enum.chunk_every(256)
    |> Enum.map_join("\n\n", &Enum.join/1)
  end

  defp text_section(scene),
    do: Enum.map_join(texts(scene), fn {id, text} -> text <> " ^" <> id <> "\n\n" end)

  # Regex.replace with a function, but only the first match, and without
  # reading `\\1` in the replacement as a backreference.
  defp replace_once(text, regex, fun) do
    case Regex.run(regex, text, return: :index) do
      [{start, length} | groups] ->
        parts = Enum.map(groups, fn {s, l} -> binary_part(text, s, l) end)
        whole = binary_part(text, start, length)

        binary_part(text, 0, start) <>
          apply(fun, [whole | parts]) <>
          binary_part(text, start + length, byte_size(text) - start - length)

      nil ->
        text
    end
  end
end
