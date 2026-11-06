defmodule Slipdock.Swimlanes.ConfigDisplayTest do
  @moduledoc "The Display menu's part of a config, which a browser remembers (#1879)."
  use ExUnit.Case, async: true

  alias Slipdock.Swimlanes.Config

  describe "display_query/2" do
    test "is empty when the display is the base's, whatever the filters" do
      base = Config.defaults("board")
      assert Config.display_query(base, base) == %{}
      assert Config.display_query(%{base | q: "x", tags: [1], done: "hide"}, base) == %{}
    end

    test "carries only the display keys that differ, encoded as query values" do
      base = Config.defaults("board")

      config = %{
        base
        | density: "compact",
          width: "wide",
          show_compact: ["tags", "id"],
          q: "not remembered"
      }

      assert Config.display_query(config, base) == %{
               "density" => "compact",
               "width" => "wide",
               "show_compact" => "tags,id"
             }
    end

    test "an emptied facet set is kept as an empty value, not dropped" do
      base = Config.defaults("board")
      assert Config.display_query(%{base | show: []}, base) == %{"show" => ""}
    end
  end

  describe "put_display/2" do
    test "puts the remembered display keys on the config and leaves the rest" do
      config = %{Config.defaults("board") | q: "kept"}

      put =
        Config.put_display(config, %{
          "density" => "compact",
          "show_compact" => "id,tags",
          "q" => "ignored",
          "rows" => "assignee"
        })

      assert put.density == "compact"
      assert put.show_compact == ["tags", "id"]
      assert put.q == "kept"
      assert put.rows == config.rows
    end

    test "drops non-string values and casts unknown ones back to what was there" do
      config = Config.defaults("board")
      put = Config.put_display(config, %{"density" => 3, "width" => "huge", "handoff" => "full"})
      assert put.density == config.density
      assert put.width == config.width
      assert put.handoff == "full"
    end

    test "round-trips display_query/2" do
      base = Config.defaults("table")
      config = %{base | fields: ["title", "priority"], color_by: "priority", density: "compact"}
      assert Config.put_display(base, Config.display_query(config, base)) == config
    end

    test "anything but a map changes nothing" do
      config = Config.defaults("board")
      assert Config.put_display(config, nil) == config
      assert Config.put_display(config, ["density", "compact"]) == config
    end

    test "display_keys/0 are the Display menu's" do
      assert Enum.sort(Config.display_keys()) ==
               ~w(color_by density fields fields_compact handoff place show show_compact tell width)
    end
  end
end
