defmodule SlipdockCLI.CardBordersTest do
  @moduledoc "`--border` and `--border-top` and the rest on cards, and how a card shows them (#1209)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-borders-#{System.unique_integer([:positive])}")
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

  @card ~s({"card":{"id":9,"title":"Edges","column":"To Do","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  defp run(command, args, opts) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, @card}]))
    capture_io(fn -> Boards.run(command, args, opts) end)
    assert_received {:request, method, path, body}
    {method, path, JSON.decode!(body)}
  end

  describe "borders/1" do
    test "nothing asked sends nothing" do
      assert Boards.borders([]) == %{
               "border_top" => nil,
               "border_right" => nil,
               "border_bottom" => nil,
               "border_left" => nil
             }
    end

    test "--border sets all four, and an edge of its own wins" do
      assert Boards.borders(border: "red", border_left: "sky") == %{
               "border_top" => "red",
               "border_right" => "red",
               "border_bottom" => "red",
               "border_left" => "sky"
             }
    end

    test "--no-border clears all four, and none clears one" do
      assert Boards.borders(no_border: true) |> Map.values() |> Enum.uniq() == [""]
      assert Boards.borders(border_top: "none")["border_top"] == ""
    end
  end

  test "edit sends only the edges asked for" do
    {method, path, body} = run("edit", ["9"], border_top: "red", border_bottom: "none")
    assert {method, path} == {"PATCH", "/api/cards/9"}
    assert body == %{"border_top" => "red", "border_bottom" => ""}
  end

  test "edit --no-border takes every edge's colour off" do
    {_method, _path, body} = run("edit", ["9"], no_border: true)

    assert body == %{
             "border_top" => "",
             "border_right" => "",
             "border_bottom" => "",
             "border_left" => ""
           }
  end

  test "add sends the edges with the card" do
    {method, path, body} = run("add", ["slipdock", "Edges"], border: "amber")
    assert {method, path} == {"POST", "/api/boards/slipdock/cards"}
    assert body["border_top"] == "amber" and body["border_left"] == "amber"
  end

  describe "borders_line/1" do
    test "nil with no edge coloured" do
      assert Render.borders_line(%{"border_top" => nil}) == nil
    end

    test "one colour when the four agree" do
      card = Map.new(~w(top right bottom left), &{"border_" <> &1, "rose"})
      assert Render.borders_line(card) == "rose (all edges)"
    end

    test "each coloured edge, clockwise from the top" do
      card = %{"border_left" => "sky", "border_top" => "red"}
      assert Render.borders_line(card) == "top red · left sky"
    end
  end
end
