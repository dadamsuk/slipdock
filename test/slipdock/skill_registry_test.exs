defmodule Slipdock.SkillRegistryTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, SkillRegistry, SkillRegistryStub, TestConfig}
  alias Slipdock.SkillRegistry.{Entry, Parse, Source}

  @repo "https://github.com/octo/skills"

  defp skill(name, description \\ "Does a thing.", body \\ "Steps.") do
    "---\nname: #{name}\ndescription: #{description}\n---\n\n#{body}\n"
  end

  defp octo(files, extra \\ %{}),
    do: Map.merge(%{files: files, licence: "MIT"}, extra)

  setup do
    %{user: user_fixture(), other: user_fixture("other@example.com")}
  end

  describe "adding a GitHub repository" do
    test "stores each SKILL.md with its metadata", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{
            "grilling/SKILL.md" => skill("grilling", "Asks hard questions."),
            "tdd/SKILL.md" => skill("tdd"),
            "README.md" => "# Skills"
          })
      })

      assert {:ok, source} = SkillRegistry.add_source(user, @repo)
      assert source.owner_id == user.id
      assert source.kind == "github"
      assert source.name == "octo/skills"
      assert source.licence == "MIT"
      assert source.version == SkillRegistryStub.sha()
      assert source.report == []

      assert [grilling, tdd] = source.entries
      assert grilling.name == "grilling"
      assert grilling.description == "Asks hard questions."
      assert grilling.path == "grilling/SKILL.md"
      assert grilling.body == skill("grilling", "Asks hard questions.")

      assert grilling.content_hash ==
               :crypto.hash(:sha256, grilling.body) |> Base.encode16(case: :lower)

      assert grilling.version == SkillRegistryStub.sha()
      assert grilling.licence == "MIT"
      assert %DateTime{} = grilling.fetched_at
      assert tdd.name == "tdd"

      # Every file came from the commit the default branch named.
      assert "/octo/skills/#{SkillRegistryStub.sha()}/grilling/SKILL.md" in SkillRegistryStub.requests()
    end

    test "a SKILL.md without a name is reported on the source, not stored", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{
            "good/SKILL.md" => skill("good"),
            "nameless/SKILL.md" => "---\ndescription: no name\n---\nBody"
          })
      })

      assert {:ok, source} = SkillRegistry.add_source(user, @repo)
      assert Enum.map(source.entries, & &1.name) == ["good"]

      assert source.report == [
               "nameless/SKILL.md has no name in its front matter, so it was skipped."
             ]
    end

    test "a repository whose skills all fail stores nothing", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"a/SKILL.md" => "no front matter at all"})
      })

      assert {:error, message} = SkillRegistry.add_source(user, @repo)
      assert message =~ "has no skill Slipdock could read"
      assert message =~ "a/SKILL.md has no name in its front matter"
      assert Repo.aggregate(Source, :count) == 0
    end

    test "a repository with only a README gets one entry, named for the repository",
         %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{"README.md" => "# Octo skills\n\nA handful of planning prompts.\n\nMore."})
      })

      assert {:ok, %{entries: [entry]}} = SkillRegistry.add_source(user, @repo)
      assert entry.name == "skills"
      assert entry.description == "A handful of planning prompts."
      assert entry.path == "README.md"
    end

    test "a repository with neither is refused", %{user: user} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"lib/x.ex" => "code"})})

      assert {:error, "#{@repo} has no SKILL.md and no README."} ==
               SkillRegistry.add_source(user, @repo)
    end

    test "a path in the repository takes only the skills under it", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{"plan/grill/SKILL.md" => skill("grill"), "other/SKILL.md" => skill("other")})
      })

      assert {:ok, source} = SkillRegistry.add_source(user, @repo <> "/tree/main/plan")
      assert source.name == "octo/skills/plan"
      assert Enum.map(source.entries, & &1.name) == ["grill"]
    end

    test "a repository GitHub doesn't know is a sentence", %{user: user} do
      SkillRegistryStub.start(%{})

      assert {:error, "octo/skills was not found."} == SkillRegistry.add_source(user, @repo)
    end

    test "no licence, or NOASSERTION, is stored as none", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"a/SKILL.md" => skill("a")}, %{licence: "NOASSERTION"})
      })

      assert {:ok, %{licence: nil, entries: [%{licence: nil}]}} =
               SkillRegistry.add_source(user, @repo)
    end

    test "a truncated tree listing is reported", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"a/SKILL.md" => skill("a")}, %{truncated: true})
      })

      assert {:ok, %{report: [line]}} = SkillRegistry.add_source(user, @repo)
      assert line =~ "only part of the repository"
    end

    test "the same URL twice is refused", %{user: user, other: other} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})

      assert {:ok, _} = SkillRegistry.add_source(user, @repo)

      assert {:error, "#{@repo} is already one of your sources."} ==
               SkillRegistry.add_source(user, @repo)

      # Somebody else's copy of the same URL is theirs.
      assert {:ok, _} = SkillRegistry.add_source(other, @repo)
    end
  end

  describe "adding one file" do
    test "a SKILL.md at any https URL, versioned by its ETag", %{user: user} do
      SkillRegistryStub.start(%{
        "/team/grill/SKILL.md" => %{body: skill("grill"), etag: ~s("abc123")}
      })

      url = "https://skills.example.com/team/grill/SKILL.md"
      assert {:ok, source} = SkillRegistry.add_source(user, url)
      assert source.kind == "file"
      assert source.name == "skills.example.com/team/grill/SKILL.md"
      assert source.licence == nil

      assert [%{name: "grill", version: ~s("abc123"), path: "team/grill/SKILL.md"}] =
               source.entries
    end

    test "without an ETag the version is the content's hash", %{user: user} do
      SkillRegistryStub.start(%{"/SKILL.md" => skill("solo")})

      assert {:ok, %{entries: [entry]}} =
               SkillRegistry.add_source(user, "https://skills.example.com/SKILL.md")

      assert entry.version == "sha256:" <> String.slice(entry.content_hash, 0, 12)
    end

    test "a GitHub blob URL takes the repository's licence and commit", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"grill/SKILL.md" => skill("grill")}, %{licence: "Apache-2.0"})
      })

      assert {:ok, source} =
               SkillRegistry.add_source(user, @repo <> "/blob/main/grill/SKILL.md")

      assert source.kind == "file"
      assert source.licence == "Apache-2.0"
      assert [%{name: "grill", licence: "Apache-2.0", version: sha}] = source.entries
      assert sha == SkillRegistryStub.sha()
      # No tree is fetched for one file.
      refute Enum.any?(SkillRegistryStub.requests(), &String.contains?(&1, "/git/trees/"))
    end

    test "one file without a name is refused", %{user: user} do
      SkillRegistryStub.start(%{"/SKILL.md" => "---\ndescription: x\n---\n"})
      url = "https://skills.example.com/SKILL.md"

      assert {:error, "#{url} has no name in its front matter."} ==
               SkillRegistry.add_source(user, url)
    end

    test "URLs that are not a source", %{user: user} do
      SkillRegistryStub.start(%{})

      assert {:error, "http://skills.example.com/SKILL.md should be an https URL."} ==
               SkillRegistry.add_source(user, "http://skills.example.com/SKILL.md")

      assert {:error, msg} = SkillRegistry.add_source(user, "https://example.com/page.html")
      assert msg =~ "is not a GitHub repository or a SKILL.md URL"

      assert {:error, msg} = SkillRegistry.add_source(user, @repo <> "/blob/main/lib/x.ex")
      assert msg =~ "is not a Markdown file"

      assert {:error, _} = SkillRegistry.add_source(user, "not a url")
      assert {:error, "A source needs a URL."} == SkillRegistry.add_source(user, nil)
      assert SkillRegistryStub.requests() == []
    end
  end

  describe "Egress" do
    setup do
      SkillRegistryStub.start(%{"/SKILL.md" => skill("x")})
      :ok
    end

    test "private, link-local and CGNAT addresses are refused before any request",
         %{user: user} do
      for host <- ~w(intranet.test metadata.test tailnet.test split.test) do
        url = "https://#{host}/SKILL.md"
        assert {:error, message} = SkillRegistry.add_source(user, url)
        assert message == "#{url} is not a public address."
      end

      assert {:error, "https://127.0.0.1/SKILL.md is not a public address."} ==
               SkillRegistry.add_source(user, "https://127.0.0.1/SKILL.md")

      assert {:error, "https://nowhere.test/SKILL.md could not be resolved."} ==
               SkillRegistry.add_source(user, "https://nowhere.test/SKILL.md")

      assert SkillRegistryStub.requests() == []
      assert Repo.aggregate(Source, :count) == 0
    end

    test "a redirect is not followed", %{user: user} do
      SkillRegistryStub.put("/moved/SKILL.md", %{status: 302, body: ""})
      url = "https://skills.example.com/moved/SKILL.md"

      assert {:error, message} = SkillRegistry.add_source(user, url)
      assert message == "#{url} redirects elsewhere (redirects are not followed)."
      assert SkillRegistryStub.requests() == ["/moved/SKILL.md"]
    end

    test "a refused or failing server is a sentence", %{user: user} do
      SkillRegistryStub.put("/limited/SKILL.md", %{status: 429})
      SkillRegistryStub.put("/broken/SKILL.md", %{status: 500})

      assert {:error, limited} =
               SkillRegistry.add_source(user, "https://skills.example.com/limited/SKILL.md")

      assert limited =~ "was refused (HTTP 429; rate limited?)"

      assert {:error, broken} =
               SkillRegistry.add_source(user, "https://skills.example.com/broken/SKILL.md")

      assert broken =~ "answered HTTP 500"
    end
  end

  describe "caps" do
    test "a file over the size cap is refused while it is read", %{user: user} do
      SkillRegistryStub.start(%{
        "/big/SKILL.md" => skill("big", "x", String.duplicate("a", 5000))
      })

      TestConfig.merge(:skill_registry, max_file_bytes: 1000)
      url = "https://skills.example.com/big/SKILL.md"

      assert {:error, "#{url} is larger than 1 KB."} == SkillRegistry.add_source(user, url)
    end

    test "a repository's file over the cap is skipped without being fetched", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{
            "big/SKILL.md" => skill("big", "x", String.duplicate("a", 5000)),
            "small/SKILL.md" => skill("small")
          })
      })

      TestConfig.merge(:skill_registry, max_file_bytes: 1000)

      assert {:ok, source} = SkillRegistry.add_source(user, @repo)
      assert Enum.map(source.entries, & &1.name) == ["small"]
      assert source.report == ["big/SKILL.md is larger than 1 KB, so it was skipped."]
      refute Enum.any?(SkillRegistryStub.requests(), &String.ends_with?(&1, "big/SKILL.md"))
    end

    test "a source holds at most max_entries skills, and says how many it left out",
         %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{
            "a/SKILL.md" => skill("a"),
            "b/SKILL.md" => skill("b"),
            "c/SKILL.md" => skill("c")
          })
      })

      TestConfig.merge(:skill_registry, max_entries: 2)

      assert {:ok, source} = SkillRegistry.add_source(user, @repo)
      assert Enum.map(source.entries, & &1.name) == ["a", "b"]
      assert source.report == ["1 more SKILL.md files were left out (at most 2 per source)."]
    end
  end

  describe "front matter" do
    test "a folded or literal description is read" do
      folded = "---\nname: grill\ndescription: >\n  Asks one question\n  at a time.\n---\nBody"
      literal = "---\nname: grill\ndescription: |\n  Line one\n  Line two\n---\nBody"

      assert {:ok, %{name: "grill", description: "Asks one question at a time."}} =
               Parse.entry(folded)

      assert {:ok, %{description: "Line one\nLine two"}} = Parse.entry(literal)
    end

    test "quoted values lose their quotes" do
      assert {:ok, %{name: "grill me", description: "It: asks"}} =
               Parse.entry(~s(---\nname: "grill me"\ndescription: 'It: asks'\n---\n))
    end

    test "bad front matter is a reason to skip" do
      assert {:skip, "its front matter is not closed with a `---` line"} =
               Parse.entry("---\nname: grill\nno end")

      assert {:skip, "its name is a list, not a single line"} =
               Parse.entry("---\nname: [a, b]\n---\n")

      assert {:skip, "has no name in its front matter"} = Parse.entry("---\nname:\n---\n")
      assert {:skip, "is not UTF-8 text"} = Parse.entry(<<0xFF, 0xFE, 0x00>>)

      long = String.duplicate("n", 101)

      assert {:skip, "its name is longer than 100 characters"} =
               Parse.entry("---\nname: #{long}\n---\n")
    end

    test "a skipped file in a repository says why", %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{"ok/SKILL.md" => skill("ok"), "bad/SKILL.md" => "---\nname: bad\nunclosed"})
      })

      assert {:ok, %{report: [line]}} = SkillRegistry.add_source(user, @repo)

      assert line ==
               "bad/SKILL.md its front matter is not closed with a `---` line, so it was skipped."
    end
  end

  describe "refresh" do
    setup %{user: user} do
      SkillRegistryStub.start(%{
        "octo/skills" =>
          octo(%{
            "keep/SKILL.md" => skill("keep"),
            "edit/SKILL.md" => skill("edit", "Old."),
            "gone/SKILL.md" => skill("gone")
          })
      })

      {:ok, source} = SkillRegistry.add_source(user, @repo)
      %{source: source}
    end

    test "reports which entries were added, changed and removed", %{user: user, source: source} do
      edit_id = Enum.find(source.entries, &(&1.name == "edit")).id
      new_sha = String.duplicate("b", 40)

      SkillRegistryStub.put(
        "octo/skills",
        octo(
          %{
            "keep/SKILL.md" => skill("keep"),
            "edit/SKILL.md" => skill("edit", "New."),
            "new/SKILL.md" => skill("new")
          },
          %{sha: new_sha}
        )
      )

      assert {:ok, refreshed, changes} = SkillRegistry.refresh_source(user, source)

      assert changes == %{
               added: ["new"],
               changed: ["edit"],
               removed: ["gone"],
               unchanged: ["keep"]
             }

      assert refreshed.version == new_sha
      edited = Enum.find(refreshed.entries, &(&1.name == "edit"))
      # Updated in place: what points at the entry still does.
      assert edited.id == edit_id
      assert edited.description == "New."
      assert edited.version == new_sha
      assert Enum.map(refreshed.entries, & &1.name) |> Enum.sort() == ["edit", "keep", "new"]
    end

    test "nothing changed is all unchanged", %{user: user, source: source} do
      assert {:ok, _, %{added: [], changed: [], removed: [], unchanged: unchanged}} =
               SkillRegistry.refresh_source(user, source)

      assert Enum.sort(unchanged) == ["edit", "gone", "keep"]
    end

    test "a failed fetch leaves the source as it was", %{user: user, source: source} do
      SkillRegistryStub.put("octo/skills", octo(%{"x.ex" => "code"}))

      assert {:error, _} = SkillRegistry.refresh_source(user, source)
      assert Repo.aggregate(Entry, :count) == 3
      assert Repo.reload!(source).version == SkillRegistryStub.sha()
    end

    test "only the owner refreshes", %{other: other, source: source} do
      assert {:error, "Only whoever added octo/skills can change it."} ==
               SkillRegistry.refresh_source(other, source)
    end
  end

  describe "remove" do
    setup %{user: user} do
      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})
      {:ok, source} = SkillRegistry.add_source(user, @repo)
      %{source: source}
    end

    test "deletes the source and its entries", %{user: user, source: source} do
      assert {:ok, _} = SkillRegistry.remove_source(user, source)
      assert Repo.aggregate(Source, :count) == 0
      assert Repo.aggregate(Entry, :count) == 0
    end

    test "only the owner removes", %{other: other, source: source} do
      assert {:error, _} = SkillRegistry.remove_source(other, source)
      assert Repo.aggregate(Entry, :count) == 1
    end
  end

  describe "who sees what" do
    test "a user sees their own sources and the seeds, not other people's",
         %{user: user, other: other} do
      SkillRegistryStub.start(%{
        "octo/skills" => octo(%{"a/SKILL.md" => skill("a")}),
        "octo/seed" => octo(%{"s/SKILL.md" => skill("s")})
      })

      {:ok, mine} = SkillRegistry.add_source(user, @repo)
      {:ok, theirs} = SkillRegistry.add_source(other, @repo)
      {:ok, seed} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")

      assert seed.owner_id == nil
      assert Enum.map(SkillRegistry.list_sources(user), & &1.id) == [mine.id, seed.id]
      assert SkillRegistry.get_source(user, theirs.id) == nil
      assert SkillRegistry.get_source(user, seed.id).id == seed.id

      [their_entry] = theirs.entries
      [seed_entry] = seed.entries
      assert SkillRegistry.get_entry(user, their_entry.id) == nil
      assert %Entry{source: %Source{}} = SkillRegistry.get_entry(user, seed_entry.id)
    end

    test "a seed is changed only by an admin", %{user: user} do
      SkillRegistryStub.start(%{"octo/seed" => octo(%{"s/SKILL.md" => skill("s")})})
      {:ok, seed} = SkillRegistry.add_source(nil, "https://github.com/octo/seed")
      admin = %{user | admin: true}

      refute SkillRegistry.can_manage?(user, seed)
      assert SkillRegistry.can_manage?(admin, seed)
      assert {:error, _} = SkillRegistry.remove_source(user, seed)
      assert {:ok, _} = SkillRegistry.remove_source(admin, seed)
    end
  end

  describe "the GitHub token" do
    test "goes to api.github.com only", %{user: user} do
      test_pid = self()

      SkillRegistryStub.start(%{"octo/skills" => octo(%{"a/SKILL.md" => skill("a")})})

      Req.Test.stub(Slipdock.SkillRegistry, fn conn ->
        send(
          test_pid,
          {:auth, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
        )

        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      TestConfig.merge(:skill_registry, github_token: "ghp_test")
      SkillRegistry.add_source(user, @repo)
      assert_received {:auth, "/repos/octo/skills", ["Bearer ghp_test"]}

      SkillRegistry.add_source(user, "https://skills.example.com/SKILL.md")
      assert_received {:auth, "/SKILL.md", []}
    end
  end
end
