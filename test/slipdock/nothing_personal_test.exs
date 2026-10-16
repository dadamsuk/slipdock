defmodule Slipdock.NothingPersonalTest do
  @moduledoc """
  The repository is public, so nothing tracked in it should belong to one
  person's machine: no real email addresses, no home directories, no addresses
  on somebody's private network, no API keys.

  This is a guard rather than a review — it runs on every commit, which is when
  such a line actually gets added. If it fails on something harmless, widen
  `@allowed` with a reason rather than deleting the test.
  """
  use ExUnit.Case, async: true

  # Each: a name, a regex, and what to do instead.
  @forbidden [
    {"a real email address",
     ~r/\b[\w.+-]+@(?!example\.(com|org|net)\b|work\.example\b|other\.example\b|elsewhere\.com\b|localhost\b)[\w-]+\.[a-z]{2,}\b/i,
     "use example.com, or read it from config"},
    {"a home directory", ~r{/home/[a-z][\w-]+/}, "use a relative path or a setting"},
    {"a private-network address",
     ~r/\b(10|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])|192\.168)\.\d+\.\d+\b/,
     "use a hostname from config"},
    {"an OpenRouter key", ~r/sk-or-v1-[A-Za-z0-9]{20,}/,
     "keys belong in ai_keys.json, never in git"},
    {"a Slack or GitHub token", ~r/\b(xox[baprs]-[\w-]{10,}|ghp_[A-Za-z0-9]{20,})\b/, "revoke it"}
  ]

  # Files that may say such things, and why.
  @allowed [
    # The licence is somebody else's text, with the FSF's address in it.
    "LICENSE",
    # Written by the test runs themselves.
    "mix.lock",
    # The egress guard's own tests: private addresses are what it refuses.
    "test/slipdock/egress_test.exs",
    # The CLI's own: which private addresses plain http may go to unwarned.
    "cli/test/security_test.exs",
    # The default trusted proxies: the private ranges, by name.
    "lib/slipdock_web/client_ip.ex",
    # npm's lockfile for the vendored Excalidraw build: version ranges such
    # of node versions starting at ten read as addresses.
    "assets/excalidraw/package-lock.json"
  ]

  # Folders of somebody else's code, committed as it was built
  # (assets/excalidraw/build.sh): minified numbers read as addresses.
  @allowed_dirs ["priv/static/vendor/"]

  test "no file in this repository carries anything personal" do
    offences =
      for path <- tracked_files(),
          path not in @allowed,
          not Enum.any?(@allowed_dirs, &String.starts_with?(path, &1)),
          {what, pattern, instead} <- @forbidden,
          line_number_and_text <- matches(path, pattern) do
        {line, text} = line_number_and_text
        "#{path}:#{line}: #{what} — #{instead}\n    #{String.slice(text, 0, 120)}"
      end

    assert offences == [],
           "Something personal is tracked in this repository:\n\n" <> Enum.join(offences, "\n")
  end

  test "a file of bytes is skipped, and a text file still reports its lines" do
    dir = Path.join(System.tmp_dir!(), "nothing-personal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {_, pattern, _} = hd(@forbidden)
    # Put together here, so this file doesn't carry the address it tests for.
    address = Enum.join(["someone", "real-domain.io"], "@")

    bytes = Path.join(dir, "clip.mp4")
    File.write!(bytes, <<0xFF, 0xFE, address::binary, 0xC3>>)
    assert lines_matching(bytes, pattern) == []

    text = Path.join(dir, "notes.md")
    File.write!(text, "fine\nmail #{address}\n")
    assert lines_matching(text, pattern) == [{2, "mail #{address}"}]

    assert lines_matching(Path.join(dir, "missing.txt"), pattern) == []
  end

  # Tracked files *and* new ones not yet added, because the point is to catch
  # something before it is committed. Checking only `git ls-files` meant a new
  # file was invisible until the commit that introduced it — so the test passed
  # locally and failed in CI, which is the wrong way round.
  defp tracked_files do
    {tracked, 0} = System.cmd("git", ["ls-files"], cd: root())
    {untracked, 0} = System.cmd("git", ["ls-files", "--others", "--exclude-standard"], cd: root())

    (tracked <> "\n" <> untracked)
    |> String.split("\n", trim: true)
    # Pictures and fonts are bytes, not prose, and their path data trips the
    # address patterns by coincidence.
    |> Enum.reject(
      &(Path.extname(&1) in [".woff2", ".png", ".jpg", ".ico", ".gif", ".webp", ".svg"])
    )
  end

  defp matches(path, pattern), do: lines_matching(Path.join(root(), path), pattern)

  # A file that isn't UTF-8 is bytes, not prose (a video, an archive): its
  # "lines" match by coincidence, and printing one crashed ExUnit's formatter
  # and lost the whole run's summary (#833).
  defp lines_matching(full, pattern) do
    case File.read(full) do
      {:ok, body} when is_binary(body) ->
        if String.valid?(body), do: lines_in(body, pattern), else: []

      _ ->
        []
    end
  end

  defp lines_in(body, pattern) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(pattern, line) end)
    |> Enum.map(fn {line, number} -> {number, line} end)
  end

  defp root, do: Path.expand("../..", __DIR__)
end
