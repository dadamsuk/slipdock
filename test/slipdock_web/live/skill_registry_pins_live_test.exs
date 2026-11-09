defmodule SlipdockWeb.SkillRegistryPinsLiveTest do
  @moduledoc """
  An entry on boards, on the registry page (#2062): enabling it pinned to
  the text shown, a refresh that changes it shown as changed upstream with
  its diff and a re-pin, disabling, a reader who may do none of it, and the
  Playbook stages that name a skill, flagged when neither enabled nor
  shipped.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Access, Handbook, SkillRegistry, SkillRegistryStub, Wiki}

  @repo "https://github.com/octo/skills"

  defp skill(name, body \\ "Ask one question at a time.") do
    "---\nname: #{name}\ndescription: Asks.\n---\n\n#{body}\n"
  end

  defp serve(body),
    do:
      SkillRegistryStub.put("octo/skills", %{
        files: %{"grilling/SKILL.md" => skill("grilling", body)}
      })

  setup %{user: user} do
    SkillRegistryStub.start(%{})
    serve("Ask one question at a time.")
    {:ok, %{entries: [entry]} = source} = SkillRegistry.add_source(user, @repo)
    board = board_fixture(%{"name" => "Plans"}, owner: user)
    %{source: source, entry: entry, board: board}
  end

  defp enable_on(view, board) do
    view |> form("#skill-enable-form", %{board_id: board.id}) |> render_submit()
  end

  test "enabling pins the text shown, and the board is no longer offered", %{
    conn: conn,
    entry: entry,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/skills/entries/#{entry.id}")
    assert has_element?(view, "#skill-entry-boards-empty")
    assert has_element?(view, "#skill-entry-stages-empty", "No stage names it")
    assert has_element?(view, "#skill-enable-board option", "Plans")

    enable_on(view, board)

    assert has_element?(view, "#skill-entry-notice", "Enabled grilling on Plans")
    [enablement] = SkillRegistry.enabled(board)
    assert enablement.pinned_hash == entry.content_hash
    assert has_element?(view, "#skill-enabled-#{enablement.id}", "Plans")
    refute has_element?(view, "#skill-enabled-#{enablement.id}-changed")
    refute has_element?(view, "#skill-enable-form")
  end

  test "a page left open while the entry was refreshed can't pin the newer text", %{
    conn: conn,
    user: user,
    source: source,
    entry: entry,
    board: board
  } do
    {:ok, view, _html} = live(conn, ~p"/skills/entries/#{entry.id}")
    serve("Ask them all at once.")
    {:ok, _, _} = SkillRegistry.refresh_source(user, source)

    # The form still carries the hash of the text this page showed.
    view
    |> form("#skill-enable-form", %{board_id: board.id})
    |> render_submit(%{hash: entry.content_hash})

    assert has_element?(view, "#skill-entry-notice", "has changed since you read it")
    assert SkillRegistry.enabled(board) == []
  end

  test "a changed refresh shows the diff, and a re-pin takes the new text", %{
    conn: conn,
    user: user,
    source: source,
    entry: entry,
    board: board
  } do
    {:ok, e} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)
    serve("Ask them all at once.")
    {:ok, _, _} = SkillRegistry.refresh_source(user, source)

    {:ok, view, _html} = live(conn, ~p"/skills/entries/#{entry.id}")
    assert has_element?(view, "#skill-enabled-#{e.id}-changed", "Changed upstream")
    assert has_element?(view, "#skill-enabled-#{e.id}-diff", "− Ask one question at a time.")
    assert has_element?(view, "#skill-enabled-#{e.id}-diff", "+ Ask them all at once.")
    # Still the pinned text on the board until re-pinned.
    assert SkillRegistry.get_enabled(board, "grilling").pinned_body =~ "one question"

    view |> element("#skill-enabled-#{e.id}-repin") |> render_click()

    assert has_element?(view, "#skill-entry-notice", "Re-pinned grilling on Plans")
    refute has_element?(view, "#skill-enabled-#{e.id}-changed")
    assert SkillRegistry.get_enabled(board, "grilling").pinned_body =~ "all at once"
  end

  test "disabling takes it off the board", %{conn: conn, user: user, entry: entry, board: board} do
    {:ok, e} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)
    {:ok, view, _html} = live(conn, ~p"/skills/entries/#{entry.id}")

    view |> element("#skill-enabled-#{e.id}-disable") |> render_click()

    assert has_element?(view, "#skill-entry-notice", "Disabled grilling on Plans.")
    assert SkillRegistry.enabled(board) == []
    assert has_element?(view, "#skill-enable-board option", "Plans")
  end

  test "a reader sees where it is enabled, with no buttons, and can't change it", %{
    user: user,
    entry: entry,
    board: board
  } do
    {:ok, e} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)
    reader = user_fixture("pins-live-reader@example.com")
    {:ok, _} = Access.grant(board, reader, "read", user)
    # A seed, so the reader can open an entry page at all.
    SkillRegistryStub.put("octo/seed", %{files: %{"s/SKILL.md" => skill("grilling")}})
    {:ok, %{entries: [seed]}} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")

    {:ok, view, _html} = live(log_in_user(build_conn(), reader), ~p"/skills/entries/#{seed.id}")
    # No board of theirs to enable it on.
    refute has_element?(view, "#skill-enable-form")

    render_click(view, "disable", %{"id" => e.id})
    assert has_element?(view, "#skill-entry-notice", "Only somebody who can write to Plans")
    assert [_] = SkillRegistry.enabled(board)

    render_click(view, "repin", %{"id" => e.id, "hash" => entry.content_hash})
    assert has_element?(view, "#skill-entry-notice", "Only somebody who can write to Plans")

    render_click(view, "enable", %{"board_id" => board.id, "hash" => seed.content_hash})
    assert has_element?(view, "#skill-entry-notice", "Pick a board you can write to.")

    render_click(view, "disable", %{"id" => "nope"})
    assert has_element?(view, "#skill-entry-notice", "no longer enabled there")
  end

  test "somebody who can't read the board learns nothing from a guessed id", %{
    user: user,
    entry: entry,
    board: board
  } do
    {:ok, e} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)
    outsider = user_fixture("pins-live-outsider@example.com")
    SkillRegistryStub.put("octo/seed", %{files: %{"s/SKILL.md" => skill("grilling")}})
    {:ok, %{entries: [seed]}} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")

    {:ok, view, _html} = live(log_in_user(build_conn(), outsider), ~p"/skills/entries/#{seed.id}")

    for event <- ["disable", "repin"] do
      render_click(view, event, %{"id" => e.id, "hash" => entry.content_hash})
      notice = view |> element("#skill-entry-notice") |> render()
      assert notice =~ "That skill is no longer enabled there."
      refute notice =~ "Plans"
    end

    assert [%{pinned_hash: hash}] = SkillRegistry.enabled(board)
    assert hash == entry.content_hash
  end

  describe "the stages that name a skill" do
    setup %{user: user, board: board} do
      {:ok, _} = Handbook.install(user, board)
      playbook = Enum.find(Handbook.find(board).pages, &(Handbook.key(&1) == "playbook"))

      body =
        String.replace(
          playbook.body,
          "## Spike\n",
          "- skill: grilling\n- skill: nowhere\n\n## Spike\n"
        )

      {:ok, _} = Wiki.update_page(playbook, %{"body" => body}, user: user)
      :ok
    end

    test "the list shows each board's stages, flagging what nothing provides", %{
      conn: conn,
      user: user,
      entry: entry,
      board: board
    } do
      {:ok, view, _html} = live(conn, ~p"/skills")
      grill = "#skills-stage-#{board.id}-grill-grilling"
      nowhere = "#skills-stage-#{board.id}-grill-nowhere"

      assert has_element?(view, "#skills-stages-board-#{board.id}", "Plans")
      assert has_element?(view, "#{grill} [data-flagged]")
      assert has_element?(view, "#{nowhere} [data-flagged]", "not a skill Slipdock ships")

      {:ok, _} = SkillRegistry.enable(user, board, entry.id, entry.content_hash)
      {:ok, view, _html} = live(conn, ~p"/skills")

      assert has_element?(view, grill, "enabled, from octo/skills")
      refute has_element?(view, "#{grill} [data-flagged]")
      assert has_element?(view, "#{nowhere} [data-flagged]")
    end

    test "the entry's page lists the stages naming it", %{conn: conn, entry: entry} do
      {:ok, view, _html} = live(conn, ~p"/skills/entries/#{entry.id}")
      assert has_element?(view, "#skill-entry-stages", "Plans · Grill")
      assert has_element?(view, "#skill-entry-stages", "not enabled there")
    end

    test "with no Playbook naming one, says so", %{user: user} do
      other = user_fixture("pins-live-other@example.com")
      {:ok, view, _html} = live(log_in_user(build_conn(), other), ~p"/skills")
      assert has_element?(view, "#skills-stages-empty")
      assert user.id != other.id
    end
  end

  test "help says how enabling and re-pinning work", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/help/tools")
    assert has_element?(view, "#tools-skills-enable", "Enable this text")
    assert has_element?(view, "#tools-skills-enable", "re-pins it")
  end
end
