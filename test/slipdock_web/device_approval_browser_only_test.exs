defmodule SlipdockWeb.DeviceApprovalBrowserOnlyTest do
  @moduledoc """
  SPEC-1's exception for approving a device code (#2596): it stays in a
  signed-in browser, at `/activate`, and has no door under `/api`, in MCP or
  in the CLI. Approving a code mints a token for the approver, so a door
  would let any write token (a leaked one, an agent's) mint more tokens,
  which outlive revoking the first. `DeviceFlowTest` checks the same from
  the outside: a token-only request approves nothing.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp routes, do: SlipdockWeb.Router.__routes__()

  test "only the browser's /activate routes reach the approving controller" do
    activation = Enum.filter(routes(), &(&1.plug == SlipdockWeb.DeviceActivationController))

    assert Enum.map(activation, &{&1.verb, &1.path}) |> Enum.sort() ==
             [{:get, "/activate"}, {:post, "/activate"}]

    for route <- activation do
      verb = route.verb |> Atom.to_string() |> String.upcase()
      info = Phoenix.Router.route_info(SlipdockWeb.Router, verb, route.path, "localhost")
      assert :browser in info.pipe_through
    end
  end

  test "no /api route approves, denies or decides a device code" do
    api_device =
      for r <- routes(),
          String.starts_with?(r.path, "/api/"),
          r.path =~ ~r/device|activat/i,
          do: {r.verb, r.path, r.plug, r.plug_opts}

    # The client's own two calls: asking for a code and polling for its token.
    assert Enum.sort(api_device) == [
             {:post, "/api/auth/device", SlipdockWeb.API.DeviceController, :create},
             {:post, "/api/auth/device/token", SlipdockWeb.API.DeviceController, :token}
           ]
  end

  test "nothing but the browser controller calls the approval" do
    callers =
      ["lib/slipdock_web/**/*.ex", "cli/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.filter(&(File.read!(&1) =~ "approve_device_authorization("))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert callers == ["lib/slipdock_web/controllers/device_activation_controller.ex"]
  end
end
