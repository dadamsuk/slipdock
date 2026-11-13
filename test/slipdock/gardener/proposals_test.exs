defmodule Slipdock.Gardener.ProposalsTest do
  @moduledoc """
  Handbook edits as gardener suggestions (#1788): the `edit_section` step
  applied, undone and refused when stale, and proposals filed by agents
  that only a person can apply, dismiss or undo.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Actor, Gardener, Repo, Wiki}
  alias Slipdock.Gardener.{Steps, Suggestion}
  alias Slipdock.Wiki.Page

  @body """
  # UX & UI

  How screens are built.

  ## Patterns

  Lists stream.

  ## Rules

  - **UX-1** must · judgement · Tokens only.
  """

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Proposals"}, owner: user)
    [_backlog, todo | _] = board.columns
    {:ok, page} = Wiki.create_page(board, %{"title" => "UX & UI", "body" => @body})
    %{user: user, board: board, page: page, todo: todo}
  end

  @agent Actor.runner(nil, 7, "loop")

  defp rules_edit(page, body \\ "- **UX-1** must · judgement · Design tokens only, never hex.") do
    %{"op" => "edit_section", "page" => page.code, "section" => "UX & UI/Rules", "body" => body}
  end

  defp propose(ctx, steps, extra \\ %{}) do
    Gardener.propose(
      ctx.board,
      ctx.user,
      Map.merge(%{"explanation" => "UX-1 keeps breaking", "steps" => steps}, extra)
    )
  end

  describe "the edit_section step" do
    test "applying edits the section only; undo restores the page", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])
      assert {:ok, applied} = Gardener.apply(s, ctx.user, actor: Slipdock.Actor.web(ctx.user))
      assert applied.state == "applied"

      body = Repo.get!(Page, ctx.page.id).body
      assert body =~ "## Rules\n\n- **UX-1** must · judgement · Design tokens only, never hex."
      refute body =~ "Tokens only."
      assert body =~ "## Patterns\n\nLists stream."

      assert {:ok, undone} = Gardener.undo(applied, ctx.user, actor: Slipdock.Actor.web(ctx.user))
      assert undone.state == "open"
      assert Repo.get!(Page, ctx.page.id).body == ctx.page.body
    end

    test "a section changed since the proposal is refused, and nothing is written", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])

      {:ok, _} =
        Wiki.replace_section(
          Repo.get!(Page, ctx.page.id),
          "UX & UI/Rules",
          "- **UX-1** must · judgement · Changed."
        )

      before = Repo.get!(Page, ctx.page.id).body
      assert {:error, message} = Gardener.apply(s, ctx.user, actor: Slipdock.Actor.web(ctx.user))
      assert message =~ "§UX & UI/Rules has changed since this was proposed"
      assert Repo.get!(Page, ctx.page.id).body == before
      assert Gardener.get_suggestion(s.id).state == "open"
    end

    test "an edit elsewhere on the page doesn't make it stale, but blocks undo", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])

      {:ok, _} =
        Wiki.replace_section(
          Repo.get!(Page, ctx.page.id),
          "UX & UI/Patterns",
          "Lists stream, always."
        )

      assert {:ok, applied} = Gardener.apply(s, ctx.user, actor: Slipdock.Actor.web(ctx.user))

      {:ok, _} =
        Wiki.replace_section(Repo.get!(Page, ctx.page.id), "UX & UI/Patterns", "Edited again.")

      assert {:error, message} =
               Gardener.undo(applied, ctx.user, actor: Slipdock.Actor.web(ctx.user))

      assert message =~ "has been edited since"
    end

    test "a section that is gone is refused", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])
      {:ok, _} = Wiki.update_page(Repo.get!(Page, ctx.page.id), %{"body" => "# UX & UI\n"})
      assert {:error, message} = Gardener.apply(s, ctx.user, actor: Slipdock.Actor.web(ctx.user))
      assert message =~ "has no section “UX & UI/Rules”"
    end

    test "section_hash ignores trailing blank lines only" do
      assert Steps.section_hash("## A\n\nx\n\n") == Steps.section_hash("## A\n\nx")
      refute Steps.section_hash("## A\n\nx") == Steps.section_hash("## A\n\ny")
    end
  end

  describe "two proposals on one section (#2772)" do
    @three """
    # Shipping

    ## Rules

    - **SHIP-1** must · judgement · Push to main.
    - **SHIP-2** must · judgement · Run the checks.
    - **SHIP-3** should · judgement · Say it passed.
    """

    @first "- **SHIP-1** must · judgement · Push to the card's branch.\n" <>
             "- **SHIP-2** must · judgement · Run the checks.\n" <>
             "- **SHIP-3** should · judgement · Say it passed."

    @third "- **SHIP-1** must · judgement · Push to main.\n" <>
             "- **SHIP-2** must · judgement · Run the checks.\n" <>
             "- **SHIP-3** must · judgement · Say on the card that it passed."

    defp two_proposals(ctx, first, second) do
      {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "Shipping", "body" => @three})

      edit =
        &%{
          "op" => "edit_section",
          "page" => page.code,
          "section" => "Shipping/Rules",
          "body" => &1
        }

      {:ok, a, :new} = propose(ctx, [edit.(first)], %{"explanation" => "First"})
      {:ok, b, :new} = propose(ctx, [edit.(second)], %{"explanation" => "Second"})
      {page, a, b}
    end

    defp web_apply(s, ctx), do: Gardener.apply(s, ctx.user, actor: Actor.web(ctx.user))

    test "two that edit different rules both apply, in either order", ctx do
      for order <- [:first_then_third, :third_then_first] do
        {page, a, b} = two_proposals(ctx, @first, @third)
        {one, two} = if order == :first_then_third, do: {a, b}, else: {b, a}

        assert {:ok, %{state: "applied"}} = web_apply(one, ctx)
        assert {:ok, %{state: "applied"}} = web_apply(two, ctx), "#{order}"

        body = Repo.get!(Page, page.id).body
        assert body =~ "- **SHIP-1** must · judgement · Push to the card's branch.\n"
        assert body =~ "- **SHIP-2** must · judgement · Run the checks.\n"
        assert body =~ "- **SHIP-3** must · judgement · Say on the card that it passed."
        refute body =~ "Push to main."
        refute body =~ "Say it passed."
        assert body =~ "# Shipping\n\n## Rules\n\n- **SHIP-1**"
      end
    end

    test "undoing the merged one puts back what the first left", ctx do
      {page, a, b} = two_proposals(ctx, @first, @third)
      {:ok, _} = web_apply(a, ctx)
      after_first = Repo.get!(Page, page.id).body
      {:ok, applied} = web_apply(b, ctx)

      assert {:ok, %{state: "open"}} =
               Gardener.undo(applied, ctx.user, actor: Actor.web(ctx.user))

      assert Repo.get!(Page, page.id).body == after_first
    end

    test "two that change the same rule: the second is refused, naming it", ctx do
      other = String.replace(@first, "Push to the card's branch.", "Push by pull request.")
      {page, a, b} = two_proposals(ctx, @first, other)
      {:ok, _} = web_apply(a, ctx)
      before = Repo.get!(Page, page.id).body

      assert {:error, message} = web_apply(b, ctx)

      assert message =~
               "§Shipping/Rules has changed since this was proposed, in lines it changes too"

      assert message =~ "SHIP-1"
      assert Repo.get!(Page, page.id).body == before
      assert Gardener.get_suggestion(b.id).state == "open"
    end

    test "two that each add a rule at the end keep both, the one applied first first", ctx do
      add =
        &(String.trim_trailing(@three |> String.split("## Rules\n\n") |> List.last()) <>
            "\n" <> &1)

      {page, a, b} =
        two_proposals(
          ctx,
          add.("- **SHIP-4** should · judgement · A."),
          add.("- **SHIP-5** should · judgement · B.")
        )

      {:ok, _} = web_apply(b, ctx)
      {:ok, _} = web_apply(a, ctx)

      assert Repo.get!(Page, page.id).body =~
               "Say it passed.\n- **SHIP-5** should · judgement · B.\n- **SHIP-4** should · judgement · A."
    end

    test "a proposal filed before base_text was kept merges against the page's history", ctx do
      {page, a, b} = two_proposals(ctx, @first, @third)
      old = Enum.map(b.proposal, &Map.delete(&1, "base_text"))
      b = b |> Ecto.Changeset.change(proposal: old) |> Repo.update!()

      {:ok, _} = web_apply(a, ctx)
      assert {:ok, %{state: "applied"}} = web_apply(b, ctx)
      assert Repo.get!(Page, page.id).body =~ "Push to the card's branch."
      assert Repo.get!(Page, page.id).body =~ "Say on the card that it passed."
    end

    test "with no base to be found, a stale one is refused as before", ctx do
      {_page, a, b} = two_proposals(ctx, @first, @third)

      old =
        Enum.map(
          b.proposal,
          &(&1 |> Map.delete("base_text") |> Map.put("base", "0000000000000000"))
        )

      b = b |> Ecto.Changeset.change(proposal: old) |> Repo.update!()
      {:ok, _} = web_apply(a, ctx)

      assert {:error, message} = web_apply(b, ctx)
      assert message =~ "has changed since this was proposed: read it again"
    end

    test "propose keeps the section it saw as base_text", ctx do
      {_page, a, _b} = two_proposals(ctx, @first, @third)
      assert [%{"base_text" => text, "base" => base}] = a.proposal
      assert text =~ "## Rules\n\n- **SHIP-1** must · judgement · Push to main."
      assert Steps.section_hash(text) == base
    end

    test "shared_sections/1 names the open proposals that share a section", ctx do
      {page, a, b} = two_proposals(ctx, @first, @third)
      {:ok, c, :new} = propose(ctx, [rules_edit(ctx.page)])

      shared = Gardener.shared_sections([a, b, c])
      assert shared[a.id] == [%{page: page.id, section: "Shipping/Rules", with: [b.id]}]
      assert shared[b.id] == [%{page: page.id, section: "Shipping/Rules", with: [a.id]}]
      refute Map.has_key?(shared, c.id)
      assert Gardener.shared_sections([a, c]) == %{}
    end

    test "one proposal with two steps on a section shares it with nobody", ctx do
      {_page, a, _b} = two_proposals(ctx, @first, @third)
      twice = %{a | proposal: a.proposal ++ a.proposal}
      assert Gardener.shared_sections([twice]) == %{}
    end
  end

  describe "propose/4" do
    test "files an open proposal, its base filled in and its evidence kept", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Evidence"})

      assert {:ok, s, :new} =
               propose(ctx, [rules_edit(ctx.page)], %{
                 "findings" => [3, "#5"],
                 "cards" => [card.id]
               })

      assert s.check == "proposal"
      assert s.state == "open"
      assert [%{"op" => "edit_section", "page" => page_id, "base" => base}] = s.proposal
      assert page_id == ctx.page.id
      {:ok, rules} = Wiki.Section.read(ctx.page.body, "UX & UI/Rules")
      assert base == Steps.section_hash(rules)
      assert s.subject == %{"cards" => [card.id], "pages" => [ctx.page.id], "findings" => [3, 5]}
      assert Gardener.person_only?(s)
      assert [%Suggestion{id: id}] = Gardener.list_open(ctx.board, check: "proposal")
      assert id == s.id
    end

    test "the same proposal again is the one filed; a dismissed one stays dismissed", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])
      assert {:ok, %{id: id}, :exists} = propose(ctx, [rules_edit(ctx.page)])
      assert id == s.id

      {:ok, _} = Gardener.dismiss(s, ctx.user, actor: Slipdock.Actor.web(ctx.user))
      assert {:ok, %{id: ^id, state: "dismissed"}, :exists} = propose(ctx, [rules_edit(ctx.page)])

      # A different edit is a new proposal.
      assert {:ok, other, :new} =
               propose(ctx, [rules_edit(ctx.page, "- **UX-1** should · judgement · Tokens.")])

      refute other.id == id
    end

    test "a run doesn't expire a proposal", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])
      {:ok, _} = Gardener.run(ctx.board)
      assert Gardener.get_suggestion(s.id).state == "open"
    end

    test "steps outside the allowed list, or malformed, are refused", ctx do
      card = card_fixture(ctx.todo, %{"title" => "X"})

      assert {:error, message} = propose(ctx, [%{"op" => "archive", "card" => card.id}])
      assert message =~ "steps[1]: a proposal can't take a “archive” step"
      assert message =~ "edit_section, comment, file_page"

      assert {:error, "steps[2]: edit_section needs a page, a section" <> _} =
               propose(ctx, [
                 rules_edit(ctx.page),
                 %{"op" => "edit_section", "page" => ctx.page.code}
               ])

      assert {:error, "steps is required" <> _} = propose(ctx, [])

      assert {:error, "steps[1]: no page \"W-999999\""} =
               propose(ctx, [%{rules_edit(ctx.page) | "page" => "W-999999"}])

      assert {:error, "steps[1]: comment needs a card" <> _} =
               propose(ctx, [%{"op" => "comment", "body" => "x"}])

      assert {:error, "steps[1]: file_page needs a folder" <> _} =
               propose(ctx, [%{"op" => "file_page", "page" => ctx.page.id}])

      assert {:error, "steps[1]: a step is an object" <> _} = propose(ctx, ["edit"])

      assert {:error, "explanation is required" <> _} =
               Gardener.propose(ctx.board, ctx.user, %{"steps" => [rules_edit(ctx.page)]})

      assert {:error, "findings are ids" <> _} =
               propose(ctx, [rules_edit(ctx.page)], %{"findings" => ["x"]})

      assert Gardener.list_open(ctx.board) == []
    end

    test "a stale base is refused at filing; a current one is kept", ctx do
      assert {:error, message} = propose(ctx, [Map.put(rules_edit(ctx.page), "base", "0000")])
      assert message =~ "has changed since that base"

      {:ok, rules} = Wiki.Section.read(ctx.page.body, "UX & UI/Rules")
      base = Steps.section_hash(rules)

      assert {:ok, %{proposal: [%{"base" => ^base}]}, :new} =
               propose(ctx, [Map.put(rules_edit(ctx.page), "base", base)])
    end

    test "comment and file_page steps apply as they always do", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Rule keeps breaking"})

      {:ok, s, :new} =
        propose(ctx, [%{"op" => "comment", "card" => card.id, "body" => "See the proposal."}])

      assert {:ok, _} = Gardener.apply(s, ctx.user, actor: Slipdock.Actor.web(ctx.user))
      assert [%{body: "See the proposal."}] = Repo.preload(card, :comments).comments
    end

    test "a stranger can't file one", ctx do
      stranger = user_fixture("proposal-stranger@example.com")

      assert {:error, :forbidden} =
               Gardener.propose(ctx.board, stranger, %{
                 "explanation" => "x",
                 "steps" => [rules_edit(ctx.page)]
               })
    end
  end

  describe "only a person decides" do
    test "an agent can't apply, dismiss or undo a proposal; a person can", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])

      assert {:error, message} = Gardener.apply(s, ctx.user, actor: @agent)
      assert message =~ "only a person can apply a proposed handbook edit"
      assert {:error, _} = Gardener.dismiss(s, ctx.user, actor: @agent)
      assert Gardener.get_suggestion(s.id).state == "open"
      assert Repo.get!(Page, ctx.page.id).body == ctx.page.body

      assert {:ok, applied} = Gardener.apply(s, ctx.user, actor: Actor.web(ctx.user))
      assert {:error, _} = Gardener.undo(applied, ctx.user, actor: @agent)
      assert {:ok, _} = Gardener.undo(applied, ctx.user, actor: Actor.web(ctx.user))
    end

    # #2668: only the Tidy-up page's actor settles one. Every other door,
    # a person's own CLI and the in-app assistant included, and a caller
    # that names no actor, is refused with the page's link.
    test "only the web actor decides one: no actor, the assistant, a CLI and MCP are refused",
         ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])

      cli_person = %{Actor.web(ctx.user) | via: "cli"}
      mcp = Actor.mcp(%{user: ctx.user})

      for actor <- [nil, Actor.assistant(ctx.user), cli_person, mcp, Actor.unknown()] do
        assert {:error, message} = Gardener.apply(s, ctx.user, actor: actor)
        assert message =~ "Tidy-up page: " <> Gardener.tidy_url(s)
        assert {:error, _} = Gardener.dismiss(s, ctx.user, actor: actor)
      end

      assert {:error, _} = Gardener.apply(s, ctx.user)
      assert Gardener.get_suggestion(s.id).state == "open"

      assert {:ok, applied} = Gardener.apply(s, ctx.user, actor: Actor.web(ctx.user))
      assert {:error, _} = Gardener.undo(applied, ctx.user, actor: cli_person)
      assert {:error, _} = Gardener.undo(applied, ctx.user)
      assert Gardener.get_suggestion(s.id).state == "applied"
    end

    test "in_person?/1 is the web actor's alone", ctx do
      assert Gardener.in_person?(Actor.web(ctx.user))
      refute Gardener.in_person?(%{Actor.web(ctx.user) | via: "api"})
      refute Gardener.in_person?(%{Actor.web(ctx.user) | kind: "agent"})
      refute Gardener.in_person?(Actor.assistant(ctx.user))
      refute Gardener.in_person?(nil)
    end

    test "tidy_url/1 is the board's Tidy-up page", ctx do
      {:ok, s, :new} = propose(ctx, [rules_edit(ctx.page)])
      assert Gardener.tidy_url(s) =~ ~r{^https?://[^/]+/boards/#{s.board_id}/tidy$}
    end

    test "an ordinary suggestion is still an agent's to decide", ctx do
      [_backlog, _todo, doing, _done] = ctx.board.columns
      card_fixture(doing, %{"title" => "Stray", "completed" => true})
      {:ok, _} = Gardener.run(ctx.board, only: ["completed_not_done"])
      [s] = Gardener.list_open(ctx.board)
      refute Gardener.person_only?(s)
      assert {:ok, _} = Gardener.apply(s, ctx.user, actor: @agent)
    end

    test "a check's suggestion with an edit_section step is a person's too" do
      s = %Suggestion{
        check: "long_section",
        proposal: [%{"op" => "comment"}],
        alternatives: %{"split" => [%{"op" => "edit_section"}]}
      }

      assert Gardener.person_only?(s)
      refute Gardener.person_only?(%{s | alternatives: %{}})
    end
  end
end
