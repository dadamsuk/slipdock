defmodule SlipdockWeb.BoardLive.PanelGuardTest do
  use ExUnit.Case, async: true

  alias SlipdockWeb.BoardLive.PanelGuard

  # A panel's gate, as a board panel would write it: a list, a refresh that
  # counts its calls, a quiet refusal, a pass and two refusals.
  defmodule Sample do
    @events ~w(look write share comment manage)
    @write_events ~w(write share comment)

    @behaviour Phoenix.LiveComponent
    use SlipdockWeb.BoardLive.PanelGuard,
      events: @events,
      access: &refreshed/1,
      prepare: &Phoenix.Component.assign(&1, prepared: true),
      refusals: [
        {:gone, true, :all, :quiet},
        {:can_share, false, ~w(share), "You can't share that."},
        {:can_comment, true, ~w(comment), :pass},
        {:can_write, false, @write_events, :read_only},
        {:can_manage, false, {:except, ~w(look write share comment)}, :owner}
      ],
      say: :error

    defp refreshed(socket),
      do: Phoenix.Component.assign(socket, refreshed: (socket.assigns[:refreshed] || 0) + 1)

    defp event(event, _params, socket),
      do: {:noreply, Phoenix.Component.assign(socket, handled: event)}
  end

  # One that names its handler, runs something on what it returns, and says
  # a refusal its own way.
  defmodule Replying do
    @behaviour Phoenix.LiveComponent
    use SlipdockWeb.BoardLive.PanelGuard,
      events: ~w(open shut),
      refusals: [{:can_write, false, :all, &__MODULE__.why/1}],
      say: &__MODULE__.said/2,
      then: :handle,
      after: &Phoenix.Component.assign(&1, after: true)

    def why(socket), do: "No, #{socket.assigns.name}."
    def said(socket, message), do: Phoenix.Component.assign(socket, said: message)

    defp handle("open", _params, socket), do: {:reply, %{ok: true}, socket}
    defp handle("shut", _params, socket), do: {:noreply, socket}
  end

  # One whose refresh finds a writer turned reader.
  defmodule Lowering do
    @behaviour Phoenix.LiveComponent
    use SlipdockWeb.BoardLive.PanelGuard,
      events: ~w(write),
      access: &Phoenix.Component.assign(&1, can_write: false),
      refusals: [{:can_write, false, :all, :read_only}],
      say: :error

    defp event(_, _, socket), do: {:noreply, socket}
  end

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, Map.new(assigns))}

  @writer [can_write: true, can_share: true, can_comment: true, can_manage: true]

  describe "the clauses `use` writes" do
    test "an event not on the list is refused before anything is read" do
      {:noreply, s} = Sample.handle_event("drop_table", %{}, socket(@writer))
      assert s.assigns.error == "That isn't something this page can do."
      refute Map.has_key?(s.assigns, :refreshed)
      refute Map.has_key?(s.assigns, :handled)
    end

    test "an event on the list is refreshed, prepared and handled" do
      {:noreply, s} = Sample.handle_event("write", %{}, socket(@writer))
      assert s.assigns.refreshed == 1
      assert s.assigns.prepared
      assert s.assigns.handled == "write"
      refute Map.has_key?(s.assigns, :error)
    end

    test "the guards read what the refresh found, not what the socket had" do
      {:noreply, s} = Lowering.handle_event("write", %{}, socket(can_write: true))
      assert s.assigns.error == "You have read-only access to this board."
    end

    test "a quiet refusal does nothing and says nothing" do
      {:noreply, s} = Sample.handle_event("write", %{}, socket([gone: true] ++ @writer))
      refute Map.has_key?(s.assigns, :handled)
      refute Map.has_key?(s.assigns, :error)
    end

    test "a read-only reader is refused a write, and may still look" do
      reader = [can_write: false, can_share: true, can_comment: false, can_manage: true]

      {:noreply, s} = Sample.handle_event("write", %{}, socket(reader))
      assert s.assigns.error == "You have read-only access to this board."
      refute Map.has_key?(s.assigns, :handled)

      {:noreply, s} = Sample.handle_event("look", %{}, socket(reader))
      assert s.assigns.handled == "look"
    end

    test "the first refusal that matches decides" do
      # Neither a sharer nor a writer: the share refusal comes first.
      {:noreply, s} =
        Sample.handle_event(
          "share",
          %{},
          socket(Keyword.merge(@writer, can_share: false, can_write: false))
        )

      assert s.assigns.error == "You can't share that."
    end

    test "a pass lets the event through the refusals after it" do
      commenter = [can_write: false, can_share: false, can_comment: true, can_manage: false]
      {:noreply, s} = Sample.handle_event("comment", %{}, socket(commenter))
      assert s.assigns.handled == "comment"
      refute Map.has_key?(s.assigns, :error)
    end

    test "an owner's event is refused to anybody else" do
      {:noreply, s} =
        Sample.handle_event("manage", %{}, socket(Keyword.put(@writer, :can_manage, false)))

      assert s.assigns.error == "Only the board's owner can do that."
    end

    test "a refusal is noreply, said by the panel's own function, and skips `after`" do
      {:noreply, s} = Replying.handle_event("open", %{}, socket(can_write: false, name: "Ann"))

      assert s.assigns.said == "No, Ann."
      refute Map.has_key?(s.assigns, :after)

      {:noreply, s} = Replying.handle_event("nope", %{}, socket(can_write: true))
      assert s.assigns.said == "That isn't something this page can do."
    end

    test "the named handler runs, and `after` runs on what it returns" do
      assert {:reply, %{ok: true}, s} =
               Replying.handle_event("open", %{}, socket(can_write: true))

      assert s.assigns.after
      assert {:noreply, s} = Replying.handle_event("shut", %{}, socket(can_write: true))
      assert s.assigns.after
    end
  end

  describe "verdict/3" do
    test "with nothing to refuse, the event is handled" do
      assert PanelGuard.verdict("x", socket([]), []) == :ok
    end

    test "an assign that isn't there matches nil" do
      assert PanelGuard.verdict("x", socket([]), [{:card, nil, :all, :quiet}]) == :quiet
    end

    test "events are a list, :all, or all but a list" do
      s = socket(can_write: false)

      assert PanelGuard.verdict("a", s, [{:can_write, false, ~w(a), "no"}]) == {:refuse, "no"}
      assert PanelGuard.verdict("b", s, [{:can_write, false, ~w(a), "no"}]) == :ok

      assert PanelGuard.verdict("b", s, [{:can_write, false, {:except, ~w(a)}, "no"}]) ==
               {:refuse, "no"}

      assert PanelGuard.verdict("a", s, [{:can_write, false, {:except, ~w(a)}, "no"}]) == :ok
    end

    test "only the value named matches" do
      assert PanelGuard.verdict("a", socket(can_write: true), [{:can_write, false, :all, "no"}]) ==
               :ok
    end
  end

  describe "the sentences" do
    test "are the ones every panel says" do
      assert PanelGuard.unknown() == "That isn't something this page can do."
      assert PanelGuard.read_only() == "You have read-only access to this board."
      assert PanelGuard.owner() == "Only the board's owner can do that."
    end
  end

  describe "tell_board/4" do
    test "tells the board only when the picker opens or shuts" do
      s = PanelGuard.tell_board(socket(picker: :open, picking: false), :picker, :picking, :picked)
      assert s.assigns.picking
      assert_received {:picked, true}

      s = PanelGuard.tell_board(s, :picker, :picking, :picked)
      refute_received {:picked, _}

      s =
        PanelGuard.tell_board(
          %{s | assigns: Map.put(s.assigns, :picker, nil)},
          :picker,
          :picking,
          :picked
        )

      refute s.assigns.picking
      assert_received {:picked, false}
    end
  end
end
