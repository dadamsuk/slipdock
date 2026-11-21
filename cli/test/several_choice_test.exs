defmodule SlipdockCLI.SeveralChoiceTest do
  @moduledoc """
  A choice field that allows several (#3611) from the command line:
  `new-field --several` asks for it, `fields` says so, and a card shows the
  options it holds as their keys, comma-separated, as `set` takes them.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-several-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  @field ~s({"field":{"id":4,"name":"Area","key":"area","kind":"select","options":[{"label":"Web"}],"config":{"several":true}}})

  test "new-field --several asks for a choice each card can hold several of" do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @field}]))

    capture_io(fn ->
      Boards.run("new-field", ["b", "Area"], kind: "select", options: "Web, API", several: true)
    end)

    assert_received {:request, "POST", "/api/boards/b/fields", body}
    assert %{"kind" => "select", "config" => %{"several" => true}} = JSON.decode!(body)
  end

  test "fields says a choice allows several, and a single one doesn't" do
    field = %{"id" => 1, "name" => "Area", "key" => "area", "kind" => "select"}
    options = [%{"label" => "Web"}, %{"label" => "API"}]

    several =
      capture_io(fn ->
        Render.fields([
          Map.merge(field, %{"options" => options, "config" => %{"several" => true}})
        ])
      end)

    assert plain(several) =~ "Web, API (several)"

    one =
      capture_io(fn ->
        Render.fields([Map.merge(field, %{"options" => options, "config" => %{}})])
      end)

    refute one =~ "(several)"
  end

  test "a card shows the options it holds as keys, comma-separated" do
    card = %{
      "id" => 9,
      "title" => "Release",
      "column" => "To Do",
      "board_id" => 3,
      "priority" => "none",
      "blocked_by" => [],
      "blocks" => [],
      "flags" => [],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => [],
      "fields" => %{"area" => ["web", "api"], "size" => "large"}
    }

    out = card |> then(&capture_io(fn -> Render.card(&1) end)) |> plain()
    assert out =~ "area=web,api"
    assert out =~ "size=large"
  end
end
