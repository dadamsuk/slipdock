defmodule SlipdockWeb.API.TemplateController do
  use SlipdockWeb, :controller

  alias Slipdock.Boards
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  @fields ~w(name description columns kind)

  def index(conn, _params) do
    json(conn, %{templates: Enum.map(Boards.list_templates(), &V.template/1)})
  end

  def show(conn, %{"id" => ref}) do
    with {:ok, template} <- fetch(ref), do: json(conn, %{template: V.template(template)})
  end

  def create(conn, params) do
    with {:ok, template} <- Boards.create_template(Map.take(params, @fields)) do
      conn |> put_status(:created) |> json(%{template: V.template(template)})
    end
  end

  def update(conn, %{"id" => ref} = params) do
    with {:ok, template} <- fetch(ref),
         {:ok, template} <- Boards.update_template(template, Map.take(params, @fields)) do
      json(conn, %{template: V.template(template)})
    end
  end

  def delete(conn, %{"id" => ref}) do
    with {:ok, template} <- fetch(ref),
         {:ok, _} <- Boards.delete_template(template) do
      json(conn, %{ok: true})
    end
  end

  defp fetch(ref) do
    case Boards.find_template(ref) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :not_found, "template"}
    end
  end
end
