defmodule SlipdockWeb.MachineServingLevelTest do
  @moduledoc """
  The boards a machine may serve are the ones its owner owns or can write
  to (#2755), asked wherever the boards are chosen: an enrolment key, an
  approval and a machine's new runner, in the context, over the API and on
  the pages. Somebody who reads a board, or holds one of its saved views,
  is offered it nowhere and refused it everywhere; a writer keeps it.
  """
  # Sync: the API's rate-limit counts are one table for the node.
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Machines, Repo}
  alias Slipdock.Machines.{EnrolmentKey, Machine}
  alias Slipdock.Runners.{MachineRunners, Runner}

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}
  @dir "/srv/src/app"
  @refusal "not a top-level board you can write to"

  # `ctx.user` is the one asking. `theirs` is somebody else's board, and
  # `own` a board of the asker's, so there is always one they may serve.
  setup %{user: user} do
    Slipdock.RateLimit.reset()
    owner = user_fixture("owner@example.com")
    theirs = board_fixture(%{"name" => "Somebody else's", "code" => unique_code()}, owner: owner)
    own = board_fixture(%{"name" => "My own", "code" => unique_code()}, owner: user)
    %{owner: owner, theirs: theirs, own: own}
  end

  defp grant(ctx, "view") do
    {:ok, view} = Boards.SavedViews.create_saved_view(ctx.theirs, %{"name" => "Shared view"})
    {:ok, _} = Access.grant(view, ctx.user, "write", ctx.owner)
    assert Access.board_permission(ctx.user, ctx.theirs) == :view
    ctx
  end

  defp grant(ctx, level) do
    {:ok, _} = Access.grant(ctx.theirs, ctx.user, level, ctx.owner)
    assert Access.board_permission(ctx.user, ctx.theirs) == String.to_existing_atom(level)
    ctx
  end

  defp pending do
    {:ok, {device_code, enrolment}} = Machines.request_enrolment(@about)
    {device_code, enrolment}
  end

  # A machine of the asker's that serves both boards: as one enrolled while
  # they could still write to `theirs` would.
  defp machine_serving_both(ctx) do
    {:ok, key, _} = Machines.create_enrolment_key(ctx.user, [ctx.own.id])
    {:ok, {_, machine}} = Machines.enrol_with_key(key, @about)

    machine
    |> Ecto.Changeset.change(board_ids: [ctx.own.id, ctx.theirs.id])
    |> Repo.update!()
  end

  defp nothing_enrolled do
    assert Repo.aggregate(EnrolmentKey, :count) == 0
    assert Repo.aggregate(Machine, :count) == 0
  end

  for level <- ~w(view read comment) do
    describe "with a #{level} grant on the board" do
      setup ctx, do: grant(ctx, unquote(level))

      test "the context offers and names only the boards they may serve", ctx do
        assert ctx.user |> Machines.servable_boards(archived: :all) |> Enum.map(& &1.id) ==
                 [ctx.own.id]

        assert {:error, :invalid, @refusal <> ": " <> named} =
                 Machines.servable_board_ids(ctx.user, [ctx.own.id, ctx.theirs.code])

        assert named == ctx.theirs.code
      end

      test "an enrolment key is refused: context, API and page", ctx do
        assert {:error, :invalid, @refusal <> _} =
                 Machines.create_enrolment_key(ctx.user, [ctx.theirs.id])

        assert %{"error" => @refusal <> _} =
                 ctx.conn
                 |> post(~p"/api/machines/enrolment-keys", %{boards: [ctx.own.id, ctx.theirs.id]})
                 |> json_response(422)

        {:ok, view, _} = live(ctx.conn, ~p"/account/machines")
        form = "form[phx-submit=create_key]"
        assert has_element?(view, ~s{#{form} input[name="boards[]"][value="#{ctx.own.id}"]})
        refute has_element?(view, ~s{#{form} input[name="boards[]"][value="#{ctx.theirs.id}"]})

        # The board isn't offered; posting it anyway is refused too.
        html = view |> element(form) |> render_submit(%{"boards" => ["#{ctx.theirs.id}"]})
        assert html =~ @refusal
        refute has_element?(view, "#new-enrolment-key")

        nothing_enrolled()
      end

      test "an approval is refused and stays pending: context, API and page", ctx do
        {device_code, enrolment} = pending()

        assert {:error, :invalid, @refusal <> _} =
                 Machines.approve_enrolment(enrolment, ctx.user, [ctx.theirs.id])

        assert %{"error" => @refusal <> _} =
                 ctx.conn
                 |> post(~p"/api/machines/enrolment/approve", %{
                   user_code: enrolment.user_code,
                   boards: [ctx.theirs.code]
                 })
                 |> json_response(422)

        {:ok, view, _} =
          live(ctx.conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")

        form = "#machine-approve-form"
        assert has_element?(view, ~s{#{form} input[value="#{ctx.own.id}"]})
        refute has_element?(view, ~s{#{form} input[value="#{ctx.theirs.id}"]})

        html = view |> element(form) |> render_submit(%{"boards" => ["#{ctx.theirs.id}"]})
        assert html =~ @refusal

        assert Machines.poll_enrolment(device_code) == {:error, :authorization_pending}
        nothing_enrolled()
      end

      test "a runner for the board is refused on a machine that names it: API and page", ctx do
        machine = machine_serving_both(ctx)
        runner = %{"pool" => "build", "name" => "", "directory" => @dir}

        assert %{"error" => @refusal <> _} =
                 ctx.conn
                 |> post(~p"/api/machines/#{machine.id}/runners", %{
                   board: ctx.theirs.id,
                   pool: "build",
                   config: %{directory: @dir}
                 })
                 |> json_response(422)

        {:ok, view, _} = live(ctx.conn, ~p"/machines/#{machine.id}")
        view |> element("button[phx-click=new_runner]") |> render_click()
        form = "#machine-runner-form"
        assert has_element?(view, ~s{#{form} option[value="#{ctx.own.id}"]})
        refute has_element?(view, ~s{#{form} option[value="#{ctx.theirs.id}"]})

        html =
          view
          |> element(form)
          |> render_submit(%{"runner" => Map.put(runner, "board", "#{ctx.theirs.id}")})

        assert html =~ "choose one of the boards the machine serves"
        assert MachineRunners.list_runners(machine) == []
        assert Repo.aggregate(Runner, :count) == 0

        # Their own board, on the same machine, still takes one.
        view
        |> element(form)
        |> render_submit(%{"runner" => Map.put(runner, "board", "#{ctx.own.id}")})

        assert [%Runner{board_id: board_id}] = MachineRunners.list_runners(machine)
        assert board_id == ctx.own.id
      end
    end
  end

  describe "with a write grant on the board" do
    setup ctx, do: grant(ctx, "write")

    test "the board is offered, and a key, an approval and a runner go through", ctx do
      assert ctx.user
             |> Machines.servable_boards(archived: :all)
             |> Enum.map(& &1.id)
             |> Enum.sort() ==
               Enum.sort([ctx.own.id, ctx.theirs.id])

      assert %{"enrolment_key" => "sde_" <> _ = key, "boards" => [served]} =
               ctx.conn
               |> post(~p"/api/machines/enrolment-keys", %{boards: [ctx.theirs.code]})
               |> json_response(201)

      assert served == ctx.theirs.id
      {:ok, {_, machine}} = Machines.enrol_with_key(key, @about)

      {device_code, enrolment} = pending()

      {:ok, view, _} =
        live(ctx.conn, ~p"/account/machines/approve?user_code=#{enrolment.user_code}")

      assert {:error, {:live_redirect, %{to: "/account/machines"}}} =
               view
               |> form("#machine-approve-form", %{"boards" => ["#{ctx.theirs.id}"]})
               |> render_submit()

      assert {:ok, {_, %Machine{board_ids: ids}}} = Machines.poll_enrolment(device_code)
      assert ids == [ctx.theirs.id]

      assert %{"runner" => %{"pool" => "build"}} =
               ctx.conn
               |> post(~p"/api/machines/#{machine.id}/runners", %{
                 board: ctx.theirs.id,
                 pool: "build",
                 config: %{directory: @dir}
               })
               |> json_response(201)
    end

    test "an archived board they can write to is still named, not offered on the form", ctx do
      ctx.theirs
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert Machines.servable_board_ids(ctx.user, [ctx.theirs.id]) == {:ok, [ctx.theirs.id]}
      assert ctx.user |> Machines.servable_boards() |> Enum.map(& &1.id) == [ctx.own.id]
    end
  end

  test "a stranger's board is refused as before", ctx do
    assert Access.board_permission(ctx.user, ctx.theirs) == :none

    assert {:error, :invalid, @refusal <> _} =
             Machines.create_enrolment_key(ctx.user, [ctx.theirs.id])
  end
end
