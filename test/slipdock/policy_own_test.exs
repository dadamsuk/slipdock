defmodule Slipdock.PolicyOwnTest do
  @moduledoc """
  Policy 5 (#3172): a person's own rows and the server's accounts ask
  `Slipdock.Policy` themselves. For every action in the table's rows for
  them (`Slipdock.PolicyActions.own/0`), the context is called with no door
  in the way, the actor set as a door sets it: the person (or an admin)
  passes; somebody else, a read-only token, and an account disabled or
  demoted after the actor was set are each refused, saying which was short
  (ARCH-8).

  Every guarded function is called once more as somebody else, so a write
  that stops asking fails here by name (`@writes`).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{
    Accounts,
    Actor,
    CardViews,
    Favourites,
    HeaderLinks,
    Multiboard,
    OAuth,
    Policy,
    Repo,
    SavedQueries,
    TransferLinks,
    Work
  }

  alias Slipdock.Accounts.{DeviceFlow, Groups, Passkeys, SignupRequest, Support, User, UserToken}
  alias Slipdock.Policy.Refused

  @actions Slipdock.PolicyActions.own()

  setup do
    user = user_fixture("own.policy.#{System.unique_integer([:positive])}@example.com")
    board = board_fixture(%{"name" => "Own"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Card"})
    %{user: user, board: board, card: card}
  end

  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})

  defp stranger,
    do: user_fixture("own.policy.#{System.unique_integer([:positive])}@example.com")

  defp admin do
    {:ok, admin} = Accounts.promote(stranger())
    admin
  end

  defp read_token(user) do
    {_plain, token} = Accounts.create_api_token(user, "reader", scope: "read")
    token
  end

  defp disable!(user), do: Repo.update!(Ecto.Changeset.change(user, disabled_at: now()))
  defp now, do: DateTime.utc_now(:second)

  defp refused?(result, action, by),
    do: match?({:error, %Refused{action: ^action, by: ^by}}, result)

  defp passed?(result), do: not match?({:error, %Refused{}}, result)

  # One write per action, on `user`'s own rows (or, for `:administer`, on
  # `user` as an account).
  defp act(:own_settings, _ctx, user), do: Accounts.update_profile(user, %{"name" => "N"})

  defp act(:own_view, _ctx, user), do: SavedQueries.save(user, "search", "words")
  defp act(:own_work, ctx, user), do: Work.mute(user, ctx.board)

  defp act(:own_group, _ctx, user), do: Groups.create_group(user, %{"name" => "G"})

  defp act(:own_sign_in, _ctx, user), do: Accounts.delete_api_token(user, -1)

  defp act(:own_transfer_link, ctx, user),
    do: TransferLinks.mint(user, token_of(user), {:card, ctx.card})

  defp act(:administer, ctx, _user),
    do: Accounts.update_standing(ctx.user, %{"unlimited" => true})

  defp token_of(user) do
    {_plain, token} =
      Policy.as_system("a test fixture", fn ->
        Accounts.create_api_token(user, "maker")
      end)

    token
  end

  test "the table's rows for a person's own and the server's accounts are the ones tested here" do
    for {action, need} <- @actions do
      assert {_scope, ^need} = Policy.rules()[action], "#{action} needs #{need} in the table"
    end

    others =
      Slipdock.PolicyActions.tags() ++
        Keyword.keys(Slipdock.PolicyActions.boards()) ++
        Keyword.keys(Slipdock.PolicyActions.wiki())

    refute Enum.any?(Keyword.keys(@actions), &(&1 in others))
  end

  @personal Keyword.keys(@actions) -- [:administer]

  describe "a person's own" do
    for action <- @personal do
      test "#{action}: the person passes", ctx do
        as(ctx.user)
        assert passed?(act(unquote(action), ctx, ctx.user))
      end

      test "#{action}: somebody else is refused", ctx do
        as(stranger())
        assert refused?(act(unquote(action), ctx, ctx.user), unquote(action), :user)
      end

      test "#{action}: an account disabled after the actor was set is refused", ctx do
        as(ctx.user)
        disable!(ctx.user)
        assert refused?(act(unquote(action), ctx, ctx.user), unquote(action), :user)
      end

      test "#{action}: nobody acting is refused", ctx do
        Policy.forbid_nobody()
        assert refused?(act(unquote(action), ctx, ctx.user), unquote(action), :nobody)
      end
    end

    for action <- @personal -- [:own_transfer_link] do
      test "#{action}: a read-only token is refused, named as the token", ctx do
        as(ctx.user, read_token(ctx.user))
        assert refused?(act(unquote(action), ctx, ctx.user), unquote(action), :token)
      end
    end

    # A read-only token may still fetch a file it can read: the link needs
    # read, and the transfer itself is checked as the token (#3172).
    test "own_transfer_link: a read-only token passes", ctx do
      as(ctx.user, read_token(ctx.user))
      assert passed?(act(:own_transfer_link, ctx, ctx.user))
    end
  end

  describe "the server's accounts (administer)" do
    test "an admin passes", ctx do
      as(admin())
      assert passed?(act(:administer, ctx, nil))
    end

    test "somebody who isn't an admin is refused, the account's own person too", ctx do
      as(stranger())
      assert refused?(act(:administer, ctx, nil), :administer, :user)
      as(ctx.user)
      assert refused?(act(:administer, ctx, nil), :administer, :user)
    end

    test "an admin's read-only token is refused, named as the token", ctx do
      admin = admin()
      as(admin, read_token(admin))
      assert refused?(act(:administer, ctx, nil), :administer, :token)
    end

    test "an admin demoted after the actor was set is refused", ctx do
      admin = admin()
      as(admin)
      Repo.update!(Ecto.Changeset.change(admin, admin: false))
      assert refused?(act(:administer, ctx, nil), :administer, :user)
    end

    test "an admin disabled after the actor was set is refused", ctx do
      admin = admin()
      as(admin)
      disable!(admin)
      assert refused?(act(:administer, ctx, nil), :administer, :user)
    end

    test "nobody acting is refused", ctx do
      Policy.forbid_nobody()
      assert refused?(act(:administer, ctx, nil), :administer, :nobody)
    end

    # Where the context names the admin (`by`), it asks as them, whoever the
    # process acts for.
    test "a function that names the admin asks as that admin", ctx do
      as(admin())
      named = stranger()
      assert refused?(Accounts.change_email(ctx.user, "x@example.com", named), :administer, :user)
      assert refused?(Accounts.add_user("new@example.com", named), :administer, :user)
    end

    test "opening a support session keeps its own refusals first", ctx do
      as(admin())
      assert {:error, :not_admin} = Support.open_support_session(stranger(), ctx.user, "why")
    end
  end

  # Every guarded write, as somebody else: each is refused by the policy,
  # with its own action. A guard taken off fails here by its name.
  describe "every write asks" do
    setup ctx do
      {:ok, view} =
        Policy.as_system("fixture", fn -> CardViews.create(ctx.user, %{"name" => "V"}) end)

      {:ok, saved} =
        Policy.as_system("fixture", fn ->
          Multiboard.create_saved(ctx.user, %{"name" => "M"}, %{})
        end)

      {:ok, group} =
        Policy.as_system("fixture", fn -> Groups.create_group(ctx.user, %{"name" => "G"}) end)

      {_code, device} = DeviceFlow.request_device_authorization(%{})
      a = admin()

      {:ok, session} =
        Policy.as_system("fixture", fn -> Support.open_support_session(a, ctx.user, "why") end)

      %{view: view, saved: saved, group: group, device: device, session: session, admin: a}
    end

    test "a person's own rows refuse somebody else", ctx do
      u = ctx.user

      challenge =
        Wax.new_registration_challenge(origin: "https://example.com", rp_id: "example.com")

      writes = [
        own_settings: fn -> Accounts.update_profile(u, %{"name" => "N"}) end,
        own_settings: fn -> Accounts.update_quick_add(u, %{}) end,
        own_settings: fn -> Accounts.update_quick_note(u, %{}) end,
        own_settings: fn -> Accounts.update_inbound(u, %{}) end,
        own_settings: fn -> Accounts.update_board_view(u, %{}) end,
        own_settings: fn -> Accounts.update_multiboard(u, %{}) end,
        own_settings: fn -> Accounts.update_display(u, %{}) end,
        own_settings: fn -> Accounts.update_waiting_notice(u, %{}) end,
        own_settings: fn -> CardViews.update_level(u, :global, %{}) end,
        own_settings: fn -> CardViews.clear_level(u, :global) end,
        own_settings: fn -> CardViews.put_show_all(u, ctx.board, true) end,
        own_settings: fn -> Multiboard.save_prefs(u, %{lists: [], top: 5, by: "board"}) end,
        own_view: fn -> CardViews.create(u, %{"name" => "W"}) end,
        own_view: fn -> CardViews.update(u, ctx.view, %{"name" => "X"}) end,
        own_view: fn -> CardViews.delete(u, ctx.view) end,
        own_view: fn -> Multiboard.create_saved(u, %{"name" => "N"}, %{}) end,
        own_view: fn -> Multiboard.update_saved(ctx.saved, %{"name" => "N"}) end,
        own_view: fn -> Multiboard.save_view(ctx.saved, %{}) end,
        own_view: fn -> Multiboard.delete_saved(ctx.saved) end,
        own_view: fn -> SavedQueries.save(u, "search", "w") end,
        own_view: fn -> SavedQueries.delete(u, 1) end,
        own_view: fn -> SavedQueries.remove(u, "search", "w") end,
        own_view: fn -> SavedQueries.toggle(u, "search", "w") end,
        own_view: fn -> Favourites.toggle(u, :board, ctx.board.id) end,
        own_view: fn -> Favourites.add(u, :board, ctx.board.id) end,
        own_view: fn -> Favourites.remove(u, :board, ctx.board.id) end,
        own_view: fn -> HeaderLinks.add(u, ctx.board, hd(Slipdock.Wiki.Icons.names())) end,
        own_view: fn -> HeaderLinks.remove(u, 1) end,
        own_view: fn -> HeaderLinks.move(u, 1, :left) end,
        own_work: fn -> Work.dismiss(u, ctx.card) end,
        own_work: fn -> Work.undismiss(u, ctx.card) end,
        own_work: fn -> Work.mute(u, ctx.board) end,
        own_work: fn -> Work.unmute(u, ctx.board) end,
        own_group: fn -> Groups.create_group(u, %{"name" => "H"}) end,
        own_group: fn -> Groups.update_group(ctx.group, %{"name" => "H"}) end,
        own_group: fn -> Groups.delete_group(ctx.group) end,
        own_group: fn -> Groups.add_group_member(ctx.group, "m@example.com") end,
        own_group: fn -> Groups.remove_group_member(ctx.group, u) end,
        own_sign_in: fn -> Accounts.create_api_token(u, "t") end,
        own_sign_in: fn -> Accounts.delete_api_token(u, 1) end,
        own_sign_in: fn -> Accounts.delete_all_sessions(u) end,
        own_sign_in: fn -> Passkeys.delete(u, 1) end,
        own_sign_in: fn -> Passkeys.register(u, challenge, %{}, "k") end,
        own_sign_in: fn -> DeviceFlow.approve_device_authorization(ctx.device, u) end,
        own_sign_in: fn -> OAuth.issue_code(u, %{}, "read") end,
        own_transfer_link: fn -> TransferLinks.mint(u, %UserToken{}, {:card, ctx.card}) end
      ]

      as(stranger())

      for {action, write} <- writes do
        assert refused?(write.(), action, :user), "#{action}: #{inspect(write)} didn't ask"
      end
    end

    test "the server's accounts refuse somebody who isn't an admin", ctx do
      u = ctx.user
      not_admin = stranger()

      writes = [
        fn -> Accounts.update_standing(u, %{"unlimited" => true}) end,
        fn -> Accounts.promote(u) end,
        fn -> Accounts.demote(u) end,
        fn -> Accounts.disable(u) end,
        fn -> Accounts.enable(u) end,
        fn -> Accounts.delete_user(u) end,
        fn -> Accounts.change_email(u, "y@example.com", not_admin) end,
        fn -> Accounts.request_admin_email_change("z@example.com", not_admin) end,
        fn -> Accounts.confirm_admin_email_change("12345678", not_admin) end,
        fn -> Accounts.add_user("added@example.com", not_admin) end,
        fn -> Accounts.approve_signup(%SignupRequest{}, not_admin, & &1) end,
        fn -> Accounts.reject_signup(%SignupRequest{}, not_admin) end,
        fn -> Support.end_support_session(ctx.session) end,
        fn -> Support.open_support_session(%{ctx.admin | admin: true}, u, "why", []) end
      ]

      as(not_admin)
      Repo.update!(Ecto.Changeset.change(ctx.admin, admin: false))

      for write <- writes do
        assert refused?(write.(), :administer, :user), "#{inspect(write)} didn't ask"
      end
    end

    test "refusing a device code is anybody signed in's, never nobody's", ctx do
      somebody = stranger()
      Policy.forbid_nobody()
      assert refused?(DeviceFlow.deny_device_authorization(ctx.device), :own_sign_in, :nobody)
      as(somebody)
      assert {:ok, _} = DeviceFlow.deny_device_authorization(ctx.device)
    end

    test "a group's owner passes on the group itself", ctx do
      as(ctx.user)
      assert {:ok, _} = Groups.update_group(ctx.group, %{"name" => "Renamed"})
      assert {:ok, _} = Groups.delete_group(ctx.group)
    end

    # The polling client has no session: the person approved the code, so the
    # mint is the server's own.
    test "a device code approved is minted for the client polling with nobody acting", ctx do
      {code, request} = DeviceFlow.request_device_authorization(%{})
      as(ctx.user)
      assert {:ok, _} = DeviceFlow.approve_device_authorization(request, ctx.user)

      Actor.put(nil)
      Policy.forbid_nobody()
      assert {:ok, token} = DeviceFlow.poll_device_authorization(code)
      assert is_binary(token)
      assert Accounts.get_user_by_api_token(token).id == ctx.user.id
    end

    test "the recovery route makes an admin with nobody acting, as the server", ctx do
      Policy.forbid_nobody()
      assert {:ok, %User{admin: true}} = Accounts.restore_admin(ctx.user)
    end
  end
end
