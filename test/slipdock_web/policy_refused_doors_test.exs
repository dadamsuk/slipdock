defmodule SlipdockWeb.PolicyRefusedDoorsTest do
  @moduledoc """
  A write the context refuses (`Slipdock.Policy`, #3168) comes back through
  each door as that door's own refusal: a 403 on REST, a tool error on MCP,
  and words in the Tags panel and the card panel (#3167).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Actor, Boards, Policy}
  alias Slipdock.Policy.Refused
  alias SlipdockWeb.API.FallbackController
  alias SlipdockWeb.MCP.Args

  defp refused(by) do
    {:error,
     %Refused{action: :create_tag, need: :write, by: by, message: "Making a tag needs write."}}
  end

  test "REST answers 403 with the refusal", %{conn: conn} do
    conn = FallbackController.call(conn, refused(:token))

    assert json_response(conn, 403) == %{"error" => "forbidden: Making a tag needs write."}
  end

  test "MCP answers a tool error with the refusal" do
    assert Args.refusal(refused(:user)) == {:error, "forbidden: Making a tag needs write."}
  end

  describe "the panels, when the context refuses what the door let through" do
    setup %{conn: conn} do
      owner = user_fixture("doors.owner@example.com")
      board = board_fixture(%{"name" => "Doors"}, owner: owner)
      card = card_fixture(hd(board.columns), %{"title" => "Card"})
      tag = tag_fixture(board, "ops")

      {:ok, _} =
        Policy.as_system("a test fixture", fn -> Boards.Tags.toggle_card_tag(card, tag) end)

      %{conn: log_in_user(conn, owner), owner: owner, board: board, card: card, tag: tag}
    end

    # The LiveView's process is the door: after mount, its actor is made
    # nobody, so the panel's own guard (the owner's level) passes and only
    # the context refuses.
    defp nobody_in(view) do
      :sys.replace_state(view.pid, fn state ->
        Actor.put(nil)
        Policy.forbid_nobody()
        state
      end)
    end

    test "the Tags panel says it, and the tag stays", %{conn: conn, board: board, tag: tag} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/tags")
      nobody_in(view)

      html = view |> element("#delete-tag-#{tag.id}") |> render_click()
      assert html =~ "nobody acting"
      assert Enum.map(Boards.Tags.list_tags(board.id), & &1.name) == ["ops"]
    end

    test "the card panel says it, and the card keeps its tags",
         %{conn: conn, board: board, card: card, tag: tag} do
      {:ok, view, _} = live(conn, ~p"/boards/#{board.id}/cards/#{card.id}")
      nobody_in(view)

      view
      |> element("#card-tag-pick-#{tag.id}")
      |> render_click()

      assert view |> element("#card-modal #panel-notice[data-callout=error]") |> render() =~
               "Tag not changed"

      assert Enum.map(Slipdock.Repo.preload(card, :tags, force: true).tags, & &1.name) == ["ops"]
    end
  end
end
