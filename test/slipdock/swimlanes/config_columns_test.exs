defmodule Slipdock.Swimlanes.ConfigColumnsTest do
  @moduledoc """
  The columns of the table, the outline and Prioritise in a view's config
  (#3665): their order, which are hidden, and their dragged widths.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Swimlanes.Config

  @outline Config.outline_col_keys()

  describe "the table's fields" do
    test "keep the reader's order and drop unknown keys" do
      assert Config.from_query(%{"fields" => "due_date,bogus,priority,f:7,title"}).fields ==
               ["due_date", "priority", "f:7", "title"]
    end

    test "a table's columns are its shown ones in order, then the hidden ones in their own" do
      config = %Config{fields: ["tags", "priority"]}

      assert Config.col_order(config, "table", ~w(column priority tags due_date)) ==
               [{"tags", true}, {"priority", true}, {"column", false}, {"due_date", false}]
    end

    test "comfortable and compact keep their own order" do
      config = %Config{
        fields: ["priority", "tags"],
        fields_compact: ["priority", "tags"],
        density: "compact"
      }

      moved = Config.move_col(config, "table", ~w(priority tags), "tags", "priority")

      assert moved.fields_compact == ["tags", "priority"]
      assert moved.fields == ["priority", "tags"]
    end

    test "moving a hidden column leaves the shown ones as they were" do
      config = %Config{fields: ["tags"]}

      assert Config.move_col(config, "table", ~w(priority tags), "priority", "tags").fields == [
               "tags"
             ]
    end

    test "moving a column puts it before another, or last" do
      config = %Config{fields: ~w(column priority tags)}
      all = ~w(column priority tags due_date)

      assert Config.move_col(config, "table", all, "tags", "column").fields ==
               ~w(tags column priority)

      assert Config.move_col(config, "table", all, "column", nil).fields ==
               ~w(priority tags column)

      # A key the view doesn't have changes nothing.
      assert Config.move_col(config, "table", all, "bogus", "column") == config
    end
  end

  describe "the table's title (#3748)" do
    @table ~w(title column priority tags)

    test "moves like any other column, and isn't put back first" do
      config = %Config{fields: ~w(title column priority)}

      moved = Config.move_col(config, "table", @table, "title", nil)
      assert moved.fields == ~w(column priority title)

      assert Config.move_col(moved, "table", @table, "title", "priority").fields ==
               ~w(column title priority)
    end

    test "hidden, it is listed after the shown columns, unticked" do
      config = Config.from_query(%{"fields" => "priority,column"})

      assert config.fields == ~w(priority column)

      assert Config.col_order(config, "table", @table) ==
               [{"priority", true}, {"column", true}, {"title", false}, {"tags", false}]
    end

    test "a table with no columns lists its title as shown, and draws it" do
      config = Config.from_form(%{"fields" => [""]}, %Config{mode: "table"})

      assert config.fields == []
      assert {"title", true} in Config.col_order(config, "table", @table)
      assert [{"title", "Title", "title"}] = Slipdock.Table.visible_fields(config)
    end

    test "a view that names its title first, as every one did, draws it first" do
      fields = Slipdock.Table.visible_fields(%Config{fields: ~w(title priority)})
      assert Enum.map(fields, &elem(&1, 0)) == ~w(title priority)
    end
  end

  describe "the outline's and Prioritise's columns" do
    test "show every column in the view's order until a reader says otherwise" do
      assert Config.col_order(%Config{}, "outline", @outline) == Enum.map(@outline, &{&1, true})
    end

    test "a -key hides a column in its place; one not named is shown after the named" do
      config = Config.from_query(%{"outline_cols" => "health,-list"})

      assert config.outline_cols == ["health", "-list"]

      assert Config.col_order(config, "outline", @outline) ==
               [{"health", true}, {"list", false}, {"progress", true}, {"schedule", true}]

      assert Config.shown_cols(config, "outline", @outline) == ~w(health progress schedule)
    end

    test "a form's hidden -key before a ticked box's key shows it, in the first place named" do
      sent = ["-schedule", "schedule", "-list", "-progress", "progress", "bogus", "-f:3"]

      assert Config.from_query(%{"outline_cols" => sent}).outline_cols ==
               ["schedule", "-list", "progress"]

      # Prioritise takes its scoring fields' f:<id> keys too.
      assert Config.from_query(%{"prio_cols" => ["-votes", "f:3", "-priority", "priority"]}).prio_cols ==
               ["-votes", "f:3", "priority"]
    end

    test "a scoring field added later is shown, after the ones the reader placed" do
      config = %Config{prio_cols: ["f:2", "-votes", "priority"]}

      assert Config.shown_cols(config, "prioritise", ~w(priority votes f:2 f:9)) ==
               ~w(f:2 priority f:9)
    end

    test "moving keeps what is hidden, and back to the view's own order is no list at all" do
      config = %Config{outline_cols: ["list", "-progress"]}
      moved = Config.move_col(config, "outline", @outline, "health", "list")

      assert moved.outline_cols == ["health", "list", "-progress", "schedule"]

      shown = %Config{outline_cols: ["schedule"]}
      assert Config.move_col(shown, "outline", @outline, "schedule", "health").outline_cols == []
    end

    test "tidy_cols empties a list that says what the view does anyway" do
      all = ~w(priority votes f:1)

      assert Config.tidy_cols(%Config{prio_cols: ~w(priority votes f:1)}, "prioritise", all).prio_cols ==
               []

      assert Config.tidy_cols(%Config{prio_cols: ~w(votes)}, "prioritise", all).prio_cols ==
               ~w(votes priority f:1)

      assert Config.tidy_cols(%Config{prio_cols: ~w(-f:1)}, "prioritise", all).prio_cols ==
               ~w(-f:1 priority votes)

      # The table's fields are always a list of their own.
      assert Config.tidy_cols(%Config{fields: ~w(title)}, "table", []).fields == ~w(title)
    end
  end

  describe "widths" do
    test "are key:px, held between the limits, the last one for a key winning" do
      {min, max} = Config.width_range()

      config =
        Config.from_query(%{
          "widths" =>
            "title:300,priority:2,due_date:99999,title:320,f:12:150,bad,x y:40,tags:wide,:40"
        })

      assert config.widths == ["priority:#{min}", "due_date:#{max}", "title:320", "f:12:150"]

      assert Config.col_widths(config, "table") ==
               %{"priority" => min, "due_date" => max, "title" => 320, "f:12" => 150}
    end

    test "are kept per view, and the table's per card size" do
      config = %Config{
        widths: ["title:300"],
        widths_compact: ["title:200"],
        outline_widths: ["list:90"]
      }

      assert Config.col_widths(config, "table") == %{"title" => 300}
      assert Config.col_widths(%{config | density: "compact"}, "table") == %{"title" => 200}
      assert Config.col_widths(config, "outline") == %{"list" => 90}
      assert Config.col_widths(config, "prioritise") == %{}
    end

    test "put_col_width sets, replaces and forgets one column's width" do
      config =
        %Config{}
        |> Config.put_col_width("prioritise", "votes", 120)
        |> Config.put_col_width("prioritise", "f:4", 200)
        |> Config.put_col_width("prioritise", "votes", 5000)

      assert config.prio_widths == ["f:4:200", "votes:960"]
      assert Config.put_col_width(config, "prioritise", "f:4", nil).prio_widths == ["votes:960"]
    end

    test "round-trip through a URL and a saved view" do
      config = %{
        Config.defaults("outline")
        | outline_cols: ["health", "-list"],
          outline_widths: ["card:400", "health:80"]
      }

      query =
        Config.to_query(config, Config.defaults("outline"))
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      assert Config.from_query(query, Config.defaults("outline")) == config
      assert Config.from_map(Config.to_map(config)).outline_widths == config.outline_widths
    end

    test "sanitize forgets the widths and places of custom fields the board no longer has" do
      board = %{tags: [], columns: [], fields: [%{id: 1}]}

      config = %Config{
        widths: ["f:1:100", "f:2:100", "title:300"],
        prio_widths: ["f:2:90"],
        prio_cols: ["f:2", "-f:1", "votes"]
      }

      clean = Config.sanitize(config, board)
      assert clean.widths == ["f:1:100", "title:300"]
      assert clean.prio_widths == []
      assert clean.prio_cols == ["-f:1", "votes"]
    end
  end
end
