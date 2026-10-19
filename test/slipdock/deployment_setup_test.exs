defmodule Slipdock.DeploymentSetupTest do
  @moduledoc """
  "Track deployments" (#1134, `Slipdock.Deployments.Setup`): what the
  generator writes for each CI — the token once, the pattern applied — what
  it refuses, what `connect/3` changes, and the paste-into-Claude prompt.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Deployments}
  alias Slipdock.Deployments.Setup

  @base "https://slipdock.example.com"

  setup do
    user = user_fixture()
    %{user: user, board: board_fixture(%{"name" => "Wire"}, owner: user)}
  end

  defp gen(board, answers, token \\ "sdd_SECRET123") do
    {:ok, a} = Setup.normalise(answers)
    Setup.generate(a, %{board: board, base_url: @base, token: token})
  end

  defp count(text, sub), do: length(String.split(text, sub)) - 1

  for ci <- ~w(github gitlab shell) do
    test "#{ci}: the token once, the wrapped step, the example", %{board: board} do
      g = gen(board, %{"ci" => unquote(ci)})
      assert count(g.text, "sdd_SECRET123") == 1
      refute g.prompt =~ "sdd_SECRET123"
      assert g.text =~ "slipdock deploy run --env production"
      assert g.text =~ "SLIPDOCK_URL to #{@base}"
      assert g.text =~ "--dry-run"
      assert g.snippet =~ "slipdock deploy run"
      assert hd(g.example_urls) =~ "#{@base}/deploy/examples/"
      assert Enum.all?(g.example_urls, &(Path.basename(&1) in Setup.example_files()))
    end
  end

  test "each CI says where history and the secret come from", %{board: board} do
    assert gen(board, %{"ci" => "github"}).text =~ "fetch-depth: 0"
    assert gen(board, %{"ci" => "github"}).text =~ "secrets.SLIPDOCK_DEPLOY_TOKEN"
    assert gen(board, %{"ci" => "gitlab"}).text =~ ~s(GIT_DEPTH: "0")
    assert gen(board, %{"ci" => "shell"}).text =~ "full clone"
  end

  test "no token writes the placeholder", %{board: board} do
    g = gen(board, %{}, nil)
    assert g.text =~ Setup.token_placeholder()
  end

  test "environments and the card pattern are applied", %{board: board} do
    g =
      gen(board, %{"environments" => "staging, production", "card_ref_pattern" => "PROJ-(\\d+)"})

    assert g.text =~ "--env staging"
    assert g.text =~ "Deploys to production are the same step with --env production"
    assert g.prompt =~ "Environments deployed to: staging, production"
    assert g.prompt =~ "the regex PROJ-(\\d+)"
  end

  test "normalise refuses what it can't use" do
    assert {:error, "ci must be one of" <> _} = Setup.normalise(%{"ci" => "jenkins"})
    assert {:error, "name at least one" <> _} = Setup.normalise(%{"environments" => " , "})

    assert {:error, "environments are" <> _} =
             Setup.normalise(%{"environments" => "pro duction!"})

    assert {:error, "card_ref_pattern" <> _} =
             Setup.normalise(%{"card_ref_pattern" => "no group"})

    assert {:ok, %{"ci" => "github", "environments" => ["production"]}} = Setup.normalise(nil)
  end

  test "connect turns delivery metrics on, sets the pattern and issues a token", %{board: board} do
    refute board.delivery_metrics

    assert {:ok, board, g} =
             Setup.connect(board, %{"ci" => "gitlab", "card_ref_pattern" => "J-(\\d+)"}, @base)

    assert board.delivery_metrics
    assert board.card_ref_pattern == "J-(\\d+)"
    [token] = Regex.run(~r/sdd_[A-Za-z0-9_-]+/, g.text)
    assert Deployments.authenticate(token).id == board.id

    # Again: a new token, the old one stops working.
    {:ok, _board, g2} = Setup.connect(Boards.get_board!(board.id), %{}, @base)
    [token2] = Regex.run(~r/sdd_[A-Za-z0-9_-]+/, g2.text)
    assert token2 != token
    assert Deployments.authenticate(token) == nil
  end

  test "connect with bad answers changes nothing", %{board: board} do
    assert {:error, _} = Setup.connect(board, %{"ci" => "nope"}, @base)
    refute Boards.get_board!(board.id).delivery_metrics
  end

  test "the prompt states the contract and points at every example", %{board: board} do
    {:ok, a} = Setup.normalise(%{})
    prompt = Setup.prompt(a, %{board: board, base_url: @base})

    for file <- Setup.example_files(), do: assert(prompt =~ "#{@base}/deploy/examples/#{file}")
    assert prompt =~ "slipdock deploy run --env <environment>"
    assert prompt =~ "fetch-depth: 0"
    assert prompt =~ "SLIPDOCK_DEPLOY_TOKEN"
    assert prompt =~ "--dry-run"
    assert prompt =~ "slipdock deploy token #{board.code}"
  end

  test "the guide's Deployments section carries the same prompt" do
    {:ok, a} = Setup.normalise(%{})
    {:ok, section} = SlipdockWeb.APIGuide.section("deployments", base_url: @base)
    assert section =~ "## Deployments"
    assert section =~ String.slice(Setup.prompt(a, %{base_url: @base}), 0, 80)
  end
end
