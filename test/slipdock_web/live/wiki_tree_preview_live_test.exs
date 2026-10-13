defmodule SlipdockWeb.WikiTreePreviewLiveTest do
  @moduledoc """
  A page's preview in the wiki's tree (#760): the WikiTree hook asks
  `tree_preview` for a page row the mouse rests on, and gets what the card
  beside the tree shows — only for a page this tree would show this reader.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  import Ecto.Query, only: [where: 2]

  alias Slipdock.{Repo, Vaults, Wiki}

  setup %{user: user} do
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kbpv"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobspv"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})

    body = """
    # Plans

    The first **paragraph**, with a [link](https://example.com).

    ```elixir
    IO.puts("never shown")

    still code
    ```

    The second paragraph.
    """

    home = page_fixture(kb, %{"title" => "Home", "body" => body}, user: user)
    page_fixture(kb, %{"title" => "Under home", "parent_id" => home.id}, user: user)
    %{kb: kb, jobs: jobs, home: home}
  end

  defp preview(view, key) do
    render_hook(view, "tree_preview", %{"key" => key})
    assert_reply(view, reply)
    reply
  end

  test "a page of this board: its title, its body as plain paragraphs, who changed it", %{
    conn: conn,
    user: user,
    kb: kb,
    home: home
  } do
    Repo.update_all(where(Wiki.Page, id: ^home.id), set: [note_tags: ["plans"]])
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    reply = preview(view, "page:#{home.id}")
    assert reply.found
    assert reply.key == "page:#{home.id}"
    assert reply.title == "Home"
    assert reply.board == nil
    assert reply.summary == nil
    assert reply.code == home.code

    assert reply.paragraphs == [
             "Plans",
             "The first paragraph, with a link.",
             "The second paragraph."
           ]

    assert reply.tags == ["plans"]
    assert reply.children == 1
    assert reply.updated == "just now"
    assert reply.updated_by == Slipdock.Accounts.User.display_name(user)
    refute reply.draft or reply.archived or reply.template
  end

  test "a page on another board of the vault says which board", %{
    conn: conn,
    user: user,
    kb: kb,
    jobs: jobs
  } do
    call =
      page_fixture(jobs, %{"title" => "Call notes", "summary" => "Acme, Tuesday"}, user: user)

    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    reply = preview(view, "page:#{call.id}")
    assert reply.found
    assert reply.board == "Job Hunt"
    assert reply.summary == "Acme, Tuesday"
  end

  test "nothing for a page outside this tree, or one the reader can't read", %{
    conn: conn,
    user: user,
    kb: kb
  } do
    mine = board_fixture(%{"name" => "Loose"}, owner: user)
    loose = page_fixture(mine, %{"title" => "Loose page"}, user: user)
    stranger = user_fixture("stranger@example.com")
    theirs = board_fixture(%{"name" => "Private"}, owner: stranger)
    secret = page_fixture(theirs, %{"title" => "Secret"}, user: stranger)
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    assert preview(view, "page:#{loose.id}") == %{found: false}
    assert preview(view, "page:#{secret.id}") == %{found: false}
  end

  test "a reader sees no draft's preview; a writer does, marked", %{
    conn: conn,
    kb: kb,
    user: user
  } do
    draft = page_fixture(kb, %{"title" => "Half done", "status" => "draft"}, user: user)

    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    assert %{found: true, draft: true} = preview(view, "page:#{draft.id}")

    reader = user_fixture("reader@example.com")
    share_fixture(kb, reader, "read")
    {:ok, view, _html} = live(log_in_user(build_conn(), reader), ~p"/boards/#{kb}/wiki")
    assert preview(view, "page:#{draft.id}") == %{found: false}
  end

  test "an archived page, a folder, a missing page or a bad key previews nothing", %{
    conn: conn,
    kb: kb,
    user: user
  } do
    {:ok, gone} = Wiki.archive_page(page_fixture(kb, %{"title" => "Gone"}, user: user))
    {:ok, folder} = Wiki.create_folder(kb, %{"name" => "Archive"})
    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")

    for key <- ["page:#{gone.id}", "folder:#{folder.id}", "page:999999999", "page:x", "root"],
        do: assert(preview(view, key) == %{found: false}, key)

    render_hook(view, "tree_preview", %{})
    assert_reply(view, %{found: false})
  end

  test "an encrypted block shows as a lock, never its ciphertext", %{
    conn: conn,
    kb: kb,
    user: user
  } do
    cipher = "%%🔐β " <> String.duplicate("QUJD", 30) <> " 🔐%%"

    page =
      page_fixture(kb, %{"title" => "Keys", "body" => "Wifi: #{cipher}\n\nPlain."}, user: user)

    {:ok, view, _html} = live(conn, ~p"/boards/#{kb}/wiki")
    reply = preview(view, "page:#{page.id}")
    refute Enum.any?(reply.paragraphs, &(&1 =~ "QUJD"))
    assert List.last(reply.paragraphs) == "Plain."
  end
end
