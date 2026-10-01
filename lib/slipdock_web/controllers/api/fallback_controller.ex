defmodule SlipdockWeb.API.FallbackController do
  use SlipdockWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "validation failed", details: SlipdockWeb.API.JSON.errors(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "not found"})
  end

  def call(conn, {:error, :not_found, what}) do
    conn |> put_status(:not_found) |> json(%{error: "#{what} not found"})
  end

  def call(conn, {:error, :forbidden, message}) do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden: #{message}"})
  end

  def call(conn, {:error, :unprocessable_entity, message}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: message})
  end

  # A write made against a version that has since moved on. Both sides come
  # back so the caller can merge rather than guess: `content_hash` is what to
  # send next time, and `title`/`body` are the page as it now stands.
  def call(conn, {:error, :conflict, %{} = current}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "conflict: the page has changed since you read it",
      current: current
    })
  end

  def call(conn, {:error, :bad_request, message}) do
    conn |> put_status(:bad_request) |> json(%{error: message})
  end
end
