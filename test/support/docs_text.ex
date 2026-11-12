defmodule Slipdock.DocsText do
  @moduledoc """
  The repository's docs as the tests that hold them to a rule read them.

  The manual is an index, `docs/manual.md`, and a page for each of its
  sections under `docs/manual/` (#2232): one file was over the 512 KB GitHub
  will render. `read!/1` reads the manual as one text, the index and then
  every part in the index's order, so a test can hold the manual to a
  sentence whichever part it is in.

  The API guide is the same: `lib/slipdock_web/api_guide.ex` is the code,
  and its prose is a Markdown file per section under
  `lib/slipdock_web/api_guide/` (#2800). `read!/1` reads the module as the
  module and then every section, so a test holding "the API guide" to a
  sentence finds it in whichever file it is.

  Any other path reads as `File.read!/1` does.
  """

  @root Path.expand("../..", __DIR__)
  @index "docs/manual.md"
  @api_guide "lib/slipdock_web/api_guide.ex"

  @doc """
  `File.read!/1`, except that the manual's index reads as the whole manual,
  and the API guide's module as the module and its sections.
  """
  def read!(path) do
    cond do
      Path.expand(path) == Path.join(@root, @index) -> manual()
      Path.expand(path) == Path.join(@root, @api_guide) -> api_guide()
      true -> File.read!(path)
    end
  end

  @doc "The API guide: its module, then each section's Markdown, by name."
  def api_guide do
    Enum.map_join([Path.join(@root, @api_guide) | api_guide_parts()], "\n", &File.read!/1)
  end

  @doc "The API guide's section files: absolute paths, sorted."
  def api_guide_parts do
    @root |> Path.join("lib/slipdock_web/api_guide/*.md") |> Path.wildcard() |> Enum.sort()
  end

  @doc "The whole manual: the index, then each part it lists, in its order."
  def manual do
    Enum.map_join([Path.join(@root, @index) | manual_parts()], "\n", &File.read!/1)
  end

  @doc "The manual's parts, as the index lists them: absolute paths, in order."
  def manual_parts do
    index = File.read!(Path.join(@root, @index))

    for [_, part] <- Regex.scan(~r{^- \[[^\]]+\]\(manual/([\w-]+\.md)\)$}m, index),
        do: Path.join([@root, "docs/manual", part])
  end
end
