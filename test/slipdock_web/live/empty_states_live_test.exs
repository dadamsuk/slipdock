defmodule SlipdockWeb.EmptyStatesLiveTest do
  @moduledoc """
  Every page and section that can be empty shows `empty_state/1` (#1715),
  in the variant that fits where it sits, with the next step as its action
  where there is one: Create group, Create token, Add a passkey, Publish a
  Tool. And once there is something to show, the empty state goes.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.ToolPackages
  import Ecto.Query

  alias Slipdock.{Accounts, Boards, Repo, Settings, Tools}

  defp empty(view, id, variant, heading) do
    heading_tag = if variant == "compact", do: "h3", else: "h2"
    has_element?(view, "##{id}[data-empty-state=#{variant}] #{heading_tag}", heading)
  end

  defp action(id), do: "##{id} [data-role=empty-state-action]"

  # A session-only sign-in: ConnCase's own conn carries an API token, so
  # its user is never without one.
  defp fresh_conn(local) do
    user = user_fixture("#{local}@example.com")
    {log_in_user(build_conn(), user), user}
  end

  describe "Favourites" do
    test "with nothing favourited: the full empty state, in rose, with no action", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/favourites")
      assert empty(view, "favourites-empty", "full", "Nothing favourited yet")
      assert has_element?(view, "#favourites-empty span.bg-rose-500\\/10 .hero-heart")
      refute has_element?(view, action("favourites-empty"))
    end

    test "a favourite replaces it", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)
      {:ok, _} = Slipdock.Favourites.toggle(user, :board, board.id)
      {:ok, view, _} = live(conn, ~p"/favourites")
      refute has_element?(view, "#favourites-empty")
    end
  end

  describe "Tidy up" do
    test "nothing to tidy: the full empty state, and a writer may look the board over", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(%{}, owner: user)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/tidy")
      assert empty(view, "garden-empty", "full", "Nothing to tidy")
      assert has_element?(view, "#{action("garden-empty")} #garden-empty-run")
    end
  end

  describe "Tools" do
    setup do
      Slipdock.TestConfig.own_uploads_dir()
      :ok
    end

    test "all three sections empty: each a compact empty state; Yours offers Publish a Tool" do
      {conn, _} = fresh_conn("toolless")
      {:ok, view, _} = live(conn, ~p"/tools")

      assert empty(view, "tools-yours-empty", "compact", "No Tools of yours yet")
      assert empty(view, "tools-shared-empty", "compact", "Nothing shared with you")
      assert empty(view, "tools-listed-empty", "compact", "None listed on this server")

      # The action is the publish form's own file picker.
      [input_id] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#tools-publish-form input[type=file]")
        |> LazyHTML.attribute("id")

      assert has_element?(
               view,
               "#{action("tools-yours-empty")} label[for='#{input_id}']",
               "Publish a Tool"
             )

      refute has_element?(view, action("tools-shared-empty"))
      refute has_element?(view, action("tools-listed-empty"))
    end

    test "a Tool of your own and one shared with you replace their empty states" do
      {conn, me} = fresh_conn("toolful")
      {:ok, _} = Tools.publish(me, package(unique_name()))
      friend = user_fixture("tool-sharer@example.com")
      {:ok, version} = Tools.publish(friend, package(unique_name()))
      {:ok, _} = Tools.share(friend, version.tool, me)

      {:ok, view, _} = live(conn, ~p"/tools")
      refute has_element?(view, "#tools-yours-empty")
      refute has_element?(view, "#tools-shared-empty")
      assert has_element?(view, "#tools-listed-empty")
    end

    test "the admin's listings: nothing waiting and nothing listed", %{conn: conn} do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => fixture_email("admin@example.com")})
      {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
      {:ok, view, _} = live(log_in_user(conn, admin), ~p"/admin/tools")

      assert empty(view, "listing-queue-empty", "compact", "Nothing waiting")
      assert empty(view, "listing-listed-empty", "compact", "Nothing listed")
    end
  end

  describe "Groups" do
    test "in no groups: the full empty state, whose Create group goes to the name" do
      {conn, _} = fresh_conn("groupless")
      {:ok, view, _} = live(conn, ~p"/groups")

      assert empty(view, "groups-empty", "full", "No groups yet")

      assert has_element?(
               view,
               "#{action("groups-empty")} label[for=new-group-name]",
               "Create group"
             )

      assert has_element?(view, "form[phx-submit=create] input#new-group-name[name=name]")
    end

    test "creating a group replaces it" do
      {conn, _} = fresh_conn("grouper")
      {:ok, view, _} = live(conn, ~p"/groups")

      view |> element("form[phx-submit=create]") |> render_submit(%{"name" => "Design"})
      refute has_element?(view, "#groups-empty")
      assert render(view) =~ "Design"
    end
  end

  describe "API tokens" do
    test "with none: a compact empty state whose Create token submits the form" do
      {conn, user} = fresh_conn("tokenless")
      assert Accounts.list_api_tokens(user) == []
      {:ok, view, _} = live(conn, ~p"/account/tokens")

      assert empty(view, "tokens-empty", "compact", "No tokens yet")

      assert has_element?(
               view,
               "#{action("tokens-empty")} button[type=submit][form=token-form-0]",
               "Create token"
             )

      assert has_element?(view, "form#token-form-0[phx-submit=create_token]")

      # What that button submits: the form, which mints the token.
      view |> element("#token-form-0") |> render_submit(%{"label" => ""})
      assert has_element?(view, "#new-token")
      refute has_element?(view, "#tokens-empty")
      assert [%{label: "CLI"}] = Accounts.list_api_tokens(user)

      # The form was remade with a new id; the action follows it.
      assert has_element?(view, "form#token-form-1")
    end

    test "after revoking the last, it comes back pointing at the current form" do
      {conn, user} = fresh_conn("revoker")
      {_, _} = Accounts.create_api_token(user, "laptop")
      {:ok, view, _} = live(conn, ~p"/account/tokens")
      refute has_element?(view, "#tokens-empty")

      [token] = Accounts.list_api_tokens(user)
      view |> element("#token-#{token.id} button", "Revoke") |> render_click()
      assert has_element?(view, "#tokens-empty button[form=token-form-0]")
    end
  end

  describe "Passkeys" do
    test "with none: a compact empty state; Add a passkey only where the browser can", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/account")
      assert empty(view, "passkeys-empty", "compact", "No passkeys yet")
      # Not known yet whether the browser can make one: no action.
      refute has_element?(view, action("passkeys-empty"))

      view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => false})
      refute has_element?(view, action("passkeys-empty"))

      view |> element("#passkeys") |> render_hook("passkey_support", %{"supported" => true})

      assert has_element?(
               view,
               "#{action("passkeys-empty")} button[type=submit][form=passkey-add-form]",
               "Add a passkey"
             )

      assert has_element?(view, "form#passkey-add-form[data-passkey-add]")
    end
  end

  describe "board Activity" do
    test "nothing logged: a compact empty state in the modal; an entry replaces it", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(%{}, owner: user)
      Repo.delete_all(from a in Boards.Activity, where: a.board_id == ^board.id)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/activity")
      assert empty(view, "activity-empty", "compact", "Nothing has happened yet")
      refute has_element?(view, action("activity-empty"))

      Boards.log_activity(board.id, nil, "card_created", "Added “Write it up”")
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/activity")
      refute has_element?(view, "#activity-empty")
      assert render(view) =~ "Write it up"
    end
  end

  describe "wiki history" do
    test "a page with no versions: the full empty state, and no compare form chrome", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(%{}, owner: user)
      page = page_fixture(board, %{"title" => "Quiet page"}, user: user)
      Repo.delete_all(from r in Slipdock.Wiki.Revision, where: r.page_id == ^page.id)

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")
      assert empty(view, "history-empty", "full", "No versions yet")
      refute has_element?(view, "#compare-form ul")
    end

    test "a page with a version lists it instead", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)
      page = page_fixture(board, %{"title" => "Busy page"}, user: user)
      assert Slipdock.Wiki.list_revisions(page) != []

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki/#{page.slug}/history")
      refute has_element?(view, "#history-empty")
      assert has_element?(view, "#compare-form ul li")
    end
  end

  describe "sign-ups" do
    setup %{conn: conn} do
      {:ok, _} = Settings.complete_setup(%{"admin_email" => fixture_email("admin@example.com")})
      {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
      %{conn: log_in_user(conn, admin)}
    end

    test "nobody waiting: a compact empty state with no action", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/users/signups")
      assert empty(view, "signups-empty", "compact", "Nobody is waiting")
      refute has_element?(view, action("signups-empty"))
    end

    test "a request replaces it", %{conn: conn} do
      {:ok, _} =
        Settings.update(%{
          "smtp_host" => "smtp.example.com",
          "smtp_from_email" => fixture_email("mail@example.com"),
          "signup_mode" => :approval
        })

      {:ok, _} = Accounts.request_signup(fixture_email("hopeful@example.com"), note: "Design")
      {:ok, view, _} = live(conn, ~p"/users/signups")
      refute has_element?(view, "#signups-empty")
      assert render(view) =~ fixture_email("hopeful@example.com")
    end
  end

  describe "the wiki" do
    test "no pages: the full empty state; a writer may write the first one", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(%{}, owner: user)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert empty(view, "wiki-empty", "full", "No pages yet")

      assert has_element?(
               view,
               ~s|#{action("wiki-empty")} a[href="/boards/#{board.id}/wiki/new"]|,
               "Write the first one"
             )
    end

    test "a reader sees it with no action" do
      owner = user_fixture("wiki-owner@example.com")
      board = board_fixture(%{}, owner: owner)
      {conn, reader} = fresh_conn("wiki-reader")
      share_fixture(board, [reader], "read")
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
      assert empty(view, "wiki-empty", "full", "No pages yet")
      refute has_element?(view, action("wiki-empty"))
    end

    test "a page replaces it", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)
      page_fixture(board)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/wiki")
      refute has_element?(view, "#wiki-empty")
    end
  end

  describe "Templates" do
    # The built-ins are seeded by a migration, so only a server without them
    # (and a user with none of their own) ever sees it.
    test "none: the full empty state, with no action (the form is above it)", %{conn: conn} do
      Repo.delete_all(from(t in Slipdock.Boards.Template, where: t.system))
      {:ok, view, _} = live(conn, ~p"/templates")
      assert empty(view, "templates-empty", "full", "No templates yet")
      refute has_element?(view, action("templates-empty"))
    end

    test "a template replaces it", %{conn: conn, user: user} do
      {:ok, _} = Boards.create_template(user, %{"name" => "Mine", "columns" => ["A"]})
      {:ok, view, _} = live(conn, ~p"/templates")
      refute has_element?(view, "#templates-empty")
    end
  end

  describe "Automations" do
    test "no rules: a compact empty state in the modal", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      assert empty(view, "rules-empty", "compact", "No rules yet")
      refute has_element?(view, action("rules-empty"))
    end

    test "a rule replaces it", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)

      rule_fixture(board, %{
        "trigger" => %{"type" => "card_created"},
        "actions" => [%{"type" => "add_flags", "flags" => ["review"]}]
      })

      {:ok, view, _} = live(conn, ~p"/boards/#{board}/automations")
      refute has_element?(view, "#rules-empty")
    end
  end

  describe "Visualise" do
    test "an empty board: aging, work mix and runners are compact empty states", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(%{}, owner: user)
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

      assert empty(view, "aging-empty", "compact", "Nothing in progress")
      assert empty(view, "mix-empty", "compact", "No tags yet")
      assert empty(view, "runners-empty", "compact", "No runners")
      refute has_element?(view, action("aging-empty"))
      refute has_element?(view, action("mix-empty"))

      assert has_element?(
               view,
               ~s|#{action("runners-empty")} a[href="/boards/#{board.id}/automations"]|,
               "Set one up in Automations"
             )

      refute has_element?(view, "#jobs-empty")
    end

    test "a runner with no jobs: Recent jobs is a compact empty state", %{conn: conn, user: user} do
      board = board_fixture(%{}, owner: user)
      {:ok, _, _} = Slipdock.Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
      {:ok, view, _} = live(conn, ~p"/boards/#{board}/visualise")

      refute has_element?(view, "#runners-empty")
      assert empty(view, "jobs-empty", "compact", "No jobs yet")
      refute has_element?(view, "#recent-jobs")
    end
  end
end
