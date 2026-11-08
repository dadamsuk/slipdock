defmodule Slipdock.SkillRegistry.Parse do
  @moduledoc """
  Reads a fetched SKILL.md (or README) into an entry's name and description
  (#2060). The front matter is read with `Slipdock.Wiki.FrontMatter`, plus the
  `>` and `|` block scalars a long `description:` is often written as.

  A SKILL.md needs a `name`; one without, or whose front matter can't be
  read, is skipped with the reason. A README with no front matter is named
  for its repository and described by its first paragraph.
  """

  alias Slipdock.Wiki.FrontMatter

  @max_name 100
  @max_description 2000

  @type parsed :: %{name: String.t(), description: String.t() | nil}

  @doc """
  `{:ok, %{name, description}}` or `{:skip, reason}`. `fallback` is the name to
  use when there is none (a README), or nil when a name is required.
  """
  @spec entry(binary(), String.t() | nil) :: {:ok, parsed} | {:skip, String.t()}
  def entry(text, fallback \\ nil) do
    with :ok <- utf8(text),
         {:ok, yaml, rest} <- front_matter(text) do
      name = scalar(yaml, "name")
      description = scalar(yaml, "description")

      cond do
        is_binary(name) and name != "" ->
          named(name, description || first_paragraph(rest))

        is_list(name) ->
          {:skip, "its name is a list, not a single line"}

        is_binary(fallback) ->
          named(fallback, description || first_paragraph(rest))

        true ->
          {:skip, "has no name in its front matter"}
      end
    end
  end

  defp named(name, description) do
    cond do
      String.length(name) > @max_name ->
        {:skip, "its name is longer than #{@max_name} characters"}

      String.contains?(name, "\n") ->
        {:skip, "its name is not a single line"}

      true ->
        {:ok, %{name: name, description: trim(description)}}
    end
  end

  defp utf8(text), do: if(String.valid?(text), do: :ok, else: {:skip, "is not UTF-8 text"})

  defp front_matter(text) do
    case FrontMatter.split(text) do
      {nil, body} ->
        if String.starts_with?(text, "---"),
          do: {:skip, "its front matter is not closed with a `---` line"},
          else: {:ok, nil, body}

      {header, body} ->
        {:ok, FrontMatter.yaml(header), body}
    end
  end

  defp scalar(nil, _key), do: nil

  defp scalar(yaml, key) do
    case FrontMatter.get(yaml, key) do
      nil -> block_scalar(yaml, key)
      value when is_binary(value) -> String.trim(value)
      list -> list
    end
  end

  # `key: >` or `key: |`, then indented lines: folded with spaces, or kept.
  defp block_scalar(yaml, key) do
    with %{text: text} <- Enum.find(FrontMatter.blocks(yaml), &(&1.key == key)),
         [first | rest] <- String.split(text, ~r/\r?\n/),
         [_, style] <- Regex.run(~r/:\s*([>|])[+-]?\s*$/, first) do
      lines = rest |> Enum.map(&String.trim/1) |> Enum.drop_while(&(&1 == ""))
      joiner = if style == ">", do: " ", else: "\n"
      lines |> Enum.join(joiner) |> String.trim() |> blank_nil()
    else
      _ -> nil
    end
  end

  defp first_paragraph(body) do
    body
    |> String.split(~r/\r?\n\s*\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, ["#", "<", "!", "[!"])))
    |> case do
      nil -> nil
      text -> text |> String.replace(~r/\s+/, " ")
    end
  end

  defp trim(nil), do: nil
  defp trim(text), do: text |> String.trim() |> String.slice(0, @max_description) |> blank_nil()

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text
end
