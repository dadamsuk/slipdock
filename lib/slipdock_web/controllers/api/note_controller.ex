defmodule SlipdockWeb.API.NoteController do
  @moduledoc "Quick notes (#1538): made from `SlipdockWeb.Ops.QuickNote` (#3188)."
  use SlipdockWeb, :controller

  action_fallback SlipdockWeb.API.FallbackController

  def create(conn, params), do: SlipdockWeb.Ops.REST.run(conn, SlipdockWeb.Ops.QuickNote, params)
end
