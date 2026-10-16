defmodule SlipdockWeb.API.TemplateController do
  use SlipdockWeb, :controller

  alias Slipdock.Boards
  alias SlipdockWeb.API.JSON, as: V

  action_fallback SlipdockWeb.API.FallbackController

  @fields ~w(name description columns kind pages folders tags automations)

  # A person sees the built-in templates and their own, and changes only
  # their own: a built-in is read-only to everyone, admins included (403),
  # and anybody else's is a 404, like a board they can't see.

  def index(conn, _params) do
    templates = Boards.list_templates(conn.assigns.current_user)
    json(conn, %{templates: Enum.map(templates, &V.template/1)})
  end

  def show(conn, %{"id" => ref}) do
    with {:ok, template} <- fetch(conn, ref), do: json(conn, %{template: V.template(template)})
  end

  def create(conn, params) do
    with {:ok, template} <-
           Boards.create_template(conn.assigns.current_user, Map.take(params, @fields)) do
      conn |> put_status(:created) |> json(%{template: V.template(template)})
    end
  end

  def update(conn, %{"id" => ref} = params) do
    user = conn.assigns.current_user

    with {:ok, template} <- fetch(conn, ref),
         {:ok, template} <-
           refusal(Boards.update_template(user, template, Map.take(params, @fields))) do
      json(conn, %{template: V.template(template)})
    end
  end

  def delete(conn, %{"id" => ref}) do
    with {:ok, template} <- fetch(conn, ref),
         {:ok, _} <- refusal(Boards.delete_template(conn.assigns.current_user, template)) do
      json(conn, %{ok: true})
    end
  end

  defp fetch(conn, ref) do
    case Boards.find_template(conn.assigns.current_user, ref) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :not_found, "template"}
    end
  end

  defp refusal({:error, :forbidden}),
    do: {:error, :forbidden, "built-in templates can't be changed"}

  defp refusal({:error, :not_found}), do: {:error, :not_found, "template"}
  defp refusal(result), do: result
end
