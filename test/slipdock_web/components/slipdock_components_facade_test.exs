defmodule SlipdockWeb.Components.SlipdockComponentsFacadeTest do
  @moduledoc """
  `SlipdockWeb.SlipdockComponents` defines nothing itself: its components and
  helpers live in the modules beneath it and it delegates to each. These
  tests hold what the modules that import it, or call it by name, rely on:
  every name is still there, a component's declarations are still what the
  compiler checks a call against, and a call through it still gets the
  component's defaults.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.SlipdockComponents
  alias SlipdockWeb.SlipdockComponents.CardFace
  alias SlipdockWeb.SlipdockComponents.Chrome
  alias SlipdockWeb.SlipdockComponents.Fields
  alias SlipdockWeb.SlipdockComponents.Marks
  alias SlipdockWeb.SlipdockComponents.Progress
  alias SlipdockWeb.SlipdockComponents.Schedule

  @sources [Marks, Schedule, Progress, CardFace, Chrome, Fields]

  # What the module exported while it still defined everything itself, bar
  # the two functions `use Phoenix.Component` and the verified routes
  # generate for the compiler's own use, and what it has been given since
  # (`view_empty/1`, #2885; `switch_field/1`, #2894).
  @exports [
    __components__: 0,
    age_chip: 1,
    assignee_chip: 1,
    assignee_chips: 1,
    avatar: 1,
    board_handles_title: 1,
    board_handles_title: 2,
    board_handles_title: 3,
    card: 1,
    card_borders: 1,
    color_swatch: 1,
    date_range_badge: 1,
    dependency_badge: 1,
    doc_link: 1,
    due_badge: 1,
    due_icon: 0,
    due_state: 2,
    favourite_toggle: 1,
    filter_menu: 1,
    flag_attention: 2,
    flag_chip_class: 1,
    flag_icon: 1,
    flag_icon_name: 2,
    flag_label: 1,
    flag_tip: 3,
    flag_toggle: 1,
    flags: 0,
    format_day: 1,
    format_due: 1,
    format_range: 2,
    health_label: 1,
    health_pill: 1,
    item_id: 1,
    keyed_label: 1,
    kind_icon: 1,
    modal: 1,
    open_item: 1,
    page?: 1,
    page_path: 1,
    past_date_detail: 3,
    past_date_label: 2,
    percent_badge: 1,
    priority_badge: 1,
    priority_bars: 1,
    priority_label: 1,
    priority_level: 1,
    priority_on_face?: 1,
    priority_options: 0,
    profile_chip: 1,
    quick_add_row: 1,
    relative_time: 1,
    schedule_badges: 1,
    show_set: 1,
    slip_chips: 1,
    snooze_mark: 1,
    stand_in_state: 1,
    stand_in_status: 1,
    start_badge: 1,
    start_icon: 0,
    start_words: 1,
    start_words: 2,
    stated_pill: 1,
    subcards_badge: 1,
    support_board_links: 1,
    support_time_left: 1,
    support_time_left: 2,
    switch_field: 1,
    tag_chip: 1,
    tag_toggle: 1,
    time_badge: 1,
    time_bar: 1,
    time_section: 1,
    timestamp: 1,
    view_empty: 1,
    view_tabs: 1,
    view_tabs_list: 0
  ]

  # A module that imports the facade and calls a component in a template,
  # compiled here so the compiler's warnings about the call can be read.
  defp compile_caller(heex, import_opts \\ "") do
    name = Module.concat(__MODULE__, "Caller#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(name)} do
      use Phoenix.Component
      import SlipdockWeb.SlipdockComponents#{import_opts}

      def render(assigns) do
        ~H\"\"\"
        #{String.replace(String.trim(heex), "\n", "\n        ")}
        \"\"\"
      end
    end
    """

    # The warnings are printed as well as returned; the print is kept off
    # the test run's output.
    {diagnostics, _printed} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        {_modules, diagnostics} =
          Code.with_diagnostics(fn -> Code.compile_string(source, "facade_caller.ex") end)

        diagnostics
      end)

    on_exit(fn ->
      :code.purge(name)
      :code.delete(name)
    end)

    {name, Enum.map(diagnostics, & &1.message)}
  end

  describe "the names" do
    test "every function the module exported is still exported" do
      exported = SlipdockComponents.__info__(:functions)
      assert @exports -- exported == []
    end

    test "it has no macros, as before" do
      assert SlipdockComponents.__info__(:macros) == []
    end

    test "each delegate is defined by one of the modules beneath it" do
      for {name, arity} <- @exports -- [__components__: 0] do
        assert [_one] = Enum.filter(@sources, &function_exported?(&1, name, arity)),
               "#{name}/#{arity} should be defined in exactly one module"
      end
    end

    test "an argument left to its default is the default of the function delegated to" do
      card = %Slipdock.Boards.Card{start_date: Date.add(Date.utc_today(), 1), rollup: nil}
      assert SlipdockComponents.start_words(card) == "Starts tomorrow"
      assert SlipdockComponents.start_words(card, Date.add(Date.utc_today(), 1)) == "Starts today"

      assert SlipdockComponents.support_time_left(~U[2020-01-01 00:00:00Z]) == "0m"

      assert SlipdockComponents.support_time_left(
               ~U[2020-01-01 03:52:00Z],
               ~U[2020-01-01 00:00:00Z]
             ) ==
               "3h 52m"

      board = %{code: "abc12", shortcut: "k"}
      assert SlipdockComponents.board_handles_title(board) == "Code: abc12\nSwitcher: b then k"
      assert SlipdockComponents.board_handles_title(board, "First") =~ "First\nCode: abc12"
      assert SlipdockComponents.board_handles_title(board, nil, 4) =~ "Ctrl+Shift+4"
    end

    test "a capture of it and an import of some of it reach the component" do
      render = &SlipdockComponents.percent_badge/1
      assert render_component(render, percent: 40) =~ "40% complete"

      {caller, warnings} =
        compile_caller(~s(<.percent_badge percent={40} />), ", only: [percent_badge: 1]")

      assert warnings == []
      assert render_component(&caller.render/1, %{}) =~ "40% complete"
    end
  end

  describe "__components__/0" do
    test "has every public component the modules beneath declare, with its declaration" do
      declared =
        for source <- @sources,
            {name, %{kind: :def} = component} <- source.__components__(),
            into: %{},
            do: {name, component}

      assert map_size(declared) > 30
      assert SlipdockComponents.__components__() == declared
    end

    test "leaves out the private ones, which nothing outside can call" do
      private =
        for source <- @sources,
            {name, %{kind: :defp}} <- source.__components__(),
            do: name

      assert :card_id in private
      assert :compact_row in private

      for name <- private do
        refute Map.has_key?(SlipdockComponents.__components__(), name)
        refute function_exported?(SlipdockComponents, name, 1)
      end
    end

    test "every component in it is a function the module exports" do
      for {name, component} <- SlipdockComponents.__components__() do
        assert {name, 1} in SlipdockComponents.__info__(:functions)
        assert is_list(component.attrs)
        assert is_list(component.slots)
      end
    end

    test "carries the attributes and slots a call is checked against" do
      components = SlipdockComponents.__components__()

      assert %{required: true, type: :any} =
               Enum.find(components.avatar.attrs, &(&1.name == :user))

      size = Enum.find(components.avatar.attrs, &(&1.name == :size))
      assert size.opts[:values] == ~w(xs sm md)
      assert size.opts[:default] == "sm"
      assert Enum.any?(components.avatar.attrs, &(&1.type == :global))

      assert Enum.map(components.modal.slots, & &1.name) == [:actions, :inner_block]
      assert Enum.find(components.modal.slots, &(&1.name == :inner_block)).required
      assert Enum.map(components.card.slots, & &1.name) == [:actions]
    end
  end

  describe "a component called through it" do
    test "gets the defaults of the attributes left out" do
      html = render_component(&SlipdockComponents.priority_bars/1, level: 2)
      assert html =~ ~s(class="shrink-0 size-3.5")
      assert html =~ ~s(data-level="2")

      html = render_component(&SlipdockComponents.avatar/1, user: nil)
      assert html =~ "size-6 text-2xs"
      assert html =~ "?"
    end

    test "gets its global attributes, and the defaults beside them" do
      html =
        render_component(&SlipdockComponents.flag_toggle/1,
          flag: "blocked",
          "phx-click": "filter_flag",
          "phx-value-flag": "blocked"
        )

      assert html =~ ~s(aria-pressed="false")
      assert html =~ ~s(phx-click="filter_flag")
      assert html =~ ~s(phx-value-flag="blocked")
      assert html =~ "Blocked"
    end

    test "gets them from a template that imports the module" do
      {caller, warnings} =
        compile_caller(~s(<.tag_chip tag={%{name: "bug", color: "rose"}} data-kind="tag" />))

      assert warnings == []
      html = render_component(&caller.render/1, %{})
      assert html =~ "px-2 py-1 text-xs"
      assert html =~ ~s(data-kind="tag")
      assert html =~ "bug"
    end

    test "gets its slots" do
      {caller, warnings} =
        compile_caller("""
        <.modal id="m" on_close={%Phoenix.LiveView.JS{}}>
          <:actions>the buttons</:actions>
          the body
        </.modal>
        """)

      assert warnings == []
      html = render_component(&caller.render/1, %{})
      assert html =~ "the buttons"
      assert html =~ "the body"
      assert html =~ "max-w-xl"
    end
  end

  describe "the compiler's checks on a call from a module that imports it" do
    test "a required attribute left out is warned about" do
      {_caller, warnings} = compile_caller(~s(<.avatar />))

      assert Enum.any?(
               warnings,
               &(&1 =~
                   ~s(missing required attribute "user" for component SlipdockWeb.SlipdockComponents.avatar/1))
             )
    end

    test "a call by the module's full name is checked the same way" do
      {_caller, warnings} =
        compile_caller(~s(<SlipdockWeb.SlipdockComponents.avatar size="md" />))

      assert Enum.any?(
               warnings,
               &(&1 =~
                   ~s(missing required attribute "user" for component SlipdockWeb.SlipdockComponents.avatar/1))
             )
    end

    test "an attribute the component does not declare is warned about" do
      {_caller, warnings} = compile_caller(~s(<.percent_badge percent={40} colour="rose" />))

      assert Enum.any?(
               warnings,
               &(&1 =~
                   ~s(undefined attribute "colour" for component SlipdockWeb.SlipdockComponents.percent_badge/1))
             )
    end

    test "a value outside the ones the attribute takes is warned about" do
      {_caller, warnings} = compile_caller(~s(<.avatar user={nil} size="huge" />))

      assert Enum.any?(warnings, &(&1 =~ ~s(attribute "size" in component)))
      assert Enum.any?(warnings, &(&1 =~ ~s(must be one of ["xs", "sm", "md"])))
    end

    test "a required slot left out and a slot not declared are warned about" do
      {_caller, warnings} =
        compile_caller(~s(<.modal id="m" on_close={%Phoenix.LiveView.JS{}} />))

      assert Enum.any?(warnings, &(&1 =~ ~s(missing required slot "inner_block")))

      {_caller, warnings} =
        compile_caller("""
        <.modal id="m" on_close={%Phoenix.LiveView.JS{}}>
          <:footer>no such slot</:footer>
          the body
        </.modal>
        """)

      assert Enum.any?(warnings, &(&1 =~ ~s(undefined slot "footer")))
    end

    test "a call that gives what is declared draws no warning" do
      {_caller, warnings} =
        compile_caller(~s(<.avatar user={nil} size="md" id="who" class="ring-1" />))

      assert warnings == []
    end
  end
end
