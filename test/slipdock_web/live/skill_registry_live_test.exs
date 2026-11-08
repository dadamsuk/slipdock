defmodule SlipdockWeb.SkillRegistryLiveTest do
  @moduledoc """
  The skills registry page (#2061): adding a source by URL, its entries and
  their metadata, an entry's full text, refreshing and removing, and every
  refusal from the fetch shown as its sentence. GitHub is
  `Slipdock.SkillRegistryStub`; nothing leaves the machine.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Repo, SkillRegistry, SkillRegistryStub, TestConfig}
  alias Slipdock.SkillRegistry.Source
  alias SlipdockWeb.SkillRegistryLive.Index

  @repo "https://github.com/octo/skills"

  defp skill(name, description \\ "Does a thing.", body \\ "Steps.") do
    "---\nname: #{name}\ndescription: #{description}\n---\n\n#{body}\n"
  end

  defp octo(files), do: %{files: files, licence: "MIT"}

  defp add(view, url) do
    view |> form("#skills-add-form", %{url: url}) |> render_submit()
    render_async(view)
  end

  describe "the page" do
    test "with nothing added says how to start, and the menu marks it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills")

      assert has_element?(view, "#skills-yours-empty", "No sources of yours yet")
      assert has_element?(view, "#skills-seeds-empty")
      assert has_element?(view, "#account-menu a[href='/skills'][aria-current=page]", "Skills")
    end
  end

  describe "adding a source" do
    test "fetches it and lists each entry with its metadata", %{conn: conn, user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{
            "grilling/SKILL.md" => skill("grilling", "Asks hard questions."),
            "tdd/SKILL.md" => skill("tdd", "Red, green, refactor."),
            "skip/SKILL.md" => "---\ndescription: no name\n---\nBody"
          })
      })

      {:ok, view, _html} = live(conn, ~p"/skills")
      html = add(view, @repo)

      assert html =~ "Added octo/skills: 2 skills."
      [source] = SkillRegistry.list_sources(user)
      [grilling, tdd] = source.entries

      assert has_element?(view, "#skill-source-#{source.id}", "octo/skills")
      assert has_element?(view, "#skill-source-#{source.id}", "Licence MIT")
      assert has_element?(view, "#skill-source-#{source.id}", "0123456")
      assert has_element?(view, "#skill-entry-#{grilling.id}", "Asks hard questions.")
      assert has_element?(view, "#skill-entry-#{grilling.id}", "grilling/SKILL.md")
      assert has_element?(view, "#skill-entry-#{tdd.id}", "tdd")

      # What the fetch skipped is said under the source.
      assert has_element?(
               view,
               "#skill-source-#{source.id}-report",
               "skip/SKILL.md has no name in its front matter, so it was skipped."
             )

      # And the field is emptied for the next one.
      assert has_element?(view, "#skills-add-url[value='']")
    end

    test "a refused address is its sentence, and nothing is stored", %{conn: conn, user: user} do
      SkillRegistryStub.start(%{})
      {:ok, view, _html} = live(conn, ~p"/skills")

      add(view, "https://intranet.test/SKILL.md")

      assert has_element?(
               view,
               "#skills-add-error",
               "https://intranet.test/SKILL.md is not a public address."
             )

      # The URL stays in the field to be corrected.
      assert has_element?(view, "#skills-add-url[value='https://intranet.test/SKILL.md']")
      assert SkillRegistry.list_sources(user) == []
      assert SkillRegistryStub.requests() == []
    end

    test "a file over the size limit is refused", %{conn: conn} do
      SkillRegistryStub.start(%{
        "/big/SKILL.md" => skill("big", "x", String.duplicate("a", 5000))
      })

      TestConfig.merge(:skill_registry, max_file_bytes: 1000)
      {:ok, view, _html} = live(conn, ~p"/skills")

      add(view, "https://skills.example.com/big/SKILL.md")

      assert has_element?(
               view,
               "#skills-add-error",
               "https://skills.example.com/big/SKILL.md is larger than 1 KB."
             )
    end

    test "a repository with no skill and no README is refused", %{conn: conn} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"lib/x.ex" => "code"})})
      {:ok, view, _html} = live(conn, ~p"/skills")

      add(view, @repo)

      assert has_element?(view, "#skills-add-error", "#{@repo} has no SKILL.md and no README.")
      assert Repo.aggregate(Source, :count) == 0
    end

    test "a URL that is not a source, or one already added, is its sentence", %{conn: conn} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})
      {:ok, view, _html} = live(conn, ~p"/skills")

      add(view, "https://example.com/page.html")

      assert has_element?(
               view,
               "#skills-add-error",
               "is not a GitHub repository or a SKILL.md URL"
             )

      add(view, @repo)
      refute has_element?(view, "#skills-add-error")

      add(view, @repo)
      assert has_element?(view, "#skills-add-error", "#{@repo} is already one of your sources.")
    end
  end

  describe "an entry" do
    test "shows its whole text and its metadata", %{conn: conn, user: user} do
      body = skill("grilling", "Asks hard questions.", "1. Ask <why>.\n2. Ask again.")
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"grilling/SKILL.md" => body})})
      {:ok, %{entries: [entry]}} = SkillRegistry.add_source(user, @repo)

      {:ok, view, _html} = live(conn, ~p"/skills/entries/#{entry.id}")

      assert has_element?(view, "h1", "grilling")
      assert has_element?(view, "#page-header", "Asks hard questions.")
      assert has_element?(view, "#skill-entry-meta", "octo/skills")
      assert has_element?(view, "#skill-entry-meta", "grilling/SKILL.md")
      assert has_element?(view, "#skill-entry-meta", "0123456")
      assert has_element?(view, "#skill-entry-meta", "MIT")
      # The file as fetched, front matter and all, escaped rather than rendered.
      assert view |> element("#skill-entry-body") |> render() =~ "name: grilling"
      assert view |> element("#skill-entry-body") |> render() =~ "1. Ask &lt;why&gt;."
    end

    test "is reached from the list", %{conn: conn, user: user} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})
      {:ok, %{entries: [entry]}} = SkillRegistry.add_source(user, @repo)
      {:ok, view, _html} = live(conn, ~p"/skills")

      {:ok, _view, html} =
        view
        |> element("#skill-entry-#{entry.id} a", "a")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "skill-entry-body"
    end

    test "somebody else's is not shown", %{conn: conn} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})

      {:ok, %{entries: [entry]}} =
        SkillRegistry.add_source(user_fixture("skills-other@example.com"), @repo)

      assert {:error, {:live_redirect, %{to: "/skills", flash: flash}}} =
               live(conn, ~p"/skills/entries/#{entry.id}")

      assert flash["error"] =~ "isn't one you can see"
    end
  end

  describe "refreshing" do
    setup %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"a/SKILL.md" => skill("a"), "b/SKILL.md" => skill("b")})
      })

      {:ok, source} = SkillRegistry.add_source(user, @repo)
      %{source: source}
    end

    test "says what changed", %{conn: conn, source: source} do
      SkillRegistryStub.put(
        "octo/skills",
        octo(%{"a/SKILL.md" => skill("a", "Now different."), "c/SKILL.md" => skill("c")})
      )

      {:ok, view, _html} = live(conn, ~p"/skills")
      view |> element("#skill-source-#{source.id}-refresh") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#skills-notice",
               "Refreshed octo/skills: added c; changed a; removed b."
             )

      assert has_element?(view, "#skill-source-#{source.id}", "Now different.")
      refute has_element?(view, "#skill-source-#{source.id}", "b/SKILL.md")
    end

    test "with nothing new says so", %{conn: conn, source: source} do
      {:ok, view, _html} = live(conn, ~p"/skills")
      view |> element("#skill-source-#{source.id}-refresh") |> render_click()
      render_async(view)

      assert has_element?(view, "#skills-notice", "Refreshed octo/skills: nothing changed.")
    end

    test "a failed fetch is its sentence and keeps the entries", %{conn: conn, source: source} do
      SkillRegistryStub.put("octo/skills", octo(%{"lib/x.ex" => "code"}))

      {:ok, view, _html} = live(conn, ~p"/skills")
      view |> element("#skill-source-#{source.id}-refresh") |> render_click()
      render_async(view)

      assert has_element?(view, "#skills-notice", "has no SKILL.md and no README.")
      assert has_element?(view, "#skill-source-#{source.id}", "a/SKILL.md")
      assert has_element?(view, "#skill-source-#{source.id}", "b/SKILL.md")
    end

    test "a source that has gone is said", %{conn: conn, user: user, source: source} do
      {:ok, view, _html} = live(conn, ~p"/skills")
      {:ok, _} = SkillRegistry.remove_source(user, source)

      view |> element("#skill-source-#{source.id}-refresh") |> render_click()
      assert has_element?(view, "#skills-notice", "That source has gone.")
      refute has_element?(view, "#skill-source-#{source.id}")
    end
  end

  describe "removing" do
    test "deletes the source and its entries", %{conn: conn, user: user} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})
      {:ok, source} = SkillRegistry.add_source(user, @repo)

      {:ok, view, _html} = live(conn, ~p"/skills")
      view |> element("#skill-source-#{source.id}-remove") |> render_click()

      assert has_element?(view, "#skills-notice", "Removed octo/skills and its skills.")
      refute has_element?(view, "#skill-source-#{source.id}")
      assert has_element?(view, "#skills-yours-empty")
      assert SkillRegistry.list_sources(user) == []
    end
  end

  describe "seeds and other people's sources" do
    setup do
      SkillRegistryStub.start(%{
        "octo/seed" => octo(%{"s/SKILL.md" => skill("s")}),
        "octo/theirs" => octo(%{"t/SKILL.md" => skill("t")})
      })

      {:ok, seed} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")

      {:ok, theirs} =
        SkillRegistry.add_source(
          user_fixture("skills-other@example.com"),
          "https://github.com/octo/theirs"
        )

      %{seed: seed, theirs: theirs}
    end

    test "a seed shows to everyone, without buttons; another's source not at all",
         %{conn: conn, seed: seed, theirs: theirs} do
      {:ok, view, _html} = live(conn, ~p"/skills")

      assert has_element?(view, "#skills-seeds #skill-source-#{seed.id}", "octo/seed")
      refute has_element?(view, "#skill-source-#{seed.id}-refresh")
      refute has_element?(view, "#skill-source-#{seed.id}-remove")
      refute has_element?(view, "#skill-source-#{theirs.id}")
    end

    test "a forged remove of a seed is refused", %{conn: conn, seed: seed} do
      {:ok, view, _html} = live(conn, ~p"/skills")

      render_click(view, "remove", %{"id" => seed.id})

      assert has_element?(view, "#skills-notice", "Only whoever added octo/seed can change it.")
      assert Repo.get(Source, seed.id)
    end

    test "an admin refreshes and removes a seed", %{seed: seed} do
      admin = user_fixture("skills-admin@example.com")
      {:ok, admin} = admin |> Ecto.Changeset.change(admin: true) |> Repo.update()

      {:ok, view, _html} = live(log_in_user(build_conn(), admin), ~p"/skills")
      assert has_element?(view, "#skill-source-#{seed.id}-refresh")

      view |> element("#skill-source-#{seed.id}-remove") |> render_click()
      refute Repo.get(Source, seed.id)
    end
  end

  describe "adding a seed (#2075)" do
    test "an admin ticks the box and the source is everyone's", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"grilling/SKILL.md" => skill("grilling")})
      })

      admin = user_fixture("skills-seed-admin@example.com")
      {:ok, admin} = admin |> Ecto.Changeset.change(admin: true) |> Repo.update()

      {:ok, view, _html} = live(log_in_user(build_conn(), admin), ~p"/skills")
      assert has_element?(view, "#skills-add-seed")

      view |> form("#skills-add-form", %{url: @repo, seed: "true"}) |> render_submit()
      render_async(view)

      assert [%Source{owner_id: nil} = seed] = SkillRegistry.list_sources(user)
      assert has_element?(view, "#skills-seeds #skill-source-#{seed.id}")
    end

    test "nobody else sees the box, and a forged one is refused", %{conn: conn, user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"grilling/SKILL.md" => skill("grilling")})
      })

      {:ok, view, _html} = live(conn, ~p"/skills")
      refute has_element?(view, "#skills-add-seed")

      render_submit(view, "add", %{"url" => @repo, "seed" => "true"})
      render_async(view)

      assert has_element?(
               view,
               "#skills-add-error",
               "Only an admin can add a source for everyone."
             )

      assert SkillRegistry.list_sources(user) == []
    end
  end

  describe "the notices" do
    test "count and list in words" do
      assert Index.added(%{name: "x", entries: [1]}) == "Added x: 1 skill."
      assert Index.added(%{name: "x", entries: []}) == "Added x: 0 skills."

      assert Index.refreshed(%{name: "x"}, %{added: [], changed: ["a", "b"], removed: []}) ==
               "Refreshed x: changed a, b."
    end
  end

  describe "help" do
    test "the Tools guide covers skills from elsewhere and links the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/tools")

      assert has_element?(view, "#tools-skills a[href='/skills']", "Skills")
      assert has_element?(view, "#tools-skills", "Refresh")
      assert has_element?(view, "#tools-skills", "Only public addresses are fetched")
      assert has_element?(view, "#tools-skills-seeds", "mattpocock/skills")
      assert has_element?(view, "#tools-skills-seeds", "For everyone on this server")
    end
  end
end
