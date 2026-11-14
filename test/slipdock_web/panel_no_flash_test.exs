defmodule SlipdockWeb.PanelNoFlashTest do
  @moduledoc """
  UX-29 (#1973, #1978): what an action in the card modal, the page panel or
  the board's other modals (runners, move to another board, archive, tags)
  says (a refusal, a result) is a `<.callout>` at the top of the panel
  (`BoardLive.Helpers.notice/3`), never a flash. The toast's dismissal reads
  as a click-away and closes the modal.

  This reads the modules those panels are made of and fails on any
  `flash(`/`put_flash(` that is not one of the named exceptions below, and
  on a `{:put_flash, …}` message written out by hand, which is the same
  flash without the helper's name (#2895).
  """
  use ExUnit.Case, async: true

  @panel_files ~w(
    lib/slipdock_web/live/board_live/card_component.ex
    lib/slipdock_web/live/board_live/card_component/field_events.ex
    lib/slipdock_web/live/board_live/card_component/glance.ex
    lib/slipdock_web/live/board_live/card_component/handoff_events.ex
    lib/slipdock_web/live/board_live/card_component/link_events.ex
    lib/slipdock_web/live/board_live/card_component/modal.ex
    lib/slipdock_web/live/board_live/card_component/repeat_events.ex
    lib/slipdock_web/live/board_live/card_component/state.ex
    lib/slipdock_web/live/board_live/card_component/wait_events.ex
    lib/slipdock_web/live/board_live/card_sections.ex
    lib/slipdock_web/live/board_live/card_panel.ex
    lib/slipdock_web/live/board_live/card_panel/attachments.ex
    lib/slipdock_web/live/board_live/card_panel/chips.ex
    lib/slipdock_web/live/board_live/card_panel/properties.ex
    lib/slipdock_web/live/board_live/card_panel/schedule.ex
    lib/slipdock_web/live/board_live/card_panel/verify.ex
    lib/slipdock_web/live/board_live/wait_components.ex
    lib/slipdock_web/live/board_live/item_events.ex
    lib/slipdock_web/live/board_live/page_component.ex
    lib/slipdock_web/components/item_components.ex
    lib/slipdock_web/live/board_live/runners_component.ex
    lib/slipdock_web/live/board_live/move_board_component.ex
    lib/slipdock_web/live/board_live/archive_component.ex
    lib/slipdock_web/live/board_live/tags_component.ex
  )

  # {file, the text on the line, why it is a flash}. The panel is gone when
  # each of these shows, so there is no modal for the toast to close.
  @exceptions [
    {"lib/slipdock_web/live/board_live/card_component/link_events.ex",
     ~s|put_flash(:info, "Started|,
     "Write it up navigates to the new page's editor, leaving the board"},
    {"lib/slipdock_web/live/board_live/move_board_component.ex",
     ~s|flash(socket, :error, "You have read-only access to that card.")|,
     "a read-only open_move_board never opens the picker, so there is no modal to say it in"},
    {"lib/slipdock_web/live/board_live/move_board_component.ex", "put_flash(:info, message)",
     "the move done closes the picker and follows the open card to its new board"},
    {"lib/slipdock_web/live/board_live/move_board_component.ex", "flash(socket, :info, message)",
     "the move done closes the picker, and no card panel is open on that card"}
  ]

  defp flashes(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> line =~ ~r/(?<!\w)(?:put_)?flash\(|\{:put_flash,/ end)
    |> Enum.reject(fn {line, _} -> String.trim_leading(line) |> String.starts_with?("#") end)
  end

  defp excepted?(path, line),
    do: Enum.any?(@exceptions, fn {file, text, _} -> file == path and line =~ text end)

  test "no flash in the board's panels and modals" do
    hits =
      for path <- @panel_files,
          {line, n} <- flashes(File.read!(path)),
          not excepted?(path, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == [],
           "A panel action says what happened with notice/3, a callout at the panel's top " <>
             "(UX-29), or is a named exception in this test with its reason:\n" <>
             Enum.join(hits, "\n")
  end

  test "every exception still matches a line, and every panel file exists" do
    for path <- @panel_files, do: assert(File.exists?(path), "#{path} is gone")

    for {file, text, _why} <- @exceptions do
      assert Enum.any?(flashes(File.read!(file)), fn {line, _} -> line =~ text end),
             "stale exception: no flash in #{file} matches #{inspect(text)}"
    end
  end

  test "the scan catches both spellings and skips comments and other names" do
    assert [_] = flashes(~s|{:noreply, flash(socket, :error, "No.")}|)
    assert [_] = flashes(~s/socket |> put_flash(:info, "Yes.")/)
    assert [_] = flashes(~s/|> flash(:error, message)/)
    assert [_] = flashes(~s|Helpers.flash(socket, :error, "No.")|)
    assert [_] = flashes(~s|send(self(), {:put_flash, :error, describe(reason)})|)
    assert [_] = flashes(~s|do: send(self(), {:put_flash, :info, "Done."})|)
    assert flashes(~s|  # never a flash(socket, ...) here|) == []
    assert flashes(~s|notice(socket, :error, "No.")|) == []
    assert flashes(~s|Phoenix.Flash.get(@flash, :info)|) == []
    assert flashes(~s|live_flash(@flash, :info)|) == []
  end
end
