defmodule SlipdockWeb.ComponentFlashTest do
  @moduledoc """
  One helper and one message shape for a LiveComponent's flash (#2895):
  `SlipdockWeb.ComponentFlash.flash/3` sends `{:put_flash, kind, message}`
  to the LiveView the component runs in. Before it the account's sections
  wrote `{:flash, …}` out by hand and the board's components sent
  `{:put_flash, …}`.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.BoardLive.Helpers
  alias SlipdockWeb.ComponentFlash

  @helper "lib/slipdock_web/live/component_flash.ex"

  test "flash/3 sends the page the flash and hands the socket back" do
    socket = %Phoenix.LiveView.Socket{}

    assert ComponentFlash.flash(socket, :info, "Saved.") == socket
    assert_received {:put_flash, :info, "Saved."}

    assert ComponentFlash.flash(socket, :error, "No.") == socket
    assert_received {:put_flash, :error, "No."}
    refute_received _
  end

  test "the board's helper is the same one" do
    socket = %Phoenix.LiveView.Socket{}

    assert Helpers.flash(socket, :error, "No.") == socket
    assert_received {:put_flash, :error, "No."}
  end

  # A message written out by hand: `send(self(), {:put_flash, …})` or the
  # account's old `{:flash, …}`.
  defp by_hand(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> line =~ ~r/send\(\s*self\(\),\s*\{:(?:put_)?flash,/ end)
  end

  test "no component writes the message out itself" do
    hits =
      for path <- Path.wildcard("lib/slipdock_web/**/*.{ex,heex}"),
          path != @helper,
          {line, n} <- by_hand(File.read!(path)),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == [],
           "A component's flash goes through SlipdockWeb.ComponentFlash.flash/3 " <>
             "(or notice/3 in a panel, UX-29):\n" <> Enum.join(hits, "\n")
  end

  test "the scan catches both shapes, and the helper is the one place left" do
    assert [_] = by_hand(~s|send(self(), {:put_flash, :error, "No."})|)
    assert [_] = by_hand(~s|        send(self(), {:flash, :info, "Profile saved."})|)
    assert by_hand(~s|send(self(), {:current_user, user})|) == []
    assert by_hand(~s/socket |> flash(:info, "Saved.")/) == []
    assert [_] = by_hand(File.read!(@helper))
  end

  test "every page that hosts such a component answers the message" do
    for path <- ~w(
          lib/slipdock_web/live/account_live/index.ex
          lib/slipdock_web/live/board_live/show.ex
          lib/slipdock_web/live/wiki_live/index.ex
          lib/slipdock_web/live/shared_live.ex
        ) do
      assert File.read!(path) =~ "def handle_info({:put_flash, kind, message}, socket)",
             "#{path} no longer takes {:put_flash, kind, message}"
    end
  end
end
