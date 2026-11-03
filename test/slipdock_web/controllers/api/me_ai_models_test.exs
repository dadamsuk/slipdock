defmodule SlipdockWeb.API.MeAIModelsTest do
  @moduledoc "`/api/me`'s `ai` block says which fallbacks a person's calls go out with (#1670)."
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Settings, TestConfig}
  alias Slipdock.AI.Keys

  setup do
    file = Path.join(System.tmp_dir!(), "me_models_#{System.unique_integer([:positive])}.json")
    TestConfig.merge(:ai, key_file: file)
    on_exit(fn -> File.rm(file) end)
    user = user_fixture("me-models-#{System.unique_integer([:positive])}@example.com")
    %{conn: conn_as(user), user: user}
  end

  test "the server's fallbacks, and the admin's model as the one in force", %{conn: conn} do
    {:ok, _} = Settings.update(%{"ai_model" => "admin/model", "ai_fallback_models" => "test/a"})

    ai = conn |> get("/api/me") |> json_response(200) |> Map.fetch!("ai")
    assert ai["model"] == "admin/model"
    assert ai["fallback_models"] == ["test/a"]
  end

  test "none for somebody who picked their own model", %{conn: conn, user: user} do
    {:ok, _} = Settings.update(%{"ai_fallback_models" => "test/a"})
    :ok = Keys.put_settings(user, %{model: "mine/model"})

    ai = conn |> get("/api/me") |> json_response(200) |> Map.fetch!("ai")
    assert ai["model"] == "mine/model"
    assert ai["fallback_models"] == []
  end
end
