defmodule SlipdockWeb.EmptyTemplatesLiveTest do
  @moduledoc """
  The Templates page's empty state (#1715): shown with no templates at all,
  and gone once the user has one of their own. The rest of the empty states
  are in `SlipdockWeb.EmptyStatesLiveTest`.
  """
  # Sync: deletes the built-in templates, and an async test creating a board
  # from one holds a lock on it, so the two deadlocked in CI (#1837).
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Slipdock.{Boards, Repo}

  # The built-ins are seeded by a migration, so only a server without them
  # (and a user with none of their own) ever sees it.
  setup do
    Repo.delete_all(from(t in Boards.Template, where: t.system))
    :ok
  end

  test "none: the full empty state, with no action (the form is above it)", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/templates")
    assert has_element?(view, "#templates-empty[data-empty-state=full] h2", "No templates yet")
    refute has_element?(view, "#templates-empty [data-role=empty-state-action]")
  end

  test "a template of the user's own replaces it", %{conn: conn, user: user} do
    {:ok, _} = Boards.Templates.create_template(user, %{"name" => "Mine", "columns" => ["A"]})
    {:ok, view, _} = live(conn, ~p"/templates")
    refute has_element?(view, "#templates-empty")
    assert render(view) =~ "Mine"
  end
end
