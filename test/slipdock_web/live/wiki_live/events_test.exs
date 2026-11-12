defmodule SlipdockWeb.WikiLive.EventsTest do
  @moduledoc """
  The wiki view's events, split out of `WikiLive.Index` into modules by what
  they act on (#2788): each module says which events it handles, read off
  its own clauses, and `Index.handle_event/3` hands each to its module. The
  wiki's live tests drive the events themselves; this holds the dispatch.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias SlipdockWeb.WikiLive.{Index, ItemEvents, PageEvents, TreeEvents}

  defmodule Sample do
    @moduledoc false
    use SlipdockWeb.WikiLive.Events

    def handle_event("first", %{"id" => _}, socket), do: {:noreply, socket}
    def handle_event("first", _params, socket), do: {:noreply, socket}
    def handle_event("second", _params, socket), do: {:reply, %{ok: true}, socket}
    def handle_event(other, _params, socket) when is_binary(other), do: {:noreply, socket}

    def not_an_event("third"), do: :ok
  end

  @modules [PageEvents, TreeEvents, ItemEvents]

  describe "events/0" do
    test "names each literal event once, however many clauses it has" do
      assert Sample.events() == ["first", "second"]
    end

    test "leaves out a clause that names no event, and other functions' strings" do
      refute "third" in Sample.events()
      assert Sample.handle_event("anything", %{}, :socket) == {:noreply, :socket}
    end

    test "no event belongs to two of the wiki's modules" do
      all = Enum.flat_map(@modules, & &1.events())

      assert all != []
      assert all -- Enum.uniq(all) == []
    end

    test "each module has events of its own" do
      assert "save" in PageEvents.events()
      assert "tree_view" in TreeEvents.events()
      assert "move_to" in ItemEvents.events()
    end
  end

  describe "Index.handle_event/3" do
    test "hands an event to the module that names it" do
      socket = %Socket{}

      assert Index.handle_event("tree_view", %{"view" => "neither"}, socket) ==
               {:noreply, socket}

      assert Index.handle_event("tree_preview", %{}, socket) ==
               {:reply, %{found: false}, socket}

      assert Index.handle_event("comment_change", %{}, socket) == {:noreply, socket}
    end

    test "an event no module names fails as an unmatched clause did" do
      assert_raise FunctionClauseError, fn ->
        Index.handle_event("no_such_event", %{}, %Socket{})
      end
    end
  end
end
