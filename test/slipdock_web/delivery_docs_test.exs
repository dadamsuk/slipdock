defmodule SlipdockWeb.DeliveryDocsTest do
  @moduledoc """
  Delivery metrics (#1134) as the docs and skills describe them: README,
  the manual, docs/agents.md, /help/agents, both skills that use them, and
  the guide — whose Deployments section is the setup wizard's own prompt,
  with the short guide still under its cap.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  test "README names the feature and its doors" do
    readme = read("README.md")
    assert readme =~ "**Delivery metrics (DORA)**"
    assert readme =~ "slipdock deploy run --env production -- ./deploy.sh"
    assert readme =~ "slipdock dora <board>"
    assert readme =~ "`get_board` with `dora: true`"
    assert readme =~ "(docs/manual.md#delivery-metrics-deploys-and-dora)"
  end

  test "the manual has the section README links to" do
    manual = read("docs/manual.md")
    assert manual =~ "\n## Delivery metrics: deploys and DORA\n"
    assert manual =~ "[Delivery metrics](#delivery-metrics-deploys-and-dora)"

    for phrase <- [
          "**Track deployments**",
          "SLIPDOCK_DEPLOY_TOKEN",
          "fetch-depth: 0",
          "slipdock deploy backfill --from-tags",
          "slipdock incident-of <card> <deploy>",
          "**idea to production**",
          "Shipped to production",
          "/deploy/examples/"
        ],
        do: assert(manual =~ phrase, phrase)
  end

  test "docs/agents.md and both skills tell an agent what it may do" do
    agents = read("docs/agents.md")
    assert agents =~ "`get_board` with `dora: true`"
    assert agents =~ ~s(`section: "deployments"`)

    skill = read("priv/skills/slipdock/SKILL.md")
    assert skill =~ "slipdock dora <board>"
    assert skill =~ "slipdock deploy run --env E -- <cmd…>"
    assert skill =~ "slipdock incident-of <card> <deploy-id>"

    work = read("priv/skills/slipdock-work/SKILL.md")
    assert work =~ "**Incidents and deploys.**"
    assert work =~ "Never record or\n  finish deploys by hand"
  end

  test "/help/agents has the row", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents")
    assert html =~ "Record deploys, and read the delivery (DORA) numbers"
    assert html =~ "slipdock deploy run, slipdock dora"
  end

  test "the guide's Deployments section, and the short guide under its cap" do
    full = SlipdockWeb.APIGuide.markdown()
    assert full =~ "\n## Deployments\n"
    assert full =~ "`POST /api/boards/:board/deployments/setup"

    {:ok, a} = Slipdock.Deployments.Setup.normalise(%{})

    assert full =~
             String.slice(
               Slipdock.Deployments.Setup.prompt(a, %{base_url: "http://localhost:4000"}),
               0,
               60
             )

    short = SlipdockWeb.APIGuide.short(user: user_fixture())
    assert short =~ "- `deployments` — Deployments"
    assert byte_size(short) < 22_000
  end
end
