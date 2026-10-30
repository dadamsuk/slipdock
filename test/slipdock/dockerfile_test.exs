defmodule Slipdock.DockerfileTest do
  @moduledoc """
  The Dockerfile fetches Tailwind itself (with curl) because `mix
  tailwind.install` fails on GitHub's oversized redirect headers. That only
  works while it fetches the version the config asks for: with any other,
  `mix assets.setup` would try the download again and the image build would
  fail the same way. mdex's NIF hits the same limit in `mix deps.compile`,
  so it comes from the package's own mirror instead.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @dockerfile File.read!(Path.join(@root, "Dockerfile"))

  defp dockerfile_tailwind_version do
    [_, version] = Regex.run(~r/^ARG TAILWIND_VERSION="([^"]+)"$/m, @dockerfile)
    version
  end

  test "fetches the Tailwind version config/config.exs asks for" do
    assert dockerfile_tailwind_version() == Application.fetch_env!(:tailwind, :version)
  end

  test "points the tailwind mix tasks at the fetched binary before assets.setup" do
    [before_setup, _] = String.split(@dockerfile, "\nRUN mix assets.setup\n", parts: 2)

    assert before_setup =~ "cd /opt/tailwind"
    assert before_setup =~ ~s(mv "$tw" tailwindcss)
    assert before_setup =~ ~r{^ENV MIX_TAILWIND_PATH=/opt/tailwind/tailwindcss$}m
  end

  test "the running image has what reads uploaded documents" do
    [_, runner] = String.split(@dockerfile, "FROM ${RUNNER_IMAGE}", parts: 2)

    for package <- ~w(tesseract-ocr tesseract-ocr-eng poppler-utils) do
      assert runner =~ ~r/\b#{package}\b/
    end
  end

  test "checks the download against the release's checksums" do
    assert @dockerfile =~ "sha256sums.txt"
    assert @dockerfile =~ "sha256sum -c -"
  end

  test "maps both image platforms to a Tailwind binary, and fails on any other" do
    assert @dockerfile =~ "amd64) tw=tailwindcss-linux-x64"
    assert @dockerfile =~ "arm64) tw=tailwindcss-linux-arm64"
    assert @dockerfile =~ ~r/\*\) echo "no Tailwind binary for .*exit 1/
  end

  test "config :tailwind, :path comes from MIX_TAILWIND_PATH, nil when unset" do
    assert Application.get_env(:tailwind, :path) == System.get_env("MIX_TAILWIND_PATH")
  end

  test "mdex's NIF comes from the mirror, not GitHub's oversized redirect" do
    assert Application.get_env(:mdex_native, :artifact_source) == :cloudflare
    assert MDExNative.Native.ArtifactURL.url("x") =~ "https://artifacts.mdelixir.dev/"
  end
end
