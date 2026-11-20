defmodule Slipdock.PolicyBoardsTest do
  @moduledoc """
  Policy 3 (#3170): the writes of boards, lists, views, sprints and grants
  ask `Slipdock.Policy` themselves. For every action in the table's board
  rows (`Slipdock.PolicyActions.boards/0`), the context is called with no
  door in the way, the actor set as a door sets it: the level the action
  needs passes; a person short of it, a read-only token on the owner, and a
  level lowered after the actor was set are each refused, saying which of
  the two was short (ARCH-8). Owning a board is its row's `owner_id`, read
  again at the write (#2998).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Actor, Boards, Policy, Repo, Sprints, Wiki}
  alias Slipdock.Policy.Refused

  @actions Slipdock.PolicyActions.boards()

  setup do
    owner = user_fixture("boards.policy.owner@example.com")
    root = board_fixture(%{"name" => "Policy boards"}, owner: owner)
    # The share rows' table level (write) holds where the owner lets editors
    # share (#3558); `share_onward_test.exs` has the board that doesn't.
    root = Repo.update!(Ecto.Changeset.change(root, editors_may_share: true))
    card = card_fixture(hd(root.columns), %{"title" => "Card"})
    %{owner: owner, root: root, card: card}
  end

  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})
  defp fixture(fun), do: Policy.as_system("a test fixture", fun)

  defp stranger,
    do: user_fixture("boards.policy.#{System.unique_integer([:positive])}@example.com")

  defp person(ctx, level) do
    user = stranger()
    {:ok, grant} = fixture(fn -> Access.grant(ctx.root, user, level, ctx.owner) end)
    {user, grant}
  end

  # Who passes, for the level an action needs: a granted person, or the
  # board's owner (`:owner`, which no grant gives). The `:self` and
  # `:account` actions are the person's own.
  defp right(ctx, :owner), do: {ctx.owner, nil}
  defp right(ctx, :write), do: person(ctx, "write")

  defp short(ctx, :owner), do: ctx |> person("write") |> elem(0)
  defp short(ctx, :write), do: ctx |> person("comment") |> elem(0)

  # Lowers `user` below what an action needs, after the actor was set.
  defp lower(ctx, :owner, _user, _grant),
    do: Repo.update!(Ecto.Changeset.change(ctx.root, owner_id: stranger().id))

  defp lower(ctx, :write, user, _grant),
    do: {:ok, _} = fixture(fn -> Access.grant(ctx.root, user, "comment", ctx.owner) end)

  @own ~w(create_board arrange_own own_template)a

  # The write `action` stands for, by `user`.
  defp act(:create_board, _ctx, user),
    do: Boards.create_board(%{"name" => "Mine"}, owner_id: user.id)

  defp act(:update_board, ctx, _user), do: Boards.update_board(ctx.root, %{"name" => "Renamed"})
  defp act(:delete_board, ctx, _user), do: Boards.delete_board(ctx.root)
  defp act(:archive_board, ctx, _user), do: Boards.Arrangement.archive_board(ctx.root)

  defp act(:edit_sub_board, ctx, _user) do
    {:ok, t} = Boards.Templates.find_template(nil, "Simple")
    Boards.create_sub_board(ctx.card, t)
  end

  defp act(:edit_list, ctx, _user),
    do: Boards.Columns.create_column(ctx.root, %{"name" => "More"})

  defp act(:place_in_list, ctx, _user) do
    [a, b | _] = ctx.root.columns
    Boards.Columns.reorder({:card, ctx.card.id}, a.id, b.id)
  end

  defp act(:edit_view, ctx, _user),
    do: Boards.SavedViews.create_saved_view(ctx.root, %{"name" => "V"})

  defp act(:publish_view, ctx, _user) do
    {:ok, view} =
      fixture(fn -> Boards.SavedViews.create_saved_view(ctx.root, %{"name" => "V"}) end)

    Boards.SavedViews.publish_saved_view(view)
  end

  defp act(:edit_sprint, ctx, _user), do: Sprints.create_sprint(ctx.root)

  defp act(:add_to_sprint, ctx, _user), do: Sprints.add_cards(ctx.card, [])
  defp act(:arrange_own, _ctx, user), do: Boards.Arrangement.reorder_boards(user, [])

  defp act(:own_template, _ctx, user),
    do:
      Boards.Templates.create_template(user, %{
        "name" => "T #{user.id}",
        "columns" => [%{"name" => "A"}]
      })

  defp act(:share_board, ctx, user), do: Access.grant(ctx.root, stranger(), "read", user)

  defp act(:share_view, ctx, user) do
    {:ok, view} =
      fixture(fn -> Boards.SavedViews.create_saved_view(ctx.root, %{"name" => "V"}) end)

    Access.grant(view, stranger(), "read", user)
  end

  # Turning editors' sharing off again, on a board that has it on.
  defp act(:let_editors_share, ctx, _user),
    do: Boards.update_board(ctx.root, %{"editors_may_share" => false})

  defp act(:share_card, ctx, user), do: Access.grant(ctx.card, stranger(), "read", user)

  defp act(:share_page, ctx, user),
    do: Access.grant(page_fixture(ctx.root, %{"title" => "P"}), stranger(), "read", user)

  defp act(:share_folder, ctx, user) do
    {:ok, folder} = fixture(fn -> Wiki.create_folder(ctx.root, %{"name" => "F"}) end)
    Access.grant(folder, stranger(), "read", user)
  end

  # The tool is the board's owner's, as they are now: lowering the owner
  # hands it on with the board.
  defp act(:share_tool, ctx, user) do
    tool =
      Repo.insert!(%Slipdock.Tools.Tool{
        owner_id: Repo.get!(Boards.Board, ctx.root.id).owner_id,
        name: "Tool",
        slug: "tool-#{System.unique_integer([:positive])}"
      })

    Access.grant(tool, stranger(), "read", user)
  end

  # Granting a runner pool (#3492), as the process's actor.
  defp act(:share_pool, ctx, _user),
    do: Slipdock.Runners.PoolGrants.grant(ctx.root, "dev", stranger().email)

  defp refused?(result, action, by),
    do: match?({:error, %Refused{action: ^action, by: ^by}}, result)

  defp refused_by?(result, by), do: match?({:error, %Refused{by: ^by}}, result)

  # Passing: anything but the policy's refusal (an empty sprint add, say, is
  # the context's own answer once the policy let it through).
  defp passed?(result), do: not match?({:error, %Refused{}}, result)

  test "the table's board rows are the ones tested here" do
    for {action, need} <- @actions do
      assert {_scope, ^need} = Policy.rules()[action], "#{action} needs #{need} in the table"
    end
  end

  for {action, need} <- @actions, action not in @own do
    describe "#{action} (needs #{need})" do
      test "passes at #{need}", ctx do
        {user, _} = right(ctx, unquote(need))
        as(user)
        result = act(unquote(action), ctx, user)
        assert passed?(result), inspect(result)
      end

      test "a person short of it is refused, named as the person", ctx do
        user = short(ctx, unquote(need))
        as(user)
        assert refused?(act(unquote(action), ctx, user), unquote(action), :user)
      end

      test "a read-only token on the owner narrows it, named as the token", ctx do
        {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
        as(ctx.owner, token)
        assert refused_by?(act(unquote(action), ctx, ctx.owner), :token)
      end

      test "a level lowered after the actor was set is read at the write", ctx do
        {user, grant} = right(ctx, unquote(need))
        as(user)
        lower(ctx, unquote(need), user, grant)
        assert refused?(act(unquote(action), ctx, user), unquote(action), :user)
      end
    end
  end

  describe "a person's own (create_board, arrange_own, own_template)" do
    for action <- @own do
      test "#{action}: the person passes, and a read-only token is refused", ctx do
        user = stranger()
        as(user)
        assert passed?(act(unquote(action), ctx, user))

        {_plain, token} = Accounts.create_api_token(user, "reader", scope: "read")
        as(user, token)
        assert refused_by?(act(unquote(action), ctx, user), :token)
      end
    end

    test "arrange_own and own_template: somebody else's rows are refused", ctx do
      as(ctx.owner)
      other = stranger()
      assert refused?(act(:arrange_own, ctx, other), :arrange_own, :user)
      assert refused?(act(:own_template, ctx, other), :own_template, :user)
    end

    test "create_board: nobody acting is refused, a token scoped to one board is not", ctx do
      Policy.forbid_nobody()
      assert refused?(act(:create_board, ctx, ctx.owner), :create_board, :nobody)

      {_plain, token} =
        Accounts.create_api_token(ctx.owner, "one board",
          scope: "write",
          scope_boards: [ctx.root.id]
        )

      as(ctx.owner, token)
      assert passed?(act(:create_board, ctx, ctx.owner))
    end
  end

  describe "a grant" do
    test "is asked of the person sharing, whoever the process acts for", ctx do
      writer = ctx |> person("write") |> elem(0)
      as(ctx.owner)
      assert refused?(Access.grant(ctx.root, stranger(), "read", writer), :share_board, :user)
    end

    test "taking one back asks what making it does", ctx do
      {_user, grant} = person(ctx, "read")
      writer = ctx |> person("write") |> elem(0)
      as(writer)
      assert refused?(Access.revoke(grant), :share_board, :user)
      as(ctx.owner)
      assert {:ok, _} = Access.revoke(grant)
    end
  end

  # The verifier's survivors on #3170: each write below asks a level or a
  # subject the table's sweep above doesn't reach through that function.
  describe "a view's other writes" do
    setup ctx do
      {:ok, view} =
        fixture(fn -> Boards.SavedViews.create_saved_view(ctx.root, %{"name" => "V"}) end)

      {:ok, view} = fixture(fn -> Boards.SavedViews.publish_saved_view(view) end)
      %{view: view}
    end

    test "unpublishing is the owner's: a write-level person is refused", ctx do
      writer = ctx |> person("write") |> elem(0)
      as(writer)

      assert refused?(
               Boards.SavedViews.unpublish_saved_view(ctx.view),
               :publish_view,
               :user
             )

      assert Repo.get!(Boards.SavedView, ctx.view.id).public_token

      as(ctx.owner)
      assert {:ok, %{public_token: nil}} = Boards.SavedViews.unpublish_saved_view(ctx.view)
    end

    test "deleting asks write on its board", ctx do
      commenter = ctx |> person("comment") |> elem(0)
      as(commenter)
      assert refused?(Boards.SavedViews.delete_saved_view(ctx.view), :edit_view, :user)

      # The owner's own token, made as a fixture: the commenter is acting
      # (`:own_sign_in`, #3172).
      {_plain, %Accounts.UserToken{} = token} =
        fixture(fn -> Accounts.create_api_token(ctx.owner, "reader", scope: "read") end)

      as(ctx.owner, token)
      assert refused_by?(Boards.SavedViews.delete_saved_view(ctx.view), :token)
      assert Repo.get(Boards.SavedView, ctx.view.id)

      writer = ctx |> person("write") |> elem(0)
      as(writer)
      assert {:ok, _} = Boards.SavedViews.delete_saved_view(ctx.view)
      refute Repo.get(Boards.SavedView, ctx.view.id)
    end
  end

  describe "placing in a list on another board" do
    # A card's move between boards asks for the card itself first; the list
    # step asks the board of the list it joins, not the one it leaves.
    setup do
      other = board_fixture(%{"name" => "Other board"}, owner: stranger())
      %{other: other}
    end

    test "into a list on a board the actor can't write is refused", ctx do
      as(ctx.owner)
      from = hd(ctx.root.columns)
      to = hd(ctx.other.columns)

      assert refused?(
               Boards.Columns.reorder({:card, ctx.card.id}, from.id, to.id),
               :place_in_list,
               :user
             )
    end

    test "out of a board the actor can't write, into one they can, passes", ctx do
      as(ctx.owner)
      card = fixture(fn -> card_fixture(hd(ctx.other.columns), %{"title" => "Theirs"}) end)
      from = hd(ctx.other.columns)
      to = hd(ctx.root.columns)
      assert :ok = Boards.Columns.reorder({:card, card.id}, from.id, to.id)
    end
  end

  describe "discarding a shared board" do
    test "is the person's own: another person is refused, the person passes", ctx do
      {user, _grant} = person(ctx, "read")
      as(stranger())
      assert refused?(Access.discard_board(user, ctx.root), :arrange_own, :user)
      assert Access.board_permission(user, ctx.root) == :read

      as(user)
      assert {:ok, :none} = Access.discard_board(user, ctx.root)
    end
  end
end
