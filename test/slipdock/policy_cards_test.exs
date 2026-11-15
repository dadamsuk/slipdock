defmodule Slipdock.PolicyCardsTest do
  @moduledoc """
  Policy 2 (#3169): the writes of a card and what hangs from one ask
  `Slipdock.Policy` themselves. For every action in the table's card rows,
  the context is called with no door in the way, the actor set as a door
  sets it: the level the action needs passes; a person one level short, a
  read-only token on the owner, and a level lowered after the actor was set
  are each refused, and say which of the two was short (ARCH-8).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Actor, Boards, Fields, Policy, Recurrence, Snooze, Votes}
  alias Slipdock.Policy.Refused

  # {action, the level it needs}: what the table says, held here too so a
  # change to either is a change to both.
  @actions [
    create_card: :write,
    update_card: :write,
    archive_card: :write,
    delete_card: :write,
    move_card: :write,
    move_card_in: :write,
    time_card: :write,
    add_comment: :comment,
    delete_comment: :write,
    delete_own_comment: :comment,
    edit_checklist: :write,
    tick_checklist: :write,
    attach_file: :write,
    remove_file: :write,
    hide_file: :write,
    edit_card_urls: :write,
    edit_dependency: :write,
    link_to_card: :read,
    edit_link: :write,
    leave_handoff: :comment,
    delete_handoff: :write,
    delete_own_handoff: :comment,
    edit_milestone: :write,
    add_status_update: :comment,
    delete_status_update: :write,
    open_wait: :write,
    answer_wait: :write,
    answer_own_wait: :comment,
    withdraw_wait: :write,
    withdraw_own_wait: :read,
    edit_field: :write,
    set_field_value: :write,
    edit_recurrence: :write,
    snooze_card: :write,
    vote: :read
  ]

  setup do
    owner = user_fixture("cards.policy.owner@example.com")
    root = board_fixture(%{"name" => "Policy cards"}, owner: owner)
    [col, col2 | _] = root.columns
    # Somebody else's comment, handoff or wait: never the actor's own.
    other = user_fixture("cards.policy.other@example.com")
    {:ok, _} = Access.grant(root, other, "write", owner)
    %{owner: owner, other: other, root: root, col: col, col2: col2}
  end

  # As a door sets it: the actor, and the user and token beside it.
  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})
  defp fixture(fun), do: Policy.as_system("a test fixture", fun)
  defp card(ctx, title \\ "Card"), do: card_fixture(ctx.col, %{"title" => title})

  defp person(ctx, nil),
    do:
      user_fixture("cards.policy.#{System.unique_integer([:positive])}@example.com")
      |> tap(fn _ -> ctx end)

  defp person(ctx, level) do
    user = person(ctx, nil)
    {:ok, grant} = Access.grant(ctx.root, user, level, ctx.owner)
    {user, grant}
  end

  defp grant_for(:read), do: "read"
  defp grant_for(:comment), do: "comment"
  defp grant_for(:write), do: "write"

  defp short_of(:read), do: nil
  defp short_of(:comment), do: "read"
  defp short_of(:write), do: "comment"

  # The write `action` stands for, by `user`, on a subject made for it.
  defp act(:create_card, ctx, _user), do: Boards.Cards.create_card(ctx.col, %{"title" => "New"})

  defp act(:update_card, ctx, _user),
    do: Boards.Cards.update_card(card(ctx), %{"title" => "Changed"})

  defp act(:archive_card, ctx, _user), do: Boards.Cards.archive_card(card(ctx))
  defp act(:delete_card, ctx, _user), do: Boards.Cards.delete_card(card(ctx))
  defp act(:move_card, ctx, _user), do: Boards.Cards.move_card(card(ctx).id, ctx.col2.id)

  defp act(:move_card_in, ctx, user) do
    # From the person's own board, so only the end it goes to is in doubt.
    own = board_fixture(%{"name" => "Own #{user.id}"}, owner: user)
    mine = card_fixture(hd(own.columns), %{"title" => "Mine"})
    Boards.Moves.move_card_to_board(mine, ctx.col)
  end

  defp act(:time_card, ctx, _user), do: Boards.Cards.start_timer(card(ctx))
  defp act(:add_comment, ctx, user), do: Boards.Comments.add_comment(card(ctx), "Hi", by: user)

  defp act(:delete_comment, ctx, _user) do
    {:ok, c} = fixture(fn -> Boards.Comments.add_comment(card(ctx), "Theirs", by: ctx.other) end)
    Boards.Comments.delete_comment(c)
  end

  defp act(:delete_own_comment, ctx, user) do
    {:ok, c} = fixture(fn -> Boards.Comments.add_comment(card(ctx), "Mine", by: user) end)
    Boards.Comments.delete_comment(c)
  end

  defp act(:edit_checklist, ctx, _user),
    do: Boards.Checklists.add_checklist_item(card(ctx), "Step")

  defp act(:tick_checklist, ctx, _user) do
    {:ok, item} = fixture(fn -> Boards.Checklists.add_checklist_item(card(ctx), "Step") end)
    Boards.Checklists.toggle_checklist_item(item)
  end

  defp act(:attach_file, ctx, _user), do: attach(card(ctx))

  defp act(:remove_file, ctx, _user) do
    {:ok, a} = fixture(fn -> attach(card(ctx)) end)
    Boards.Attachments.delete_attachment(a)
  end

  defp act(:hide_file, ctx, _user) do
    {:ok, a} = fixture(fn -> attach(card(ctx)) end)
    Boards.Attachments.hide_attachment_on_card(a, true)
  end

  defp act(:edit_card_urls, ctx, _user),
    do: Boards.CardUrls.add_card_url(card(ctx), %{"url" => "https://example.com/doc"})

  defp act(:edit_dependency, ctx, _user),
    do: Boards.Dependencies.add_dependency(card(ctx, "Blocked"), card(ctx, "Blocker"))

  defp act(:link_to_card, ctx, user) do
    # From the person's own card, so only the card pointed at is in doubt.
    own = board_fixture(%{"name" => "Own #{user.id}"}, owner: user)
    mine = card_fixture(hd(own.columns), %{"title" => "Mine"})
    Boards.Links.add_link(mine, card(ctx), "relates")
  end

  defp act(:edit_link, ctx, _user),
    do: Boards.Links.add_link(card(ctx, "A"), card(ctx, "B"), "relates")

  defp act(:leave_handoff, ctx, user),
    do: Boards.Handoffs.leave_handoff(card(ctx), user, %{next_step: "Next", via: "ui"})

  defp act(:delete_handoff, ctx, _user), do: delete_handoff_by(ctx, ctx.other)
  defp act(:delete_own_handoff, ctx, user), do: delete_handoff_by(ctx, user)

  defp act(:edit_milestone, ctx, _user),
    do: Boards.Milestones.create_milestone(ctx.root, %{"name" => "M", "date" => "2030-01-01"})

  defp act(:add_status_update, ctx, user),
    do: Boards.StatusUpdates.add_status_update(card(ctx), user, %{"health" => "on_track"})

  defp act(:delete_status_update, ctx, _user) do
    {:ok, u} =
      fixture(fn ->
        Boards.StatusUpdates.add_status_update(card(ctx), ctx.owner, %{"health" => "on_track"})
      end)

    Boards.StatusUpdates.delete_status_update(u.id)
  end

  defp act(:open_wait, ctx, user),
    do: Boards.Waits.open_wait(card(ctx), Actor.web(user), %{"needs" => "Which?"})

  defp act(:answer_wait, ctx, user) do
    c = wait_on(ctx, %{"needs" => "Which?"}, ctx.other)
    Boards.Waits.answer_wait(c, Actor.web(user), %{"answer" => "That one"})
  end

  defp act(:answer_own_wait, ctx, user) do
    c = wait_on(ctx, %{"needs" => "Which?", "on_user_id" => user.id}, ctx.other)
    Boards.Waits.answer_wait(c, Actor.web(user), %{"answer" => "That one"})
  end

  defp act(:withdraw_wait, ctx, user) do
    c = wait_on(ctx, %{"needs" => "Which?"}, ctx.other)
    Boards.Waits.withdraw_wait(c, Actor.web(user))
  end

  defp act(:withdraw_own_wait, ctx, user) do
    c = wait_on(ctx, %{"needs" => "Which?"}, user)
    Boards.Waits.withdraw_wait(c, Actor.web(user))
  end

  defp act(:edit_field, ctx, _user),
    do: Fields.create_field(ctx.root, %{"name" => "Effort", "kind" => "number"})

  defp act(:set_field_value, ctx, _user) do
    {:ok, field} =
      fixture(fn -> Fields.create_field(ctx.root, %{"name" => "Effort", "kind" => "number"}) end)

    Fields.set_value(card(ctx), field, "3")
  end

  defp act(:edit_recurrence, ctx, user),
    do: Recurrence.set(card(ctx), %{"rule" => "every day"}, user)

  defp act(:snooze_card, ctx, user),
    do: Snooze.snooze(card(ctx), user, DateTime.add(DateTime.utc_now(), 2, :day))

  defp act(:vote, ctx, user), do: Votes.set(card(ctx), user, 1)

  defp attach(card) do
    path = Path.join(System.tmp_dir!(), "policy-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "notes")

    Boards.Attachments.add_attachment(
      card,
      %{filename: "notes.txt", content_type: "text/plain"},
      path
    )
  end

  defp delete_handoff_by(ctx, author) do
    c = card(ctx)

    {:ok, _} =
      fixture(fn -> Boards.Handoffs.leave_handoff(c, author, %{next_step: "Next", via: "ui"}) end)

    Boards.Handoffs.delete_handoff(c)
  end

  defp wait_on(ctx, attrs, opener) do
    c = card(ctx)
    {:ok, _} = fixture(fn -> Boards.Waits.open_wait(c, Actor.web(opener), attrs) end)
    Boards.Cards.get_card!(c.id)
  end

  defp refused?(result, action, by),
    do: match?({:error, %Refused{action: ^action, by: ^by}}, result)

  defp passed?(:ok), do: true
  defp passed?({:ok, _}), do: true
  defp passed?(_), do: false

  # A refusal of the token, at this action or at the other end it asks too.
  defp token_refused?(result), do: match?({:error, %Refused{by: :token}}, result)

  # The two whose other end asks write of the actor's own card.
  @both_ends [:move_card_in, :link_to_card]

  test "the table's card rows are the ones tested here" do
    for {action, need} <- @actions do
      assert {_scope, ^need} = Policy.rules()[action], "#{action} needs #{need} in the table"
    end

    # Policy 1's tag rows, Policy 3's board rows and Policy 4's wiki rows are
    # tested beside theirs.
    card_rows =
      Policy.rules()
      |> Map.keys()
      |> Enum.reject(
        &(&1 in Keyword.keys(Slipdock.PolicyActions.boards()) or
            &1 in Keyword.keys(Slipdock.PolicyActions.wiki()) or
            &1 in Slipdock.PolicyActions.tags())
      )

    assert Enum.sort(card_rows) == @actions |> Keyword.keys() |> Enum.sort()
  end

  for {action, need} <- @actions do
    describe "#{action} (needs #{need})" do
      test "passes at #{need}", ctx do
        {user, _} = person(ctx, grant_for(unquote(need)))
        as(user)
        result = act(unquote(action), ctx, user)
        assert passed?(result), "refused at #{unquote(need)}: #{inspect(result)}"
      end

      test "a person a level short is refused, named as the person", ctx do
        user =
          case short_of(unquote(need)) do
            nil -> person(ctx, nil)
            level -> ctx |> person(level) |> elem(0)
          end

        as(user)
        assert refused?(act(unquote(action), ctx, user), unquote(action), :user)
      end

      test "a read-only token on the owner narrows it, named as the token", ctx do
        {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
        as(ctx.owner, token)
        result = act(unquote(action), ctx, ctx.owner)

        if unquote(need) == :read and unquote(action) not in @both_ends,
          do: assert(passed?(result), inspect(result)),
          else: assert(token_refused?(result), inspect(result))
      end

      test "a level lowered after the actor was set is read at the write", ctx do
        {user, grant} = person(ctx, grant_for(unquote(need)))
        as(user)

        case short_of(unquote(need)) do
          nil -> {:ok, _} = fixture(fn -> Access.revoke(grant) end)
          level -> {:ok, _} = Access.grant(ctx.root, user, level, ctx.owner)
        end

        assert refused?(act(unquote(action), ctx, user), unquote(action), :user)
      end
    end
  end

  describe "remove_link/1 takes either end" do
    # A link shows on both its cards, so a writer of either may take it off.
    setup ctx do
      writer = ctx |> person(nil)
      own = board_fixture(%{"name" => "Writer's own"}, owner: writer)
      mine = card_fixture(hd(own.columns), %{"title" => "Mine"})
      theirs = card(ctx, "Theirs")
      %{writer: writer, mine: mine, theirs: theirs}
    end

    defp link(from, to) do
      {:ok, link} = fixture(fn -> Boards.Links.add_link(from, to, "relates") end)
      link
    end

    test "from its own end", ctx do
      as(ctx.writer)
      assert {:ok, _} = Boards.Links.remove_link(link(ctx.mine, ctx.theirs))
    end

    test "from the other end", ctx do
      as(ctx.writer)
      assert {:ok, _} = Boards.Links.remove_link(link(ctx.theirs, ctx.mine))
    end

    test "and neither is refused", ctx do
      stranger = person(ctx, nil)
      as(stranger)

      assert {:error, %Refused{action: :edit_link, by: :user}} =
               Boards.Links.remove_link(link(ctx.mine, ctx.theirs))
    end
  end
end
