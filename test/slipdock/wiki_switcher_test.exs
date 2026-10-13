defmodule Slipdock.WikiSwitcherTest do
  @moduledoc """
  The quick switcher (W-103 R11.4): fuzzy matching on a note's title, its
  aliases and its path, across the vault, for what the reader may open.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Wiki.Switcher

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KB", "code" => "kbsw"}, owner: user)
    jobs = board_fixture(%{"name" => "Job Hunt", "code" => "jobsw"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: jobs})
    {:ok, acme} = Wiki.create_folder(jobs, %{"name" => "Acme"})
    {:ok, call} = Wiki.create_page(jobs, %{"title" => "Call"}, user: user)
    {:ok, call} = Wiki.file_page(call, acme)
    {:ok, rust} = Wiki.create_page(kb, %{"title" => "Rust ownership"}, user: user)

    Repo.update_all(
      from(p in Slipdock.Wiki.Page, where: p.id == ^rust.id),
      set: [aliases: ["Borrow checker"]]
    )

    %{user: user, kb: kb, jobs: jobs, call: call, rust: rust}
  end

  defp titles(results), do: Enum.map(results, & &1.title)

  describe "score/2" do
    test "the letters must come in order, case aside" do
      assert Switcher.score("acl", "Jobs/Acme/Call")
      assert Switcher.score("ACME", "acme")
      refute Switcher.score("lca", "Call")
      refute Switcher.score("x", "Call")
    end

    test "a prefix beats a run inside, which beats letters scattered" do
      prefix = Switcher.score("own", "Ownership notes")
      inside = Switcher.score("own", "Rust ownership")
      scattered = Switcher.score("own", "Old wiki notes")

      assert prefix > inside
      assert inside > scattered
    end

    test "starting words scores higher, and a shorter text wins a tie" do
      assert Switcher.score("rc", "Release checklist") > Switcher.score("rc", "parcel")
      assert Switcher.score("call", "Call") > Switcher.score("call", "Call notes from Monday")
    end

    test "spaces in the query match anything" do
      assert Switcher.score("acme call", "Acme/Call")
    end
  end

  describe "pool/2 and search/3" do
    test "spans the vault's boards, with vault paths", %{user: user, kb: kb, call: call} do
      pool = Switcher.pool(user, kb)

      assert %{path: "Jobs/Acme/Call", board: "Job Hunt"} = Enum.find(pool, &(&1.id == call.id))
      assert %{path: "Rust ownership"} = Enum.find(pool, &(&1.title == "Rust ownership"))
    end

    test "finds by title, by alias and by path, saying which", %{user: user, kb: kb} do
      pool = Switcher.pool(user, kb)

      assert [%{title: "Rust ownership", matched: :title} | _] = Switcher.search(pool, "rustown")

      assert [%{title: "Rust ownership", matched: {:alias, "Borrow checker"}}] =
               Switcher.search(pool, "borrow")

      assert [%{title: "Call", matched: :path}] = Switcher.search(pool, "jobsacme")
      assert Switcher.search(pool, "zzz") == []
    end

    test "a page's code typed whole is that page, first", %{user: user, kb: kb, call: call} do
      pool = Switcher.pool(user, kb)
      assert [%{id: id, matched: :code} | _] = Switcher.search(pool, String.downcase(call.code))
      assert id == call.id
    end

    test "an empty query gives the latest changed, and limit caps it", %{user: user, kb: kb} do
      pool = Switcher.pool(user, kb)
      assert titles(Switcher.search(pool, "")) |> Enum.sort() == ["Call", "Rust ownership"]
      assert length(Switcher.search(pool, "", 1)) == 1
      assert Enum.all?(Switcher.search(pool, "  "), &(&1.matched == :recent))
    end

    test "outside a vault, the board alone, with folder paths", %{user: user} do
      lone = board_fixture(%{"name" => "Lone", "code" => "lonesw"}, owner: user)
      {:ok, folder} = Wiki.create_folder(lone, %{"name" => "Specs"})
      {:ok, page} = Wiki.create_page(lone, %{"title" => "Retry"}, user: user)
      {:ok, _} = Wiki.file_page(page, folder)

      assert [%{title: "Retry", path: "Specs/Retry"}] = Switcher.pool(user, lone)
    end

    test "no archived pages, and drafts only where the reader can write", %{
      user: owner,
      kb: kb,
      jobs: jobs
    } do
      {:ok, draft} =
        Wiki.create_page(kb, %{"title" => "Draft idea", "status" => "draft"}, user: owner)

      {:ok, gone} = Wiki.create_page(kb, %{"title" => "Gone"}, user: owner)
      {:ok, _} = Wiki.archive_page(gone)

      titles = owner |> Switcher.pool(kb) |> titles()
      assert "Draft idea" in titles
      refute "Gone" in titles

      reader = user_fixture("switch.reader@example.com")
      {:ok, _} = Slipdock.Access.grant(kb, reader, "read", owner)
      pool = Switcher.pool(reader, kb)

      refute Enum.any?(pool, &(&1.id == draft.id))
      # Job Hunt is in the vault, but not theirs to open.
      refute Enum.any?(pool, &(&1.board_id == jobs.id))
    end
  end

  test "searching 10,000 notes takes milliseconds, not a query" do
    pool =
      for n <- 1..10_000 do
        %{
          id: n,
          board_id: 1,
          board: "B",
          title: "Note number #{n} about #{rem(n, 97)}",
          slug: "n#{n}",
          code: "W-#{n}",
          aliases: [],
          path: "Folder #{rem(n, 50)}/Note number #{n}",
          updated_at: DateTime.utc_now(),
          haystack:
            String.downcase(
              "Note number #{n} about #{rem(n, 97)}\nFolder #{rem(n, 50)}/Note number #{n}"
            )
        }
      end

    {us, results} = :timer.tc(fn -> Switcher.search(pool, "note 4242") end)
    assert hd(results).title =~ "4242"
    IO.puts("\n    switcher over 10,000 notes: #{div(us, 1000)} ms")
    assert us < 1_000_000
  end
end
