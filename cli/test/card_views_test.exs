defmodule SlipdockCLI.CardViewsTest do
  @moduledoc """
  `slipdock card-views` and `slipdock card-view …` (#2031): what each sends
  and shows. A usage error and a server refusal end in `System.halt/1`, so
  the usage errors are checked on `plan/3`, which decides them, and the
  refusals on `send_request/1`, which hands back what `out/3` would print.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{CardViews, FakeServer}

  setup do
    saved = Map.new(~w(SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))
  defp run(cmd, args, o \\ []), do: capture_io(fn -> CardViews.run(cmd, args, o) end)

  @focus %{"id" => 3, "name" => "Focus", "elements" => %{"tags" => false, "due_date" => true}}
  @catalogue [
    %{"key" => "tags", "label" => "Tags", "group" => "front", "default" => true},
    %{"key" => "side.time", "label" => "Time", "group" => "side", "default" => true}
  ]
  @plan %{"id" => 7, "code" => "plan", "name" => "Plan"}

  describe "named card views" do
    test "card-views lists each with what it shows and hides" do
      serve([{200, JSON.encode!(%{card_views: [@focus], elements: @catalogue})}])
      out = run("card-views", [])

      assert_received {:request, "GET", "/api/card-views", _}
      assert out =~ ~r/3\s+Focus\s+due_date\s+tags/
      refute out =~ "side.time"
    end

    test "--elements prints the catalogue too" do
      serve([{200, JSON.encode!(%{card_views: [], elements: @catalogue})}])
      out = run("card-views", [], elements: true)

      assert out =~ "no card views yet"
      assert out =~ ~r/side\.time\s+side\s+on\s+Time/
    end

    test "--json passes the answer through" do
      serve([{200, JSON.encode!(%{card_views: [@focus], elements: @catalogue})}])
      json = run("card-views", [], json: true)
      assert %{"card_views" => [%{"name" => "Focus"}], "elements" => [_, _]} = JSON.decode!(json)
    end

    test "show reads one by name" do
      serve([{200, JSON.encode!(%{card_view: @focus})}])
      out = run("card-view", ["show", "Focus"])

      assert_received {:request, "GET", "/api/card-views/Focus", _}
      assert out =~ "Focus"
      assert out =~ ~r/shows:\s+due_date/
      assert out =~ ~r/hides:\s+tags/
    end

    test "new sends the name, words joined, and the elements as given" do
      serve([{201, JSON.encode!(%{card_view: %{@focus | "name" => "Deep focus"}})}])
      out = run("card-view", ["new", "Deep", "focus"], show: "due_date", hide: "tags")

      assert_received {:request, "POST", "/api/card-views", body}

      assert JSON.decode!(body) == %{
               "name" => "Deep focus",
               "show" => "due_date",
               "hide" => "tags"
             }

      assert out =~ "saved card view Deep focus (3)"
    end

    test "edit sends only what is changing" do
      serve([{200, JSON.encode!(%{card_view: @focus})}])
      run("card-view", ["edit", "3"], name: "Calm", inherit: "tags", reset: true)

      assert_received {:request, "PATCH", "/api/card-views/3", body}
      assert JSON.decode!(body) == %{"name" => "Calm", "inherit" => "tags", "reset" => true}
    end

    test "rm deletes it and says the levels keep their own" do
      serve([{200, JSON.encode!(%{deleted: @focus})}])
      out = run("card-view", ["rm", "Focus"])

      assert_received {:request, "DELETE", "/api/card-views/Focus", _}
      assert out =~ "deleted card view Focus"
    end

    test "a view that is not the caller's is the server's 404" do
      serve([{404, ~s({"error":"card view not found"})}])
      {:ok, {:view, request}} = CardViews.plan("card-view", ["show", "Theirs"], [])

      assert CardViews.send_request(request) ==
               {:error, 404, %{"error" => "card view not found"}}
    end

    test "an unknown element is the server's 422, which names it" do
      serve([{422, JSON.encode!(%{error: "not an element: colour (see the elements list)"})}])
      {:ok, {:created, request}} = CardViews.plan("card-view", ["new", "X"], hide: "colour")

      assert {:error, 422, %{"error" => "not an element: colour" <> _}} =
               CardViews.send_request(request)
    end

    test "missing a view, or nothing to change, is a usage error" do
      for sub <- ~w(show new edit rm) do
        assert {:error, "usage: slipdock card-view " <> _} =
                 CardViews.plan("card-view", [sub], [])
      end

      assert {:error, "say what to change" <> _} = CardViews.plan("card-view", ["edit", "3"], [])
      assert {:error, "usage: slipdock card-views" <> _} = CardViews.plan("card-views", ["x"], [])
      assert {:error, "usage: " <> _} = CardViews.plan("card-view", [], [])
      assert {:error, "usage: " <> _} = CardViews.plan("card-view", ["frobnicate"], [])
    end
  end

  describe "levels" do
    test "level with no board reads the global level" do
      serve([
        {200,
         JSON.encode!(%{
           level: %{
             level: "global",
             board: nil,
             list: nil,
             card_view: nil,
             elements: %{"tags" => false},
             show_all: false
           }
         })}
      ])

      out = run("card-view", ["level"])

      assert_received {:request, "GET", "/api/card-views/level", _}
      assert out =~ "global level"
      assert out =~ ~r/applies:\s+none/
      assert out =~ ~r/hides:\s+tags/
      refute out =~ "show all"
    end

    test "level with a board and a list reads that list's, and says which" do
      serve([
        {200,
         JSON.encode!(%{
           level: %{
             level: "list",
             board: @plan,
             list: %{id: 9, name: "Doing"},
             card_view: %{id: 3, name: "Focus"},
             elements: %{},
             show_all: false
           }
         })}
      ])

      out = run("card-view", ["level"], board: "plan", list: "Doing")

      assert_received {:request, "GET", "/api/card-views/level?board=plan&list=Doing", _}
      assert out =~ "list level: Doing on Plan (plan)"
      assert out =~ ~r/applies:\s+Focus \(3\)/
    end

    test "a board's level says whether show all is on" do
      level = %{level: "board", board: @plan, list: nil, card_view: nil, elements: %{}}
      serve([{200, JSON.encode!(%{level: Map.put(level, :show_all, true)})}])

      assert run("card-view", ["level"], board: "plan") =~ ~r/show all:\s+on/
    end

    test "set puts the level's changes, --apply none and --show-all as the API takes them" do
      level = %{level: "board", board: @plan, list: nil, card_view: nil, elements: %{}}
      serve([{200, JSON.encode!(%{level: Map.put(level, :show_all, false)})}])

      run("card-view", ["set"],
        board: "plan",
        apply: "none",
        show: "tags,due_date",
        show_all: "off"
      )

      assert_received {:request, "PUT", "/api/card-views/level", body}

      assert JSON.decode!(body) == %{
               "board" => "plan",
               "card_view" => "none",
               "show" => "tags,due_date",
               "show_all" => false
             }
    end

    test "set refuses --show-all off a board's level, a bad value, and nothing to change" do
      assert {:error, "--show-all is a board's switch" <> _} =
               CardViews.plan("card-view", ["set"], board: "plan", list: "Doing", show_all: "on")

      assert {:error, "--show-all is a board's switch" <> _} =
               CardViews.plan("card-view", ["set"], show_all: "on")

      assert {:error, "--show-all takes on or off"} =
               CardViews.plan("card-view", ["set"], board: "plan", show_all: "maybe")

      assert {:error, "say what to change" <> _} =
               CardViews.plan("card-view", ["set"], board: "plan")

      assert {:ok, {:level, {:put, _, %{"show_all" => true}}}} =
               CardViews.plan("card-view", ["set"], board: "plan", show_all: "on")
    end

    test "a list without a board is refused before anything is sent" do
      for sub <- ~w(level set clear applied) do
        assert {:error, "--list needs --board" <> _} =
                 CardViews.plan("card-view", [sub], list: "Doing", show: "tags")
      end
    end

    test "clear deletes the level, named in the query" do
      level = %{level: "board", board: @plan, list: nil, card_view: nil, elements: %{}}
      serve([{200, JSON.encode!(%{level: Map.put(level, :show_all, false)})}])

      run("card-view", ["clear"], board: "plan")
      assert_received {:request, "DELETE", "/api/card-views/level?board=plan", _}
    end

    test "a list that is not on the board is the server's 404" do
      serve([{404, ~s({"error":"list not found"})}])
      {:ok, {:level, request}} = CardViews.plan("card-view", ["level"], board: "plan", list: "X")

      assert CardViews.send_request(request) == {:error, 404, %{"error" => "list not found"}}
    end
  end

  describe "applied" do
    test "prints each element shown or hidden and where it comes from" do
      serve([
        {200,
         JSON.encode!(%{
           board: @plan,
           list: %{id: 9, name: "Doing"},
           show_all: false,
           saved_view_card_view: "Focus",
           elements: [
             %{key: "tags", label: "Tags", group: "front", shown: false, source: "saved view"},
             %{key: "side.time", label: "Time", group: "side", shown: true, source: "default"}
           ]
         })}
      ])

      out = run("card-view", ["applied"], board: "plan", list: "Doing", view: "Mine")

      assert_received {:request, "GET", "/api/card-views/applied?board=plan&list=Doing&view=Mine",
                       _}

      assert out =~ "a card in Doing on Plan (plan)"
      assert out =~ "the saved view applies card view Focus on top"
      assert out =~ ~r/tags\s+hidden\s+saved view\s+Tags/
      assert out =~ ~r/side\.time\s+shown\s+default\s+Time/
    end

    test "with no board it is the global level alone" do
      serve([{200, ~s({"board":null,"list":null,"show_all":false,"elements":[]})}])
      out = run("card-view", ["applied"])

      assert_received {:request, "GET", "/api/card-views/applied", _}
      assert out =~ "global level only"
    end
  end

  test "the CLI routes card-views here and lists every form in the help" do
    serve([{200, JSON.encode!(%{card_views: [@focus], elements: @catalogue})}])
    assert capture_io(fn -> SlipdockCLI.main(["card-views"]) end) =~ "Focus"

    help = capture_io(fn -> SlipdockCLI.main(["--help"]) end)

    for usage <- [
          "card-views [--elements]",
          "card-view show <view>",
          "card-view new <name> [--show a,b] [--hide c,d]",
          "card-view edit <view> [--name N]",
          "card-view rm <view>",
          "card-view level [--board B] [--list L]",
          "card-view set [--board B] [--list L] [--apply VIEW|none]",
          "card-view clear [--board B] [--list L]",
          "card-view applied [--board B] [--list L] [--view SAVEDVIEW]"
        ],
        do: assert(help =~ usage, usage)
  end
end
