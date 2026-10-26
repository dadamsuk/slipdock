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
    jobs = board_fixture(%{"name" => "Journal Desk", "code" => "jobsw"}, owner: user)
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "Brain"})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Journal", board: jobs})
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
      assert Switcher.score("acl", "Journal/Acme/Call")
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

      assert %{path: "Journal/Acme/Call", board: "Journal Desk"} =
               Enum.find(pool, &(&1.id == call.id))

      assert %{path: "Rust ownership"} = Enum.find(pool, &(&1.title == "Rust ownership"))
    end

    test "finds by title, by alias and by path, saying which", %{user: user, kb: kb} do
      pool = Switcher.pool(user, kb)

      assert [%{title: "Rust ownership", matched: :title} | _] = Switcher.search(pool, "rustown")

      assert [%{title: "Rust ownership", matched: {:alias, "Borrow checker"}}] =
               Switcher.search(pool, "borrow")

      assert [%{title: "Call", matched: :path}] = Switcher.search(pool, "journalacme")
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
      # Journal Desk is in the vault, but not theirs to open.
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

  describe "linkable_pool/2 (#1303)" do
    setup %{user: user} do
      notes = board_fixture(%{"name" => "Notes", "code" => "notsw1303"}, owner: user)
      {:ok, other} = Vaults.create_vault(user, %{"name" => "Garden"})
      {:ok, _} = Vaults.add_mapping(other, user, %{path: "/", board: notes})
      {:ok, rose} = Wiki.create_page(notes, %{"title" => "Rose pruning"}, user: user)

      stranger = user_fixture("switch1303.stranger@example.com")
      hidden = board_fixture(%{"name" => "Hidden", "code" => "hidsw1303"}, owner: stranger)
      {:ok, theirs} = Vaults.create_vault(stranger, %{"name" => "Theirs"})
      {:ok, _} = Vaults.add_mapping(theirs, stranger, %{path: "/", board: hidden})
      {:ok, secret} = Wiki.create_page(hidden, %{"title" => "Rose secret"}, user: stranger)

      %{notes: notes, rose: rose, secret: secret}
    end

    test "adds every other vault's pages, marked with the vault, and nobody else's", %{
      user: user,
      kb: kb,
      rose: rose,
      call: call,
      secret: secret
    } do
      pool = Switcher.linkable_pool(user, kb)
      by_id = Map.new(pool, &{&1.id, &1})

      assert by_id[rose.id].elsewhere == "Garden"
      assert by_id[call.id][:elsewhere] == nil
      refute Map.has_key?(by_id, secret.id)

      # The plain switcher stays inside the board's vault.
      refute Enum.any?(Switcher.pool(user, kb), &(&1.id == rose.id))
    end

    test "a board outside any vault gets its own pages and every vault's", %{
      user: user,
      rose: rose,
      call: call
    } do
      loose = board_fixture(%{"name" => "Loose", "code" => "loosw1303"}, owner: user)
      {:ok, own} = Wiki.create_page(loose, %{"title" => "Loose end"}, user: user)

      by_id = user |> Switcher.linkable_pool(loose) |> Map.new(&{&1.id, &1})

      assert by_id[own.id][:elsewhere] == nil
      assert by_id[rose.id].elsewhere == "Garden"
      assert by_id[call.id].elsewhere == "Brain"
    end

    test "this vault's pages come first, recent or matched", %{
      user: user,
      kb: kb,
      rose: rose,
      rust: rust
    } do
      # The other vault's page is the newest of all, and still comes after.
      Repo.update_all(
        from(p in Slipdock.Wiki.Page, where: p.id != ^rose.id),
        set: [updated_at: ~U[2020-01-01 00:00:00Z]]
      )

      pool = Switcher.linkable_pool(user, kb)
      recent = Switcher.search(pool, "", 50)

      assert Enum.find_index(recent, &(&1.id == rust.id)) <
               Enum.find_index(recent, &(&1.id == rose.id))

      # The same words match both titles equally well: this vault's wins.
      {:ok, here} = Wiki.create_page(kb, %{"title" => "Rose pruning"}, user: user)

      assert [%{id: first}, %{id: second} | _] =
               user |> Switcher.linkable_pool(kb) |> Switcher.search("rose pruning")

      assert {first, second} == {here.id, rose.id}

      # A far better match from elsewhere still wins.
      assert [%{id: id} | _] = Switcher.search(pool, "rose")
      assert id == rose.id
    end
  end
end
