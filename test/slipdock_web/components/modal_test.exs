defmodule SlipdockWeb.ModalTest do
  @moduledoc """
  `modal/1` on a phone (#1862). A page wider than the phone makes mobile
  Chrome widen the layout viewport to fit it, and an overlay sized by
  `inset-0` widened with it, leaving board settings half off the screen.
  Below `sm` the overlay is sized to the screen instead; at `sm` and up it
  keeps `inset-0`. The browser half is `tools/e2e/board-settings.sh`.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.JS
  alias SlipdockWeb.SlipdockComponents

  defp classes(size) do
    assigns = %{size: size}

    html =
      rendered_to_string(~H"""
      <SlipdockComponents.modal id="m" on_close={JS.patch("/back")} size={@size}>
        Body
      </SlipdockComponents.modal>
      """)

    [overlay] = html |> LazyHTML.from_fragment() |> LazyHTML.query("#m") |> Enum.to_list()
    [sheet] = overlay |> LazyHTML.query(".kanban-modal-in") |> Enum.to_list()
    {split(overlay), split(sheet)}
  end

  defp split(node), do: node |> LazyHTML.attribute("class") |> hd() |> String.split()

  for size <- ~w(sm md lg xl page wide) do
    test "a #{size} modal's overlay is the screen's size below sm, whatever the page's width" do
      {overlay, _sheet} = classes(unquote(size))

      assert "max-sm:w-screen" in overlay
      assert "max-sm:h-dvh" in overlay
      # Still pinned to the top left, and the sheet fills the overlay's width.
      assert "fixed" in overlay
      assert "inset-0" in overlay
    end
  end

  test "the sheet fills the overlay on a phone and keeps its cap from sm up" do
    {overlay, sheet} = classes("lg")

    assert "w-full" in sheet
    assert "max-w-4xl" in sheet
    # Nothing outside a max-sm: variant sets the overlay's own width or
    # height, so desktop keeps inset-0 and never takes in the scrollbar.
    refute Enum.any?(overlay, &(&1 in ~w(w-screen h-dvh h-screen)))
    refute Enum.any?(overlay, &String.starts_with?(&1, "sm:w-"))
  end
end
