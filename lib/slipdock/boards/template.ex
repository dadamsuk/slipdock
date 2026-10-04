defmodule Slipdock.Boards.Template do
  @moduledoc """
  A board template: a named list of columns used to set up new boards and
  the sub-boards inside cards. `columns` is a list of string-keyed maps with
  `"name"`, optional `"wip_limit"`, optional `"color"` and optional
  `"category"` (todo / doing / done / dropped).

  `pages` is the wiki a board made from this template starts with: a list of
  `%{"title" =>, "body" =>, "summary" =>, "template" =>}` maps, so a new
  board arrives with somewhere to write rather than an empty wiki. Bodies may
  use the `{{board.name}}` and `{{today}}` placeholders.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "board_templates" do
    field :name, :string
    field :description, :string
    field :columns, {:array, :map}, default: []
    field :pages, {:array, :map}, default: []
    # The kind of board this template makes (see `Slipdock.Boards.Board`'s
    # `kind`): "Sprint planning" makes sprint boards. nil for most.
    field :kind, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(template, attrs) do
    # Normalise first: `cast` would reject bare strings in an array of maps.
    attrs =
      case attrs do
        %{"columns" => cols} -> Map.put(attrs, "columns", normalize_columns(cols))
        %{columns: cols} -> Map.put(attrs, :columns, normalize_columns(cols))
        _ -> attrs
      end

    attrs =
      case attrs do
        %{"pages" => pages} -> Map.put(attrs, "pages", normalize_pages(pages))
        %{pages: pages} -> Map.put(attrs, :pages, normalize_pages(pages))
        _ -> attrs
      end

    template
    |> cast(attrs, [:name, :description, :columns, :pages, :kind])
    |> update_change(:kind, &if(&1 == "", do: nil, else: &1))
    |> validate_inclusion(:kind, Slipdock.Boards.Board.kinds())
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :columns])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_columns()
    |> unique_constraint(:name, message: "already exists")
  end

  @doc "The pages a board made from this template starts with, cleaned up."
  def normalize_pages(pages) when is_list(pages) do
    pages
    |> Enum.map(fn page ->
      page = Map.new(page, fn {k, v} -> {to_string(k), v} end)

      %{
        "title" => page["title"] |> to_string() |> String.trim(),
        "body" => to_string(page["body"] || ""),
        "summary" => nonblank(page["summary"]),
        "template" => page["template"] == true
      }
    end)
    |> Enum.reject(&(&1["title"] == ""))
  end

  def normalize_pages(_), do: []

  defp nonblank(nil), do: nil
  defp nonblank(""), do: nil
  defp nonblank(text), do: to_string(text)

  # Accepts a list of maps (atom or string keys) or a params map keyed by
  # index (as submitted by a form) and returns clean string-keyed maps.
  def normalize_columns(columns) when is_map(columns) do
    columns
    |> Enum.sort_by(fn {k, _} -> String.to_integer(to_string(k)) end)
    |> Enum.map(fn {_, v} -> v end)
    |> normalize_columns()
  end

  def normalize_columns(columns) when is_list(columns) do
    columns
    |> Enum.map(fn
      col when is_map(col) ->
        col = Map.new(col, fn {k, v} -> {to_string(k), v} end)

        %{
          "name" => col["name"] |> to_string() |> String.trim(),
          "wip_limit" => wip(col["wip_limit"]),
          "color" => color(col["color"]),
          "category" => category(col["category"])
        }

      name when is_binary(name) ->
        %{"name" => String.trim(name), "wip_limit" => nil, "color" => nil, "category" => nil}
    end)
    |> Enum.reject(&(&1["name"] == ""))
  end

  def normalize_columns(_), do: []

  defp wip(nil), do: nil
  defp wip(""), do: nil
  defp wip(n) when is_integer(n) and n > 0, do: n
  defp wip(n) when is_integer(n), do: nil

  defp wip(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp wip(_), do: nil

  defp color(c) when is_binary(c) and c != "",
    do: if(c in Slipdock.Palette.names(), do: c, else: nil)

  defp color(_), do: nil

  defp category(c) when is_binary(c) and c != "",
    do: if(c in Slipdock.Boards.Column.category_keys(), do: c, else: nil)

  defp category(_), do: nil

  defp validate_columns(changeset) do
    case get_field(changeset, :columns) do
      [] -> add_error(changeset, :columns, "must have at least one list")
      cols when length(cols) > 20 -> add_error(changeset, :columns, "can have at most 20 lists")
      _ -> changeset
    end
  end
end
