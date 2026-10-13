defmodule Slipdock.Vaults.OverlapTest do
  @moduledoc """
  A mapping over pages another board already has at those paths (#744): the
  refusal and its count, the cases that are allowed, and what a vault that
  already has an overlap does — it is reported, and sync still never writes
  two files to one path.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Vaults, Wiki}
  alias Slipdock.Vaults.{Layout, Mapping, Sync}

  setup do
    user = user_fixture()
    kb = board_fixture(%{"name" => "KnowledgeBase", "code" => "kb"}, owner: user)
    hunt = board_fixture(%{"name" => "Job Hunt", "code" => "hunt"}, owner: user)
    {:ok, jobs} = Wiki.create_folder(kb, %{"name" => "Jobs"})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "GMinds"})
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, vault: vault}
  end

  defp file!(board, title, folder) do
    {:ok, page} = Wiki.create_page(board, %{"title" => title, "folder_id" => folder && folder.id})
    page
  end

  test "an inner mapping over an outer board's pages is refused, with the count", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, vault: vault} = ctx
    file!(kb, "Acme", jobs)
    file!(kb, "Beta", jobs)
    file!(kb, "Elsewhere", nil)
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})

    assert {:error, :unprocessable_entity, message} =
             Vaults.add_mapping(vault, user, %{path: "/Jobs", board: hunt})

    assert message =~ "/Jobs would overlap 2 pages KnowledgeBase already has under /Jobs"
    assert message =~ "Jobs/Acme.md"
    assert message =~ "move them to Job Hunt first, or map somewhere else"

    # The preview says the same before anything is saved.
    assert {:error, :unprocessable_entity, ^message} =
             Vaults.preview_mapping(vault, user, %{path: "/Jobs", board: hunt})

    assert Repo.aggregate(Mapping, :count) == 1
  end

  test "an outer mapping over an inner mapping's path is refused too", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, vault: vault} = ctx
    file!(kb, "Acme", jobs)
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: hunt})

    assert {:error, :unprocessable_entity, message} =
             Vaults.add_mapping(vault, user, %{path: "/", board: kb})

    assert message =~ "would overlap 1 page KnowledgeBase already has under /Jobs"
  end

  test "allowed when the outer folder is empty, or its pages have gone", ctx do
    %{user: user, kb: kb, hunt: hunt, jobs: jobs, vault: vault} = ctx
    gone = file!(kb, "Old", jobs)
    {:ok, _} = Wiki.archive_page(gone)
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})

    assert {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: hunt})
    assert Vaults.overlaps(vault) == []
  end

  test "a path that only starts the same is not an overlap", ctx do
    %{user: user, kb: kb, hunt: hunt, vault: vault} = ctx
    {:ok, search} = Wiki.create_folder(kb, %{"name" => "Jobsearch"})
    file!(kb, "Notes", search)
    {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})

    assert {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Jobs", board: hunt})
  end

  describe "a vault that already has one" do
    setup ctx do
      %{user: user, kb: kb, hunt: hunt, jobs: jobs, vault: vault} = ctx
      file!(kb, "Acme", jobs)
      file!(hunt, "Acme", nil)
      {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/", board: kb})

      # Made the way it was before mappings were checked.
      Repo.insert!(%Mapping{vault_id: vault.id, board_id: hunt.id, path: "Jobs"})
      :ok
    end

    test "is reported, page by page", %{vault: vault} do
      assert [overlap] = Vaults.overlaps(vault)

      assert overlap == %{
               path: "Jobs/Acme.md",
               board: "KnowledgeBase",
               mapping: "/",
               under: "/Jobs",
               owner: "Job Hunt"
             }
    end

    test "does not stop an unrelated mapping", %{user: user, vault: vault} do
      other = board_fixture(%{"name" => "Other", "code" => "oth"}, owner: user)
      assert {:ok, _} = Vaults.add_mapping(vault, user, %{path: "/Other", board: other})
    end

    test "sync still writes one file per path", %{user: user, vault: vault} do
      paths = vault |> Layout.build() |> Map.fetch!(:pages) |> Map.values() |> Enum.map(& &1.path)
      assert length(paths) == 2
      assert length(Enum.uniq_by(paths, &String.downcase/1)) == 2
      assert "Jobs/Acme.md" in paths

      listing = Sync.listing(vault, user)
      listed = listing.entries |> Enum.map(& &1.path)
      assert length(listed) == length(Enum.uniq(listed))
    end
  end
end
