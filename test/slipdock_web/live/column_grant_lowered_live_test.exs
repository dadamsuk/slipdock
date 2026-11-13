defmodule SlipdockWeb.ColumnGrantLoweredLiveTest do
  @moduledoc """
  A list's settings, open while their reader's grant is lowered, refuse the
  write (#2946).

  `ColumnComponent` works out what its reader may do when the board hands it
  its assigns, as the panels in `PanelGrantLoweredLiveTest` (#2771) did. Each
  test opens a board as a writer, lowers the grant to read, and sends the
  component's writes: whatever it still shows, nothing is stored.

  The grant is lowered two ways. `:told` is `Access.grant/4`, which tells the
  board. `:untold` changes the grant's row and tells nobody: it stands for a
  lowering the open board never hears of (a group's membership, a grant on
  the card a sub-board hangs from) and for an event that arrives before the
  board has taken the news in.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Repo}
  alias Slipdock.Access.Grant
  alias Slipdock.Boards.Column

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Lowered"}, owner: owner)
    writer = user_fixture("writer@example.com")
    {:ok, _} = Access.grant(board, writer, "write", owner)

    %{board: board, owner: owner, writer: writer}
  end

  defp as(user), do: log_in_user(build_conn(), user)

  defp lower(:told, ctx) do
    {:ok, _} = Access.grant(ctx.board, ctx.writer, "read", ctx.owner)
    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  defp lower(:untold, ctx) do
    assert {1, _} =
             Repo.update_all(
               from(g in Grant,
                 where: g.board_id == ^ctx.board.id and g.user_id == ^ctx.writer.id
               ),
               set: [level: "read"]
             )

    assert Access.board_permission(ctx.writer, ctx.board) == :read
  end

  # Told, the board stops drawing the list settings for a reader; untold,
  # they are still there and refuse the write themselves.
  defp refused(view, :told), do: refute(has_element?(view, "#board-column"))

  defp refused(view, :untold),
    do: assert(render(view) =~ "You have read-only access to this board.")

  defp columns(board),
    do: Repo.all(from(c in Column, where: c.board_id == ^board.id, order_by: c.id))

  for how <- [:told, :untold] do
    describe "the grant lowered to read, the board #{how}:" do
      test "a list's settings save, recolour and delete nothing", ctx do
        [column | _] = before = columns(ctx.board)
        id = "#{column.id}"

        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")
        settings = with_target(view, "#board-column")

        # Opened while the reader could still write.
        render_hook(settings, "edit_column", %{"id" => id})
        assert has_element?(view, "#column-modal")

        lower(unquote(how), ctx)

        render_hook(settings, "set_column_color", %{"color" => "rose"})

        render_hook(settings, "save_column", %{
          "column" => %{"name" => "Renamed", "wip_limit" => "3"}
        })

        render_hook(settings, "delete_column", %{"id" => id})

        assert columns(ctx.board) == before
        refused(view, unquote(how))
      end

      test "a list's settings no longer open", ctx do
        [column | _] = columns(ctx.board)
        {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")

        lower(unquote(how), ctx)

        view
        |> with_target("#board-column")
        |> render_hook("edit_column", %{"id" => "#{column.id}"})

        refute has_element?(view, "#column-modal")
        refused(view, unquote(how))
      end
    end
  end

  test "a writer whose grant is unchanged still saves the list", ctx do
    [column | _] = columns(ctx.board)
    {:ok, view, _} = live(as(ctx.writer), ~p"/boards/#{ctx.board}")
    settings = with_target(view, "#board-column")

    render_hook(settings, "edit_column", %{"id" => "#{column.id}"})
    render_hook(settings, "save_column", %{"column" => %{"name" => "Renamed"}})

    assert Repo.get!(Column, column.id).name == "Renamed"
  end
end
