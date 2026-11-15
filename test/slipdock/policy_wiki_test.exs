defmodule Slipdock.PolicyWikiTest do
  @moduledoc """
  Policy 4 (#3171): the writes of the wiki, vaults and recordings ask
  `Slipdock.Policy` themselves. For every action in the table's wiki rows
  (`Slipdock.PolicyActions.wiki/0`), the context is called with no door in
  the way, the actor set as a door sets it: the level the action needs
  passes; a person short of it, a read-only token on the owner, and a level
  lowered after the actor was set are each refused (ARCH-8).

  A page's level is the higher of its board's and its share's
  (`Access.page_permission/2`); a folder's comes from its home. Where a
  function is asked of a person it names (filing a page elsewhere, moving
  one, installing the handbook), its own refusals come first, so the
  person short of the level meets those, and a token scoped to another
  board shows which board the policy asks.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Accounts, Actor, Boards, Policy, Repo, Vaults, Wiki}
  alias Slipdock.Policy.Refused
  alias Slipdock.Wiki.{Autosaves, Files, FolderPlacements, Placements, TreeStates}

  @actions Slipdock.PolicyActions.wiki()

  setup do
    Slipdock.TestConfig.own_uploads_dir()
    owner = user_fixture("wiki.policy.owner@example.com")
    root = board_fixture(%{"name" => "Policy wiki"}, owner: owner)
    card = card_fixture(hd(root.columns), %{"title" => "Card"})
    {:ok, folder} = fixture(fn -> Wiki.create_folder(root, %{"name" => "Folder"}) end)
    page = page_fixture(root, %{"title" => "Page", "body" => "Words"}, user: owner)
    other = page_fixture(root, %{"title" => "Other"}, user: owner)
    source = Path.join(System.tmp_dir!(), "policy-wiki-#{System.unique_integer([:positive])}")
    File.write!(source, "bytes")
    on_exit(fn -> File.rm(source) end)
    {:ok, file} = fixture(fn -> Files.create(root, %{name: "notes.txt"}, source, owner) end)

    {:ok, attachment} =
      fixture(fn ->
        Boards.Attachments.add_attachment(
          card,
          %{filename: "a.txt", content_type: "text/plain"},
          source
        )
      end)

    %{
      owner: owner,
      root: root,
      card: card,
      folder: folder,
      page: page,
      other: other,
      wfile: file,
      source: source,
      attachment: attachment
    }
  end

  defp as(user, token \\ nil), do: Actor.put(Actor.web(user), nil, {user, token})
  defp fixture(fun), do: Policy.as_system("a test fixture", fun)

  defp stranger,
    do: user_fixture("wiki.policy.#{System.unique_integer([:positive])}@example.com")

  defp person(ctx, level, board \\ nil) do
    user = stranger()
    {:ok, grant} = fixture(fn -> Access.grant(board || ctx.root, user, level, ctx.owner) end)
    {user, grant}
  end

  defp right(ctx, :owner), do: {ctx.owner, nil}
  defp right(ctx, :write), do: person(ctx, "write")

  defp short(ctx, :owner), do: ctx |> person("write") |> elem(0)
  defp short(ctx, :write), do: ctx |> person("comment") |> elem(0)

  defp lower(ctx, :owner, _user, _grant),
    do: Repo.update!(Ecto.Changeset.change(ctx.root, owner_id: stranger().id))

  defp lower(ctx, :write, user, _grant),
    do: {:ok, _} = fixture(fn -> Access.grant(ctx.root, user, "comment", ctx.owner) end)

  # Asked of a person the call names, after the function's own refusals:
  # the person short of it meets those first.
  @named ~w(file_also move_wiki_out move_wiki_in install_handbook adopt_knowledge_base purge_revisions)a
  # A person's own rows.
  @own ~w(own_draft own_tree_state own_vault own_google)a
  # Tested on their own below, where their rule is.
  @apart ~w(pin_to_card link_page transcribe_file)a

  # The write `action` stands for, by `user`.
  defp act(:create_wiki_item, ctx, _user), do: Wiki.create_page(ctx.root, %{"title" => "New"})
  defp act(:edit_page, ctx, _user), do: Wiki.update_page(ctx.page, %{"body" => "Changed"})
  defp act(:archive_page, ctx, _user), do: Wiki.archive_page(ctx.page)
  defp act(:delete_page, ctx, _user), do: Wiki.delete_page(ctx.page)

  # `user:` is the board's owner, whose own check passes: the person acting
  # is the one asked.
  defp act(:purge_revisions, ctx, _user),
    do: Wiki.purge_revisions(ctx.page, ["999999"], user: ctx.owner)

  defp act(:publish_page, ctx, _user), do: Wiki.publish(ctx.page)
  defp act(:place_page, ctx, _user), do: Wiki.place(ctx.page, hd(ctx.root.columns))
  defp act(:pin_page, ctx, _user), do: Wiki.pin(ctx.page, {:page, ctx.other})
  defp act(:write_up_card, ctx, _user), do: Wiki.create_page_from_card(ctx.card)
  defp act(:arrange_wiki, ctx, _user), do: Wiki.set_tree_icons(ctx.root, true)
  defp act(:edit_folder, ctx, _user), do: Wiki.update_folder(ctx.folder, %{"name" => "Renamed"})
  defp act(:delete_folder, ctx, _user), do: Wiki.delete_folder(ctx.folder)
  defp act(:purge_folder, ctx, _user), do: Wiki.delete_folder(ctx.folder, :purge)
  defp act(:edit_file, ctx, _user), do: Files.replace(ctx.wfile, %{}, ctx.source)
  defp act(:archive_file, ctx, _user), do: Files.archive(ctx.wfile)
  defp act(:delete_file, ctx, _user), do: Files.delete(ctx.wfile)
  defp act(:reread_file, ctx, _user), do: Slipdock.OCR.retry(ctx.attachment)
  defp act(:file_also, ctx, user), do: Placements.add(ctx.page, ctx.folder, user)

  defp act(:move_wiki_out, ctx, user) do
    {target, _} = ctx[:target] || target_board(ctx)
    Wiki.Move.to_board(ctx.page, target, nil, user)
  end

  defp act(:move_wiki_in, ctx, user) do
    {target, _} = ctx[:target] || target_board(ctx)
    Wiki.Move.to_board(ctx.page, target, nil, user)
  end

  defp act(:install_handbook, ctx, user), do: Slipdock.Handbook.install(user, ctx.root)

  defp act(:adopt_knowledge_base, ctx, user),
    do: Wiki.KnowledgeBase.adopt(user, ctx.root, name: "Mine")

  defp act(:own_draft, ctx, user),
    do: Autosaves.save(user, ctx.root, ctx.page, nil, %{"body" => "draft"}, nil)

  defp act(:own_tree_state, ctx, user), do: TreeStates.put(user, "board:#{ctx.root.id}", [])

  defp act(:own_vault, _ctx, user),
    do: Vaults.update_vault(Vaults.root(user), %{"name" => "Mine"})

  defp act(:own_google, _ctx, user) do
    Slipdock.Google.connection(user) || Slipdock.GoogleStub.connect!(user)
    Slipdock.GoogleStub.stub(fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
    Slipdock.Google.disconnect(user)
  end

  # Another root board of the owner's, in the same vault, a writer of the
  # first given write on it too.
  defp target_board(ctx) do
    target = board_fixture(%{"name" => "Elsewhere"}, owner: ctx.owner)
    {target, nil}
  end

  defp refused?(result, action, by),
    do: match?({:error, %Refused{action: ^action, by: ^by}}, result)

  defp refused_by?(result, by), do: match?({:error, %Refused{by: ^by}}, result)

  # Passing: anything but the policy's refusal (an empty purge, a file that
  # isn't read for text, is the context's own answer once it let it through).
  defp passed?(result), do: not match?({:error, %Refused{}}, result)

  # The function's own refusal, or the policy's: anything but a success.
  defp refused_any?(result),
    do: not match?({:ok, _}, result) and not match?({:ok, _, _}, result) and result != :ok

  test "the table's wiki rows are the ones tested here" do
    for {action, need} <- @actions do
      assert {_scope, ^need} = Policy.rules()[action], "#{action} needs #{need} in the table"
    end

    tested = Enum.map(@actions, &elem(&1, 0))
    rows = Policy.rules() |> Map.keys()
    others = Slipdock.PolicyActions.tags() ++ Keyword.keys(Slipdock.PolicyActions.boards())
    assert Enum.all?(tested, &(&1 in rows))
    refute Enum.any?(tested, &(&1 in others))
  end

  for {action, need} <- @actions, action not in @own and action not in @apart do
    describe "#{action} (needs #{need})" do
      setup ctx do
        # A move's other board, which the person writes as well.
        if unquote(action) in [:move_wiki_out, :move_wiki_in] do
          {target, _} = target_board(ctx)
          %{target: {target, nil}}
        else
          :ok
        end
      end

      test "passes at #{need}", ctx do
        {user, _} = right(ctx, unquote(need))
        grant_target(ctx, user, "write")
        as(user)
        result = act(unquote(action), ctx, user)
        assert passed?(result), inspect(result)
      end

      test "a person short of it is refused", ctx do
        user = short(ctx, unquote(need))
        grant_target(ctx, user, "write")
        as(user)
        result = act(unquote(action), ctx, user)

        if unquote(action) in @named,
          do: assert(refused_any?(result), inspect(result)),
          else: assert(refused?(result, unquote(action), :user), inspect(result))
      end

      test "a read-only token on the owner narrows it, named as the token", ctx do
        {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
        as(ctx.owner, token)
        assert refused_by?(act(unquote(action), ctx, ctx.owner), :token)
      end

      test "a level lowered after the actor was set is read at the write", ctx do
        {user, grant} = right(ctx, unquote(need))
        grant_target(ctx, user, "write")
        as(user)
        lower(ctx, unquote(need), user, grant)
        result = act(unquote(action), ctx, user)

        if unquote(action) in @named,
          do: assert(refused_any?(result), inspect(result)),
          else: assert(refused?(result, unquote(action), :user), inspect(result))
      end
    end
  end

  defp grant_target(%{target: {target, _}} = ctx, user, level) when user != nil do
    if user.id != ctx.owner.id,
      do: {:ok, _} = fixture(fn -> Access.grant(target, user, level, ctx.owner) end)
  end

  defp grant_target(_ctx, _user, _level), do: :ok

  describe "a person's own (drafts, tree state, vault, Google)" do
    for action <- @own do
      test "#{action}: a read-only token is refused, the person passes", ctx do
        user = stranger()
        {_plain, token} = Accounts.create_api_token(user, "reader", scope: "read")
        as(user, token)
        assert refused?(act(unquote(action), ctx, user), unquote(action), :token)

        as(user)
        assert passed?(act(unquote(action), ctx, user))
      end

      test "#{action}: somebody else's is refused", ctx do
        as(stranger())
        assert refused?(act(unquote(action), ctx, stranger()), unquote(action), :user)
      end
    end

    test "nobody acting is refused", ctx do
      Policy.forbid_nobody()
      assert refused?(act(:create_wiki_item, ctx, nil), :create_wiki_item, :nobody)
      assert refused?(act(:own_tree_state, ctx, ctx.owner), :own_tree_state, :nobody)
    end
  end

  # Each write below asks a level or a subject the table's sweep doesn't
  # reach through that function.
  describe "where a page goes: the folder it is filed in, a share counting" do
    test "a folder sharee makes a page there and nowhere else on the board", ctx do
      sharee = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.folder, sharee, "write", ctx.owner) end)
      as(sharee)

      assert {:ok, _} =
               Wiki.create_page(ctx.root, %{"title" => "Inside", "folder_id" => ctx.folder.id})

      assert refused?(Wiki.create_page(ctx.root, %{"title" => "Top"}), :create_wiki_item, :user)

      assert {:ok, _} =
               Wiki.create_folder(ctx.root, %{"name" => "Sub", "parent_id" => ctx.folder.id})

      assert {:ok, _} =
               Files.create(ctx.root, %{name: "in.txt", folder_id: ctx.folder.id}, ctx.source)

      assert {:ok, _} = Wiki.Drawings.create(ctx.root, ctx.folder)
      assert {:ok, _} = Wiki.Folders.ensure_path(ctx.root, ctx.folder, ["Deep"])

      assert {:ok, _} =
               Wiki.Folders.create_literal(ctx.root, %{
                 "name" => "A/B",
                 "parent_id" => ctx.folder.id
               })
    end

    test "a folder sharee is refused a folder, file, drawing or path at the top", ctx do
      sharee = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.folder, sharee, "write", ctx.owner) end)
      as(sharee)

      assert refused?(
               Wiki.Folders.create_literal(ctx.root, %{"name" => "A/B"}),
               :create_wiki_item,
               :user
             )

      assert refused?(
               Files.create(ctx.root, %{name: "top.txt"}, ctx.source),
               :create_wiki_item,
               :user
             )

      assert refused?(Wiki.Drawings.create(ctx.root, nil), :create_wiki_item, :user)
      assert refused?(Wiki.create_folder(ctx.root, %{"name" => "Top"}), :create_wiki_item, :user)
      assert refused?(Wiki.Folders.ensure_path(ctx.root, nil, ["Top"]), :create_wiki_item, :user)

      assert refused?(
               Wiki.Archive.import_files(ctx.root, [{"x.md", "x"}]),
               :create_wiki_item,
               :user
             )
    end

    test "a page's share is its level: a page sharee edits it, not its neighbour", ctx do
      sharee = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.page, sharee, "write", ctx.owner) end)
      as(sharee)

      assert {:ok, _} = Wiki.update_page(ctx.page, %{"body" => "Shared edit"})
      assert {:ok, _} = Wiki.append(ctx.page, "More")
      assert {:ok, _} = Wiki.set_tags(ctx.page, [])
      assert refused?(Wiki.update_page(ctx.other, %{"body" => "No"}), :edit_page, :user)
      assert refused?(Wiki.append(ctx.other, "No"), :edit_page, :user)
      assert refused?(Wiki.append_section(ctx.other, "", "No"), :edit_page, :user)
    end

    test "a page sharee archives, publishes and puts nothing in a list: those are the board's",
         ctx do
      sharee = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.page, sharee, "write", ctx.owner) end)
      as(sharee)

      assert refused?(Wiki.archive_page(ctx.page), :archive_page, :user)
      assert refused?(Wiki.unarchive_page(ctx.page), :archive_page, :user)
      assert refused?(Wiki.publish(ctx.page), :publish_page, :user)
      assert refused?(Wiki.unpublish(ctx.page), :publish_page, :user)
      assert refused?(Files.archive(ctx.wfile), :archive_file, :user)
      assert refused?(Wiki.delete_folder(ctx.folder), :delete_folder, :user)
    end

    test "a folder's level comes from its home: a share above it counts", ctx do
      {:ok, inner} =
        fixture(fn ->
          Wiki.create_folder(ctx.root, %{"name" => "Inner", "parent_id" => ctx.folder.id})
        end)

      sharee = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.folder, sharee, "write", ctx.owner) end)
      {:ok, outside} = fixture(fn -> Wiki.create_folder(ctx.root, %{"name" => "Outside"}) end)
      as(sharee)

      assert {:ok, _} = Wiki.update_folder(inner, %{"name" => "Inner two"})
      assert {:ok, _} = Wiki.move_folder(inner, ctx.folder)
      assert refused?(Wiki.update_folder(outside, %{"name" => "No"}), :edit_folder, :user)
      assert refused?(Wiki.move_folder(outside, nil), :edit_folder, :user)
      assert refused?(Wiki.set_tree_sort(ctx.root, outside, "name"), :edit_folder, :user)
      assert {:ok, _} = Wiki.set_tree_sort(ctx.root, inner, "name")
    end
  end

  describe "the page's other writes, each asking for the page" do
    test "a commenter is refused, a writer passes", ctx do
      {commenter, _} = person(ctx, "comment")
      {writer, _} = person(ctx, "write")
      [revision | _] = Wiki.list_revisions(ctx.page)

      writes = [
        {:edit_page, fn -> Wiki.move_page(ctx.page, ctx.other) end},
        {:edit_page, fn -> Wiki.revert_page(ctx.page, revision) end},
        {:edit_page, fn -> Wiki.rename_speaker(ctx.page, "A", "B") end},
        {:edit_page, fn -> Wiki.set_tags(ctx.page, []) end},
        {:edit_page, fn -> Wiki.file_page(ctx.page, ctx.folder) end},
        {:edit_page, fn -> Wiki.edit_section(ctx.page, :append, "", "x") end},
        {:place_page, fn -> Wiki.unplace(%{ctx.page | column_id: hd(ctx.root.columns).id}) end},
        {:attach_file, fn -> Wiki.add_attachment(ctx.page, %{filename: "b.txt"}, ctx.source) end},
        {:arrange_wiki, fn -> Wiki.set_tree_sort(ctx.root, nil, "name") end},
        {:archive_page, fn -> Wiki.unarchive_page(ctx.page) end},
        {:publish_page, fn -> Wiki.unpublish(ctx.page) end},
        {:edit_file, fn -> Files.move(ctx.wfile, %{name: "moved.txt"}) end},
        {:create_wiki_item,
         fn -> Wiki.Folders.create_literal(ctx.root, %{"name" => "Lit/eral"}) end},
        {:create_wiki_item, fn -> Wiki.create_folder(ctx.root, %{"name" => "Top folder"}) end},
        {:create_wiki_item,
         fn -> Wiki.Archive.import_files(ctx.root, [{"Imported.md", "Read in."}]) end},
        {:arrange_wiki, fn -> Wiki.AutoOrganise.apply_plan(ctx.root, []) end}
      ]

      for {action, write} <- writes do
        as(commenter)
        assert refused?(write.(), action, :user), "#{action} let a commenter through"
        as(writer)
        assert passed?(write.()), "#{action} refused a writer"
      end
    end

    test "a page's purged history is its owner's, whoever opts[:user] names", ctx do
      {writer, _} = person(ctx, "write")
      as(writer)

      assert refused?(
               Wiki.purge_revisions(ctx.page, ["1"], user: ctx.owner),
               :purge_revisions,
               :user
             )

      as(ctx.owner)
      assert {:ok, 0} = Wiki.purge_revisions(ctx.page, ["1"], user: ctx.owner)
    end

    test "a template's page asks for the folder it is filed in", ctx do
      template = page_fixture(ctx.root, %{"title" => "T", "template" => true}, user: ctx.owner)
      sharee = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.folder, sharee, "write", ctx.owner) end)
      as(sharee)

      assert {:ok, _} = Wiki.create_from_template(ctx.root, template, %{}, folder: ctx.folder)

      assert refused?(
               Wiki.create_from_template(ctx.root, template, %{}, title: "Top"),
               :create_wiki_item,
               :user
             )
    end
  end

  describe "a card's write-up" do
    test "is the card's writer's: a card grant is enough for its own folder", ctx do
      writer = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.card, writer, "write", ctx.owner) end)
      as(writer)

      assert {:ok, page} = Wiki.create_page_from_card(ctx.card)
      assert page.folder_id == Repo.get_by!(Wiki.Folder, card_id: ctx.card.id).id
      assert {:ok, _} = Wiki.CardFolders.ensure(ctx.card)
    end

    test "filed somewhere it was told, the writer writes there too", ctx do
      writer = stranger()
      {:ok, _} = fixture(fn -> Access.grant(ctx.card, writer, "write", ctx.owner) end)
      as(writer)

      assert refused?(
               Wiki.create_page_from_card(ctx.card, folder: ctx.folder),
               :create_wiki_item,
               :user
             )

      assert refused?(
               Wiki.create_page_from_card(ctx.card, parent: ctx.page),
               :create_wiki_item,
               :user
             )

      refute Repo.get_by(Wiki.Page, title: ctx.card.title)

      # Given write there too, it is filed where it was told.
      {:ok, _} = fixture(fn -> Access.grant(ctx.folder, writer, "write", ctx.owner) end)
      assert {:ok, filed} = Wiki.create_page_from_card(ctx.card, folder: ctx.folder)
      assert filed.folder_id == ctx.folder.id
    end

    test "under a page it was told, a writer of the board writes it", ctx do
      {writer, _} = person(ctx, "write")
      as(writer)
      assert {:ok, child} = Wiki.create_page_from_card(ctx.card, parent: ctx.page)
      assert child.parent_id == ctx.page.id
    end

    test "a reader of the board is refused it, and its folder", ctx do
      {reader, _} = person(ctx, "read")
      as(reader)
      assert refused?(Wiki.create_page_from_card(ctx.card), :write_up_card, :user)
      assert refused?(Wiki.CardFolders.ensure(ctx.card), :write_up_card, :user)
      refute Repo.get_by(Wiki.Folder, card_id: ctx.card.id)
    end

    test "a card made from a page's passage asks for the list's board", ctx do
      other = board_fixture(%{"name" => "Theirs"}, owner: stranger())
      as(ctx.owner)

      assert refused?(
               Wiki.create_card_from_selection(ctx.page, hd(other.columns), "Words"),
               :create_card,
               :user
             )

      assert {:ok, card} =
               Wiki.create_card_from_selection(ctx.page, hd(ctx.root.columns), "Words")

      assert Repo.get!(Wiki.Page, ctx.page.id).body =~ "Words (##{card.id})"
    end

    test "the page notes the card only if the person writes it; else the link is kept", ctx do
      maker = stranger()
      theirs = board_fixture(%{"name" => "Maker's"}, owner: maker)
      {:ok, _} = fixture(fn -> Access.grant(ctx.root, maker, "read", ctx.owner) end)
      as(maker)

      assert {:ok, card} = Wiki.create_card_from_selection(ctx.page, hd(theirs.columns), "Words")
      assert Repo.get!(Wiki.Page, ctx.page.id).body == "Words"
      assert Repo.get_by(Wiki.Link, page_id: ctx.page.id, target_card_id: card.id)
    end
  end

  describe "pinning a page to a card" do
    test "the card's writer may pin a page they can read, not one they can't", ctx do
      other = board_fixture(%{"name" => "Card's board"}, owner: stranger())
      card = fixture(fn -> card_fixture(hd(other.columns), %{"title" => "Elsewhere"}) end)
      writer = stranger()

      {:ok, _} =
        fixture(fn ->
          Access.grant(card, writer, "write", other.owner_id |> Accounts.get_user!())
        end)

      as(writer)

      assert refused?(Wiki.pin(ctx.page, {:card, card}), :link_page, :user)

      {:ok, _} = fixture(fn -> Access.grant(ctx.root, writer, "read", ctx.owner) end)
      assert {:ok, _} = Wiki.pin(ctx.page, {:card, card})
      assert {:ok, _} = Wiki.unlink(ctx.page, {:card, card})
    end

    test "the page's writer may pin it to a card they can read, not one they can't", ctx do
      other = board_fixture(%{"name" => "Hidden board"}, owner: stranger())
      card = fixture(fn -> card_fixture(hd(other.columns), %{"title" => "Hidden"}) end)
      {writer, _} = person(ctx, "write")
      as(writer)

      assert refused?(Wiki.pin(ctx.page, {:card, card}), :link_to_card, :user)
      assert {:ok, _} = Wiki.pin(ctx.page, {:card, ctx.card})
    end

    test "a reader of both is refused, named for the card", ctx do
      {reader, _} = person(ctx, "read")
      as(reader)
      assert refused?(Wiki.pin(ctx.page, {:card, ctx.card}), :pin_to_card, :user)
      assert refused?(Wiki.unlink(ctx.page, {:card, ctx.card}), :pin_to_card, :user)
      assert refused?(Wiki.pin(ctx.page, {:page, ctx.other}), :pin_page, :user)
    end
  end

  describe "asked of the person a call names, on the board the policy asks" do
    # A write token scoped to one board: the board the policy asks shows.
    defp scoped(user, board) do
      {_plain, token} =
        Accounts.create_api_token(user, "one board", scope: "write", scope_boards: [board.id])

      token
    end

    test "a move asks the board it leaves and the one it joins", ctx do
      target = board_fixture(%{"name" => "Target"}, owner: ctx.owner)

      as(ctx.owner, scoped(ctx.owner, target))

      assert refused?(
               Wiki.Move.to_board(ctx.page, target, nil, ctx.owner),
               :move_wiki_out,
               :token
             )

      as(ctx.owner, scoped(ctx.owner, ctx.root))
      assert refused?(Wiki.Move.to_board(ctx.page, target, nil, ctx.owner), :move_wiki_in, :token)
      assert Repo.get!(Wiki.Page, ctx.page.id).board_id == ctx.root.id

      as(ctx.owner)
      assert {:ok, moved} = Wiki.Move.to_board(ctx.page, target, nil, ctx.owner)
      assert moved.board_id == target.id
    end

    test "a folder's move asks both boards too", ctx do
      target = board_fixture(%{"name" => "Folder target"}, owner: ctx.owner)

      as(ctx.owner, scoped(ctx.owner, target))

      assert refused?(
               Wiki.FolderMove.to_board(ctx.folder, target, ctx.owner),
               :move_wiki_out,
               :token
             )

      as(ctx.owner, scoped(ctx.owner, ctx.root))

      assert refused?(
               Wiki.FolderMove.to_board(ctx.folder, target, ctx.owner),
               :move_wiki_in,
               :token
             )

      as(ctx.owner)
      assert {:ok, _} = Wiki.FolderMove.to_board(ctx.folder, target, ctx.owner)
    end

    test "a whole wiki's move asks both boards, as the person it names", ctx do
      target = board_fixture(%{"name" => "Wiki target"}, owner: ctx.owner)

      as(ctx.owner, scoped(ctx.owner, target))

      assert refused?(
               Wiki.WikiMove.run(ctx.owner, ctx.root, target, "Moved", dry_run: true),
               :move_wiki_out,
               :token
             )

      as(ctx.owner, scoped(ctx.owner, ctx.root))

      assert refused?(
               Wiki.WikiMove.run(ctx.owner, ctx.root, target, "Moved", dry_run: true),
               :move_wiki_in,
               :token
             )

      # The task's process is nobody: the person it names is asked.
      Actor.put(nil)
      Policy.forbid_nobody()

      assert {:ok, %{dry_run: true}} =
               Wiki.WikiMove.run(ctx.owner, ctx.root, target, "Moved", dry_run: true)
    end

    test "filing elsewhere asks the folder's board; taking it out, either end's", ctx do
      there = board_fixture(%{"name" => "There"}, owner: ctx.owner)
      {:ok, folder} = fixture(fn -> Wiki.create_folder(there, %{"name" => "Also"}) end)

      as(ctx.owner, scoped(ctx.owner, ctx.root))
      assert refused?(Placements.add(ctx.page, folder, ctx.owner), :file_also, :token)
      assert refused?(FolderPlacements.add(ctx.folder, folder, ctx.owner), :file_also, :token)

      as(ctx.owner)
      assert {:ok, _} = Placements.add(ctx.page, folder, ctx.owner)
      assert {:ok, _} = FolderPlacements.add(ctx.folder, folder, ctx.owner)

      # Out again: the page's board is enough, and so is the folder's.
      as(ctx.owner, scoped(ctx.owner, ctx.root))
      assert {:ok, _} = Placements.remove(ctx.page, folder, ctx.owner)
      assert {:ok, _} = FolderPlacements.remove(ctx.folder, folder, ctx.owner)

      as(ctx.owner)
      assert {:ok, _} = Placements.add(ctx.page, folder, ctx.owner)
      assert {:ok, _} = FolderPlacements.add(ctx.folder, folder, ctx.owner)
      # A token for neither end: refused, named as the token.
      as(ctx.owner, scoped(ctx.owner, board_fixture(%{"name" => "Neither"}, owner: ctx.owner)))
      assert refused?(Placements.remove(ctx.page, folder, ctx.owner), :file_also, :token)
      assert refused?(FolderPlacements.remove(ctx.folder, folder, ctx.owner), :file_also, :token)

      as(ctx.owner, scoped(ctx.owner, there))
      assert {:ok, _} = Placements.remove(ctx.page, folder, ctx.owner)
      assert {:ok, _} = FolderPlacements.remove(ctx.folder, folder, ctx.owner)
    end

    test "a folder made by its vault path asks where it is made", ctx do
      {reader, _} = person(ctx, "read")
      as(reader)

      assert refused?(
               Placements.folder_at(ctx.page, "/Policy wiki/New place", create: true),
               :create_wiki_item,
               :user
             )

      as(ctx.owner)
      assert {:ok, _} = Placements.folder_at(ctx.page, "/Policy wiki/New place", create: true)
    end

    test "sharing a page or folder asks the person sharing, a writer", ctx do
      {writer, _} = person(ctx, "write")
      token_writer = scoped(writer, board_fixture(%{}, owner: writer))
      as(writer, token_writer)

      assert refused?(
               Wiki.Sharing.share(writer, ctx.page, %{"email" => "share.a@example.com"}, "read"),
               :share_page,
               :token
             )

      assert refused?(
               Wiki.Sharing.share(
                 writer,
                 ctx.folder,
                 %{"email" => "share.a@example.com"},
                 "read"
               ),
               :share_folder,
               :token
             )

      as(writer)

      assert {:ok, _} =
               Wiki.Sharing.share(writer, ctx.page, %{"email" => "share.a@example.com"}, "read")

      as(writer, token_writer)

      assert refused?(
               Wiki.Sharing.unshare(writer, ctx.page, %{"email" => "share.a@example.com"}),
               :share_page,
               :token
             )

      as(writer)

      assert {:ok, _} =
               Wiki.Sharing.unshare(writer, ctx.page, %{"email" => "share.a@example.com"})
    end

    test "a Knowledge Base is the board's owner's, read from the row now", ctx do
      as(ctx.owner)
      stale = ctx.root
      Repo.update!(Ecto.Changeset.change(ctx.root, owner_id: stranger().id))

      assert refused?(Wiki.KnowledgeBase.adopt(ctx.owner, stale), :adopt_knowledge_base, :user)
      refute Repo.get!(Boards.Board, ctx.root.id).kind == "wiki"
    end
  end

  describe "a vault's own writes" do
    test "a sync writes as the person whose vault it is", ctx do
      vault = Vaults.root(ctx.owner)
      {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
      as(ctx.owner, token)

      assert refused?(
               Vaults.Sync.write_page(vault, ctx.owner, %{
                 "path" => "Policy wiki/Synced.md",
                 "content" => "x"
               }),
               :own_vault,
               :token
             )

      assert refused?(
               Vaults.Sync.archive_page(vault, ctx.owner, ctx.page.id, nil),
               :own_vault,
               :token
             )

      assert refused?(
               Vaults.Sync.archive_file(vault, ctx.owner, ctx.wfile.id, nil),
               :own_vault,
               :token
             )

      assert refused?(
               Vaults.Sync.purge_file(vault, ctx.owner, ctx.wfile.id, nil),
               :own_vault,
               :token
             )

      assert refused?(
               Vaults.Sync.move_file(vault, ctx.owner, ctx.wfile.id, %{
                 "path" => "Policy wiki/n.txt"
               }),
               :own_vault,
               :token
             )

      assert refused?(
               Vaults.Sync.write_file(
                 vault,
                 ctx.owner,
                 %{"path" => "Policy wiki/w.txt"},
                 ctx.source
               ),
               :own_vault,
               :token
             )

      refute Repo.get_by(Wiki.Page, title: "Synced")

      # Nobody acting on the process: the person named is who is asked.
      Actor.put(nil)

      assert {:ok, _} =
               Vaults.Sync.write_page(vault, ctx.owner, %{
                 "path" => "Policy wiki/Synced.md",
                 "content" => "x"
               })
    end

    test "a vault's settings are its person's", ctx do
      vault = Vaults.root(ctx.owner)
      as(stranger())
      assert refused?(Vaults.set_shortcut(vault, "zz"), :own_vault, :user)
      assert refused?(Vaults.set_recordings_folder(vault, ""), :own_vault, :user)
      as(ctx.owner)
      assert {:ok, _} = Vaults.set_recordings_folder(vault, "")
    end

    test "a draft's file and its throwing away are its person's", ctx do
      {:ok, draft} =
        fixture(fn ->
          Autosaves.save(ctx.owner, ctx.root, ctx.page, nil, %{"body" => "d"}, nil)
        end)

      as(stranger())
      assert refused?(Autosaves.discard(draft), :own_draft, :user)

      assert refused?(
               Autosaves.add_file(draft, ctx.owner, %{filename: "a.png"}, ctx.source),
               :own_draft,
               :user
             )

      assert refused?(Autosaves.adopt(draft, ctx.page, "body"), :own_draft, :user)
      assert Repo.get(Wiki.Autosave, draft.id)

      as(ctx.owner)
      assert :ok = Autosaves.discard(draft)
    end

    test "a quick note goes in the person's own vault", ctx do
      {_plain, token} = Accounts.create_api_token(ctx.owner, "reader", scope: "read")
      as(ctx.owner, token)
      assert refused?(Wiki.QuickNote.save(ctx.owner, "A thought"), :own_vault, :token)

      as(stranger())
      assert refused?(Wiki.QuickNote.save(ctx.owner, "A thought"), :own_vault, :user)
    end

    test "a connection to Google is the person's own", ctx do
      as(stranger())

      assert refused?(
               Slipdock.Google.connect(ctx.owner, "code", "https://example.com/cb"),
               :own_google,
               :user
             )
    end
  end
end
