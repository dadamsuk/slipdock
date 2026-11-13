defmodule SlipdockWeb.APIGuideDocsPlacesTest do
  @moduledoc """
  The guide's *Verified work* section names the docs places SPEC-10 is
  checked across (#2763). They come from `Slipdock.Verified.docs_places/0`,
  so each place there, its name and the files to grep, is in the guide, and
  so is how many there are.
  """
  use SlipdockWeb.ConnCase, async: true

  alias SlipdockWeb.APIGuide

  defp verifying_reader do
    owner = Slipdock.Fixtures.user_fixture("guide-places@example.com")
    board = Slipdock.Fixtures.board_fixture(%{"name" => "Places"}, owner: owner)
    {:ok, _board} = Slipdock.Boards.update_board(board, %{"verify_work" => true})
    owner
  end

  test "every docs place in Verified.docs_places/0 is in the guide, with its files" do
    guide = APIGuide.markdown(user: verifying_reader())
    places = Slipdock.Verified.docs_places()

    assert places != []

    for {name, files} <- places do
      assert guide =~ "#{name}: `#{files}`",
             "the guide doesn't show the docs place #{inspect(name)} (`#{files}`)"
    end

    [_, count] = Regex.run(~r/grep them across the (\w+) places \(/, guide)

    assert count == Integer.to_string(length(places))
  end

  test "a reader with no verifying board isn't shown the places" do
    owner = Slipdock.Fixtures.user_fixture("guide-places-none@example.com")
    guide = APIGuide.markdown(user: owner)

    refute guide =~ "grep them across the"
  end
end
