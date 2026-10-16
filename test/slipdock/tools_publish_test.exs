defmodule Slipdock.ToolsPublishTest do
  @moduledoc """
  Publishing a Tool package (#960): what a package must hold, what it may
  not, and how versions and names are owned.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Quota, Repo, Settings, Tools}
  alias Slipdock.Tools.Package

  defp publish(user, overrides \\ %{}, opts \\ []) do
    name = opts[:name] || unique_name()
    Tools.publish(user, package(name, opts[:version] || "1.0.0", overrides))
  end

  defp manifest(name, changes) do
    base = Jason.decode!(files(name)["tool.json"])
    %{"tool.json" => Jason.encode!(Map.merge(base, changes))}
  end

  describe "a valid package" do
    test "is stored as an immutable version with a sha over its files" do
      user = user_fixture()
      name = unique_name()

      assert {:ok, version} = Tools.publish(user, package(name))
      assert version.tool.slug == name
      assert version.tool.name == "Demo Tool"
      assert version.tool.owner_id == user.id
      assert version.version == "1.0.0"
      assert version.sha == Package.sha(Enum.to_list(files(name)))
      assert version.readme =~ "What it does."
      assert [%{"name" => "Found", "category" => "todo"} | _] = version.board["lists"]

      paths = version |> Tools.files() |> Enum.map(& &1.path)
      assert "skills/#{name}/references/notes.md" in paths
      assert "files/helper.sh" in paths
      assert Tools.file(version, "files/helper.sh").content == "#!/bin/sh\necho hi\n"
      assert version.size == files(name) |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
    end

    test "can sit inside one top-level folder, the way tar packs a directory" do
      name = unique_name()
      assert {:ok, version} = Tools.publish(user_fixture(), tarball(files(name), name))
      assert version.sha == Package.sha(Enum.to_list(files(name)))
    end

    test "lists its skills with descriptions, and local files beside their skill" do
      name = unique_name()
      {:ok, version} = Tools.publish(user_fixture(), package(name))

      assert [main, setup] = Tools.skills(version)
      assert main.name == name
      assert main.description == "Does the demo thing."
      assert main.files == ["SKILL.md", "helper.sh", "references/notes.md"]
      assert setup.name == "#{name}-setup"
      assert setup.files == ["SKILL.md"]
      assert is_binary(main.sha) and byte_size(main.sha) == 16
    end
  end

  describe "versions" do
    test "a newer version is added beside the first" do
      user = user_fixture()
      name = unique_name()
      {:ok, _} = Tools.publish(user, package(name, "1.0.0"))
      assert {:ok, v2} = Tools.publish(user, package(name, "1.1.0", %{"README.md" => "# v2"}))

      tool = v2.tool
      assert Enum.map(Tools.versions(tool), & &1.version) == ["1.1.0", "1.0.0"]
      assert Tools.latest_version(tool).readme == "# v2"
      assert Tools.get_version(tool, "1.0.0").readme =~ "What it does."
    end

    test "the same version again is refused, even with different files" do
      user = user_fixture()
      name = unique_name()
      {:ok, _} = Tools.publish(user, package(name, "1.0.0"))

      assert {:error, message} =
               Tools.publish(user, package(name, "1.0.0", %{"README.md" => "changed"}))

      assert message =~ "already published, and a version never changes"
      [only] = Tools.versions(Repo.get_by(Tools.Tool, slug: name))
      assert only.readme =~ "What it does."
    end

    test "an older version is refused" do
      user = user_fixture()
      name = unique_name()
      {:ok, _} = Tools.publish(user, package(name, "2.0.0"))
      assert {:error, message} = Tools.publish(user, package(name, "1.9.0"))
      assert message =~ "older than the latest, 2.0.0"
    end

    test "somebody else can't publish under a name that is taken" do
      name = unique_name()
      {:ok, _} = Tools.publish(user_fixture(), package(name, "1.0.0"))
      other = user_fixture("other@example.com")

      assert {:error, message} = Tools.publish(other, package(name, "1.1.0"))
      assert message =~ "belongs to someone else's Tool"
    end
  end

  describe "manifest errors" do
    test "each is refused with its own message" do
      user = user_fixture()

      cases = [
        {fn n -> files(n, "1.0.0", %{"tool.json" => nil}) end, "tool.json is missing"},
        {fn n -> %{"tool.json" => "{not json"} |> then(&files(n, "1.0.0", &1)) end,
         "tool.json: not valid JSON"},
        {fn n -> files(n, "1.0.0", manifest(n, %{"name" => "Bad Name"})) end,
         "name must be lowercase"},
        {fn n -> files(n, "1.0.0", manifest(n, %{"version" => "one"})) end,
         "version must be a version number"},
        {fn n -> files(n, "1.0.0", manifest(n, %{"summary" => " "})) end, "summary is required"},
        {fn n -> files(n, "1.0.0", manifest(n, %{"summary" => String.duplicate("x", 201)})) end,
         "summary is at most 200"},
        {fn n -> files(n, "1.0.0", manifest(n, %{"files" => "all"})) end, "files is a list"},
        {fn n -> files(n, "1.0.0", %{"README.md" => nil}) end, "README.md is missing"},
        {fn n -> files(n, "1.0.0", %{"README.md" => <<0xFF, 0xFE>>}) end, "must be UTF-8"},
        {fn n -> files(n, "1.0.0", %{"board.json" => ~s({"lists": []})}) end,
         "board.json: lists: a board needs at least one list"},
        {fn n -> files(n, "1.0.0", %{"notes.txt" => "x"}) end,
         "notes.txt: a package holds tool.json"},
        {fn n ->
           files(n, "1.0.0")
           |> Map.reject(fn {p, _} -> String.starts_with?(p, "skills/") end)
           |> Map.merge(
             manifest(n, %{"files" => [%{"path" => "guide.md", "install" => "board"}]})
           )
           |> Map.delete("files/helper.sh")
         end, "at least one skill"},
        {fn n -> files(n, "1.0.0", %{"skills/#{n}/SKILL.md" => "# no front matter"}) end,
         "must start with front matter"},
        {fn n ->
           files(n, "1.0.0", %{
             "skills/#{n}/SKILL.md" => "---\nname: other\ndescription: d\n---\n"
           })
         end, "front matter name is “other”"},
        {fn n -> files(n, "1.0.0", %{"skills/#{n}/SKILL.md" => "---\nname: #{n}\n---\n"}) end,
         "needs a name and a description"},
        {fn n -> files(n, "1.0.0", %{"files/stray.txt" => "x"}) end,
         "files/stray.txt: not listed in tool.json's files"},
        {fn n -> files(n, "1.0.0", %{"files/guide.md" => nil}) end,
         "files lists guide.md, but files/guide.md is not in the package"},
        {fn n ->
           files(
             n,
             "1.0.0",
             manifest(n, %{"files" => [%{"path" => "guide.md", "install" => "cloud"}]})
           )
           |> Map.delete("files/helper.sh")
         end, "install is board or local"},
        {fn n ->
           files(
             n,
             "1.0.0",
             manifest(n, %{"files" => [%{"path" => "guide.md", "install" => "local"}]})
           )
           |> Map.delete("files/helper.sh")
         end, "needs a skill from skills/"},
        {fn n ->
           files(
             n,
             "1.0.0",
             manifest(n, %{
               "files" => [
                 %{"path" => "guide.md", "install" => "board"},
                 %{"path" => "SKILL.md", "install" => "local", "skill" => n}
               ]
             })
           )
           |> Map.delete("files/helper.sh")
           |> Map.put("files/SKILL.md", "x")
         end, "would overwrite the"}
      ]

      for {build, expected} <- cases do
        name = unique_name()
        result = Tools.publish(user, tarball(build.(name)))
        assert {:error, message} = result, "expected #{inspect(expected)}, got #{inspect(result)}"
        assert message =~ expected
      end
    end

    test "something that is not a tarball is refused" do
      assert {:error, "that is not a readable .tar.gz"} =
               Tools.publish(user_fixture(), "plain text, not gzip")
    end
  end

  describe "unsafe archives" do
    test "a path that climbs out of the package is refused" do
      name = unique_name()
      bytes = tarball(Map.put(files(name), "../escape.txt", "boo"))

      assert {:error, message} = Tools.publish(user_fixture(), bytes)
      assert message =~ "../escape.txt: a path in a package must stay inside it"
    end

    test "an absolute path is refused" do
      refute Package.safe_path?("/etc/passwd")
      refute Package.safe_path?("skills/../../x")
      refute Package.safe_path?("C:/x")
      refute Package.safe_path?("a\\b")
      assert Package.safe_path?("skills/x/SKILL.md")
    end

    test "a symlink is refused" do
      name = unique_name()
      dir = Path.join(System.tmp_dir!(), "tool-link-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      tar = Path.join(dir, "p.tar.gz")

      try do
        File.ln_s!("/etc/passwd", Path.join(dir, "link"))
        {:ok, handle} = :erl_tar.open(String.to_charlist(tar), [:write, :compressed])

        for {path, content} <- files(name),
            do: :ok = :erl_tar.add(handle, content, String.to_charlist(path), [])

        :ok = :erl_tar.add(handle, String.to_charlist(Path.join(dir, "link")), ~c"files/link", [])
        :ok = :erl_tar.close(handle)

        assert {:error, message} = Tools.publish(user_fixture(), File.read!(tar))
        assert message =~ "files/link: only plain files and folders"
      after
        File.rm_rf!(dir)
      end
    end

    test "an oversized package is refused before it is unpacked" do
      big = :binary.copy("x", Package.max_compressed() + 1)
      assert {:error, message} = Tools.publish(user_fixture(), big)
      assert message =~ "over 10 MB"
    end
  end

  describe "quota" do
    test "a package counts towards its owner's storage, and one past it is refused" do
      {:ok, _} =
        Settings.complete_setup(%{"admin_email" => "admin@example.com", "storage_limit_mb" => 1})

      user = user_fixture()
      {:ok, v} = publish(user)
      assert Quota.used(user, :storage) == v.size

      big = :crypto.strong_rand_bytes(1_100_000)

      assert {:error, :payment_required, "storage_limit_reached", message} =
               publish(user, %{"files/guide.md" => big})

      assert message =~ "of storage left on this server"
    end
  end
end
