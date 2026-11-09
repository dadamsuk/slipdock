defmodule Slipdock.RunnersSecurityShipTest do
  @moduledoc """
  Security fixes don't announce themselves (#1794, W-2310 §Sweeps and static
  checks): on a board that ships by pull request, a card tagged `security`
  is told, in its claimed job's prompt and in its JSON, to open a neutral
  pull request — a neutral title instead of the card's, a body that is only
  the card id, and commits that don't describe the hole. Other cards are
  told what they always were.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Repo, Runners, Verified}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Public", "code" => unique_code()}, owner: user)
    [_backlog, todo | _] = board.columns

    {:ok, board} =
      Boards.update_board(board, %{"verify_work" => true, "ship_via" => "pull_request"})

    hole = card_fixture(todo, %{"title" => "Board events skip the write check on /api/x"})
    plain = card_fixture(todo, %{"title" => "Rename the menu"})
    {:ok, _} = Boards.set_card_tags(hole, [tag_fixture(board, "Security", "red")])

    {token, _} = Accounts.create_api_token(user, "bot")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    %{board: board, hole: Repo.get!(Card, hole.id), plain: plain, api: conn}
  end

  defp prompt(card) do
    {:ok, job} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "Do it."})
    Runners.claimed_prompt(job)
  end

  test "a security card's prompt gives a neutral title and body, never the card's", ctx do
    id = ctx.hole.id
    text = prompt(ctx.hole)

    assert text =~
             ~s|`gh pr create --head card-#{id} --title "Maintenance (##{id})" --body "Card ##{id}."`|

    assert text =~ "(a neutral title, not the card's)"
    refute text =~ "--fill"
    refute text =~ "Board events skip"
    refute text =~ "/api/x"

    assert text =~ "Describe the change neutrally everywhere they show (commit messages"
    assert text =~ "never the hole, how to exploit it or a list of the affected endpoints"
    assert text =~ "The detail stays on this card until the fix is deployed"
    assert text =~ "the closing comment may link to it"
    # The rest of the instructions are as for any card.
    assert text =~ "never push the default branch"
    assert text =~ "slipdock done #{id} --pr <url>"
  end

  test "another card's prompt is unchanged: its own title, --fill, no neutral note", ctx do
    id = ctx.plain.id
    text = prompt(ctx.plain)

    assert text =~ ~s|`gh pr create --head card-#{id} --title "Rename the menu (##{id})" --fill`|
    refute text =~ "Maintenance"
    refute text =~ "neutrally"
    refute Verified.neutral?(ctx.plain)
  end

  test "the tag is matched whatever its case, and a push board has no instructions", ctx do
    assert Verified.neutral?(ctx.hole)
    assert Verified.neutral_pr_title(ctx.hole) == "Maintenance (##{ctx.hole.id})"

    {:ok, _} = Boards.update_board(ctx.board, %{"ship_via" => "push"})
    assert Verified.ship_instructions(Repo.get!(Card, ctx.hole.id)) == nil
  end

  test "the card's JSON says the PR is neutral, and the same instructions", ctx do
    json = ctx.api |> get(~p"/api/cards/#{ctx.hole.id}") |> json_response(200)
    assert %{"neutral" => true, "instructions" => text} = json["card"]["shipping"]
    assert text =~ "Maintenance (##{ctx.hole.id})"
    refute text =~ "Board events skip"

    json = ctx.api |> get(~p"/api/cards/#{ctx.plain.id}") |> json_response(200)
    assert %{"neutral" => false, "instructions" => text} = json["card"]["shipping"]
    assert text =~ "--fill"
  end

  test "untagging a card makes its next prompt ordinary again", ctx do
    {:ok, _} = Boards.set_card_tags(ctx.hole, [])
    text = prompt(Repo.get!(Card, ctx.hole.id))
    assert text =~ "--fill"
    refute text =~ "neutrally"
  end

  test "the guide, the manual, agents.md and the loop skill say so", %{user: user} do
    # The guide says it to a reader with a board that ships by pull request.
    assert SlipdockWeb.APIGuide.markdown(user: user) =~
             "**A card tagged `security`** gets a neutral pull request"

    assert Slipdock.DocsText.read!("docs/manual.md") =~
             "**Security fixes don't announce themselves.**"

    assert Slipdock.DocsText.read!("docs/agents.md") =~
             "A card tagged `security` ships a neutral pull request"

    assert Slipdock.DocsText.read!("priv/skills/slipdock-loop/SKILL.md") =~
             "**A card tagged `security`** ships a neutral pull request"
  end
end
