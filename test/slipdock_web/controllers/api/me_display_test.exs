defmodule SlipdockWeb.API.MeDisplayTest do
  @moduledoc "\"Names in trees and lists\" over the API (#1594)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts

  setup do
    user = user_fixture("display-#{System.unique_integer([:positive])}@example.com")
    %{conn: conn_as(user), user: user}
  end

  test "GET /api/me says the choice, full by default", %{conn: conn} do
    assert %{"user" => %{"tree_names" => "full"}} = conn |> get("/api/me") |> json_response(200)
  end

  test "PUT sets it", %{conn: conn, user: user} do
    assert %{"tree_names" => "short"} =
             conn |> put("/api/me/display", %{tree_names: "short"}) |> json_response(200)

    assert Accounts.get_user!(user.id).tree_names == "short"
  end

  test "a choice that isn't one is refused", %{conn: conn, user: user} do
    assert %{"error" => error} =
             conn |> put("/api/me/display", %{tree_names: "tiny"}) |> json_response(422)

    assert error =~ "full, short"
    assert Accounts.get_user!(user.id).tree_names == "full"
  end

  test "sending nothing is refused", %{conn: conn} do
    assert %{"error" => _} = conn |> put("/api/me/display", %{}) |> json_response(422)
  end
end
