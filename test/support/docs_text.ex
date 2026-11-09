defmodule Slipdock.DocsText do
  @moduledoc """
  The repository's docs as the tests that hold them to a rule read them.

  The manual is an index, `docs/manual.md`, and a page for each of its
  sections under `docs/manual/` (#2232): one file was over the 512 KB GitHub
  will render. `read!/1` reads the manual as one text, the index and then
  every part in the index's order, so a test can hold the manual to a
  sentence whichever part it is in. Any other path reads as `File.read!/1`
  does.
  """

  @root Path.expand("../..", __DIR__)
  @index "docs/manual.md"

  @doc "`File.read!/1`, except that the manual's index reads as the whole manual."
  def read!(path) do
    if Path.expand(path) == Path.join(@root, @index), do: manual(), else: File.read!(path)
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
