defmodule SlipdockWeb.API.NoteController do
  @moduledoc "Quick notes (#1538): `Slipdock.Wiki.QuickNote`, for the CLI and agents."
  use SlipdockWeb, :controller

  alias Slipdock.Wiki.QuickNote
  alias SlipdockWeb.API.Authorize

  action_fallback SlipdockWeb.API.FallbackController

  def create(conn, params) do
    allow = &(Authorize.board(conn, &1, :write) == :ok)

    with {:ok, note} <-
           QuickNote.save(conn.assigns.current_user, params["text"], via: "api", allow: allow) do
      conn |> put_status(:created) |> json(%{note: json(note)})
    end
  end

  @doc "A saved note as the API and the MCP tool give it."
  def json(%{page: page, vault: vault, location: location, placed_by: placed_by}) do
    %{
      code: page.code,
      title: page.title,
      vault: vault.name,
      location: "/" <> location,
      placed_by: placed_by
    }
  end
end
