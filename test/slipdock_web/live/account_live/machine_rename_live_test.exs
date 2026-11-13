defmodule SlipdockWeb.AccountLive.MachineRenameLiveTest do
  @moduledoc """
  A machine renamed by another door (#2764): a rename over the API reaches
  an open machine page (`/machines/:id`) and an open Account › Machines,
  its owner's and a board member's, without a reload. A refused rename
  changes neither, and the daemon's own reports leave the list as it is.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Machines}
  alias Slipdock.Runners.MachineRunners

  @about %{"hostname" => "build-box", "os" => "linux", "arch" => "amd64"}

  setup %{user: user} do
    board = board_fixture(%{"name" => "Served board", "code" => unique_code()}, owner: user)
    {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])
    {:ok, {_machine_key, machine}} = Machines.enrol_with_key(key, @about)
    %{board: board, machine: machine}
  end

  defp rename_over_api(ctx, name) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> api_token(ctx.user))
    |> patch(~p"/api/machines/#{ctx.machine.id}", %{name: name})
  end

  defp api_token(user) do
    {token, _} = Accounts.create_api_token(user, "rename")
    token
  end

  # Account › Machines reloads its list by a `send_update` to itself when it
  # hears the rename, a message it queues behind any already waiting. The one
  # ping `has_element?` makes can be ahead of it and see the list from before;
  # a render first is a round trip that lets the update through (#2953).
  defp settled(view) do
    _ = render(view)
    view
  end

  test "a rename over the API reaches an open machine page", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/machines/#{ctx.machine.id}")
    assert render(view) =~ "build-box"
    refute render(view) =~ "Silverbox"

    assert %{"machine" => %{"name" => "Silverbox"}} =
             ctx |> rename_over_api("Silverbox") |> json_response(200)

    # The page heard it on the machine's topic: the heading and the rename
    # form both carry the new name, and the hostname is shown beside it.
    html = render(view)
    assert html =~ "Silverbox"
    assert has_element?(view, "#machine-rename input#machine-rename-name[value=Silverbox]")
    assert has_element?(view, "#machine-rename", "hostname build-box")
  end

  test "a rename over the API reaches an open Account › Machines", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/account/machines")
    assert has_element?(view, "#machine-#{ctx.machine.id}", "build-box")

    ctx |> rename_over_api("Silverbox") |> json_response(200)

    assert has_element?(settled(view), "#machine-#{ctx.machine.id}", "Silverbox")
    refute has_element?(view, "#machine-#{ctx.machine.id}", "build-box")
  end

  test "a board member's open list of machines serving their boards follows a rename", ctx do
    member = user_fixture("member@example.com")
    {:ok, _} = Access.grant(ctx.board, member, "write", ctx.user)
    {:ok, view, _} = live(log_in_user(build_conn(), member), ~p"/account/machines")
    assert has_element?(view, "#shared-machine-#{ctx.machine.id}", "build-box")

    ctx |> rename_over_api("Silverbox") |> json_response(200)

    assert has_element?(settled(view), "#shared-machine-#{ctx.machine.id}", "Silverbox")
  end

  test "a refused rename changes nothing on the open page or the list", ctx do
    {:ok, page, _} = live(ctx.conn, ~p"/machines/#{ctx.machine.id}")
    {:ok, list, _} = live(ctx.conn, ~p"/account/machines")

    assert %{"error" => "give the machine a name"} =
             ctx |> rename_over_api("   ") |> json_response(422)

    assert has_element?(page, "#machine-rename input#machine-rename-name[value=build-box]")
    assert has_element?(settled(list), "#machine-#{ctx.machine.id}", "build-box")
  end

  test "the daemon's reports and probes on the machine's topic leave the list alone", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/account/machines")
    topic = MachineRunners.topic(ctx.machine)

    # Renamed behind the list's back (no broadcast): a report that follows
    # doesn't read the list again, so the old name stays until a change.
    Slipdock.Repo.update!(Ecto.Changeset.change(ctx.machine, name: "Quietly"))
    Phoenix.PubSub.broadcast(Slipdock.PubSub, topic, {:config_reported, ctx.machine.id})
    Phoenix.PubSub.broadcast(Slipdock.PubSub, topic, {:probe_changed, 1})

    assert has_element?(settled(view), "#machine-#{ctx.machine.id}", "build-box")
    assert Process.alive?(view.pid)
  end
end
