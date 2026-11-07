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
          fields: [],
          q: "not remembered"
      }

      assert Config.display_query(config, base) == %{
               "density" => "compact",
               "width" => "wide",
               "fields" => ""
             }
    end

    test "never carries what a card's front shows: card views decide it (#2031)" do
      base = Config.defaults("board")
      config = Config.put_card_view(%{base | show: [], show_compact: ["id"]}, "Mine")
      assert Config.display_query(config, base) == %{}
    end
  end

  describe "put_display/2" do
    test "puts the remembered display keys on the config and leaves the rest" do
      config = %{Config.defaults("board") | q: "kept"}

      put =
        Config.put_display(config, %{
          "density" => "compact",
          "show_compact" => "id,tags",
          "fields" => "title,id",
          "q" => "ignored",
          "rows" => "assignee"
        })

      assert put.density == "compact"
      assert put.fields == ["title", "id"]
      # What a browser remembered of the card front before #2031 is dropped.
      assert put.show_compact == config.show_compact
      assert put.q == "kept"
      assert put.rows == config.rows
    end

    test "drops non-string values and casts unknown ones back to what was there" do
      config = Config.defaults("board")
      put = Config.put_display(config, %{"density" => 3, "width" => "huge", "place" => "start"})
      assert put.density == config.density
      assert put.width == config.width
      assert put.place == "start"
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
               ~w(color_by density fields fields_compact place tell width)
    end
  end
end
