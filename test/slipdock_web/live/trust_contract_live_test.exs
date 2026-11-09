defmodule SlipdockWeb.TrustContractLiveTest do
  @moduledoc """
  The trust contract (#2581) shown where people look before trusting a
  machine to the board: Help › Agents › Runners (signed out too) and each
  machine's page, for its owner and for a member of a board it serves. Both
  render the one text, `Slipdock.Machines.TrustContract.markdown/0`, through
  `SlipdockWeb.TrustContract`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Machines}
  alias Slipdock.Machines.TrustContract

  defp headings,
    do: for([_, h] <- Regex.scan(~r/^#### (.+)$/m, TrustContract.markdown()), do: h)

  defp bullets, do: length(Regex.scan(~r/^- /m, TrustContract.markdown()))

  # The section renders the contract: every heading as a heading, every
  # bullet as a list item, the executors' names as code, and the promises in
  # their words.
  defp assert_renders_contract(view, section) do
    for heading <- headings(), do: assert(has_element?(view, "#{section} h4", heading))

    html = view |> element(section) |> render()
    assert length(Regex.scan(~r/<li>/, html)) == bullets()

    for executor <- Slipdock.Runners.Config.executors(),
        do: assert(has_element?(view, "#{section} li code", executor))

    text = html |> Floki.parse_fragment!() |> Floki.text() |> String.split() |> Enum.join(" ")

    for words <- [
          "Run a command on this machine.",
          "First-install trust.",
          "the operator who runs the server is also the one who signs the releases",
          "Prompts are the board members' instructions."
        ],
        do: assert(text =~ words)

    refute html =~ "####"
    # The text is wrapped for a terminal: its newlines are not line breaks.
    refute html =~ "<br"
  end

  describe "Help › Agents › Runners" do
    @tag :anonymous
    test "shows the contract to someone deciding whether to install", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents/runners")
      assert has_element?(view, "#help-trust-contract h2", "What the server can and cannot do")
      assert has_element?(view, "#help-trust-contract code", "slipdock-runner show")
      assert_renders_contract(view, "#help-trust-contract")
    end

    @tag :anonymous
    test "the other ways in don't carry it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents/mcp")
      refute has_element?(view, "#help-trust-contract")
    end
  end

  describe "a machine's page" do
    setup %{user: user} do
      board = board_fixture(%{"name" => "Served", "code" => unique_code()}, owner: user)
      {:ok, key, _} = Machines.create_enrolment_key(user, [board.id])

      {:ok, {_key, machine}} =
        Machines.enrol_with_key(key, %{"hostname" => "box", "os" => "linux", "arch" => "amd64"})

      %{board: board, machine: machine}
    end

    test "shows its owner the contract, before its ceiling is reported", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/machines/#{ctx.machine.id}")
      assert has_element?(view, "#machine-ceiling-none")
      assert has_element?(view, "#machine-trust-contract h2", "What the server can and cannot do")
      assert_renders_contract(view, "#machine-trust-contract")
    end

    test "shows it to a member of a board it serves", ctx do
      member = user_fixture("contract-member@example.com")
      {:ok, _} = Access.grant(ctx.board, member, "read", ctx.user)

      {:ok, view, _html} = live(conn_as(member), ~p"/machines/#{ctx.machine.id}")
      assert has_element?(view, "#machine-owner")
      assert_renders_contract(view, "#machine-trust-contract")
    end
  end
end
