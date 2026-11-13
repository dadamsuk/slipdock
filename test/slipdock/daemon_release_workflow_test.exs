defmodule Slipdock.DaemonReleaseWorkflowTest do
  @moduledoc """
  The runner daemon's signed release in .github/workflows/release.yml
  (#2578, W-2542): only a v* tag releases; the build has no secrets; the
  signing key is read in one job only, through the protected
  `daemon-release` environment; the signature is checked against the
  committed public key before anything is published; and the installers get
  the key from that one file.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @path Path.join(@root, ".github/workflows/release.yml")
  @external_resource @path
  @external_resource Path.join(@root, ".github/workflows/ci.yml")
  @text File.read!(@path)
  @jobs YamlElixir.read_from_string!(@text)["jobs"]

  defp job(name), do: Map.fetch!(@jobs, name)

  defp runs(job), do: Enum.map_join(job["steps"], "\n", &(&1["run"] || ""))

  test "a v* tag pushed is the only thing that releases the daemon" do
    assert job("daemon-build")["if"] ==
             "${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"

    assert job("daemon-release")["needs"] == "daemon-build"
  end

  # cli-sign signs the CLI the image serves with the same key (#2669), in
  # the same environment.
  test "the signing key is read only in the two signing jobs, through daemon-release" do
    readers =
      for {name, job} <- @jobs, inspect(job) =~ "DAEMON_SIGNING_KEY", do: name

    assert Enum.sort(readers) == ["cli-sign", "daemon-release"]
    assert job("daemon-release")["environment"] == "daemon-release"
    assert job("cli-sign")["environment"] == "daemon-release"
    refute inspect(job("daemon-build")) =~ "secrets."
    assert job("daemon-build")["permissions"] == %{"contents" => "read"}
  end

  test "signs in the slipdock-runner namespace, then checks against the committed key before publishing" do
    steps = job("daemon-release")["steps"] |> Enum.map(&(&1["name"] || &1["uses"]))

    assert Enum.find_index(steps, &(&1 == "Sign release.json")) <
             Enum.find_index(steps, &(&1 == "Check the signature against the committed key"))

    assert Enum.find_index(steps, &(&1 == "Check the signature against the committed key")) <
             Enum.find_index(steps, &(&1 == "Publish the release"))

    run = runs(job("daemon-release"))
    assert run =~ "ssh-keygen -Y sign -q -f \"$key_file\" -n slipdock-runner dist/release.json"
    assert run =~ "daemon/internal/release/release_key.pub"
    assert run =~ "-n slipdock-runner"
    # The key file is private to the job and removed however it ends.
    assert run =~ "umask 077"
    assert run =~ ~s(trap 'rm -f "$key_file"' EXIT)
  end

  test "the installers get the key from release_key.pub, and a release without one isn't made" do
    run = runs(job("daemon-build"))
    assert run =~ "internal/release/release_key.pub"
    assert run =~ ~s(sed "s|__SLIPDOCK_RELEASE_KEY__|$key|" install.sh > dist/install.sh)
    assert run =~ ~s(sed "s|__SLIPDOCK_RELEASE_KEY__|$key|" install.ps1 > dist/install.ps1)
    assert run =~ "holds no ssh-ed25519 key"

    for installer <- ~w(install.sh install.ps1) do
      assert File.read!(Path.join([@root, "daemon", installer])) =~ "'__SLIPDOCK_RELEASE_KEY__'",
             "#{installer} has lost the line the release job writes the key into"
    end
  end

  test "the binaries carry the tag's version, and the platform list is the release package's" do
    run = runs(job("daemon-build"))
    assert run =~ "release-manifest -version \"$VERSION\" -platforms"
    assert run =~ "-X github.com/dadamsuk/slipdock/daemon/internal/cli.Version=$VERSION"
    assert run =~ "go test ./..."
  end

  # #2960: the race detector is ci.yml's daemon job's (#2664), which runs on
  # the tag's tree; the release's own test stays quick, and says why.
  test "the release's daemon tests run without -race, and the workflow says why" do
    run = runs(job("daemon-build"))
    assert run =~ ~r/^go test \.\/\.\.\.$/m
    refute run =~ "-race"
    assert @text =~ "# Without -race, on purpose (#2960)."

    ci = YamlElixir.read_from_string!(File.read!(Path.join(@root, ".github/workflows/ci.yml")))
    assert runs(ci["jobs"]["daemon"]) =~ "go test -race ./..."
  end

  test "the committed release key is a public key or none, never a private one" do
    key = File.read!(Path.join(@root, "daemon/internal/release/release_key.pub"))
    refute key =~ "PRIVATE KEY"

    for line <- String.split(key, "\n"), line != "", not String.starts_with?(line, "#") do
      assert line =~ ~r/^ssh-ed25519 [A-Za-z0-9+\/=]+( .*)?$/
    end
  end

  test "the deploy job is still the file's last, where release_workflow_test reads it" do
    assert @jobs |> Map.keys() |> Enum.member?("deploy")
    [_, after_deploy] = String.split(@text, "\n  deploy:\n", parts: 2)
    refute after_deploy =~ ~r/\n  [a-z][a-z0-9_-]*:\n/
  end
end
