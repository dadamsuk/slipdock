defmodule Slipdock.SkillRegistry.GitHub do
  @moduledoc """
  What a source URL points at, and for a GitHub repository, which files to
  fetch (#2060).

  A URL is one of:

    * a repository, `https://github.com/<owner>/<repo>`, optionally
      `/tree/<ref>/<path>` to take only the skills under a path;
    * one file in a repository, `https://github.com/<owner>/<repo>/blob/<ref>/<path>.md`
      or its `raw.githubusercontent.com` form;
    * one Markdown file at any other `https` URL.

  For a repository it asks GitHub's API for the default branch and licence,
  the commit the ref names, and the tree at that commit, then fetches each
  file from `raw.githubusercontent.com` at that commit, so every entry of a
  fetch comes from one version.
  """

  alias Slipdock.SkillRegistry.Fetch

  @api "https://api.github.com"
  @raw "https://raw.githubusercontent.com"
  @json_max 5_000_000

  @type target ::
          {:repo, %{owner: String.t(), repo: String.t(), ref: String.t() | nil, path: String.t()}}
          | {:repo_file,
             %{owner: String.t(), repo: String.t(), ref: String.t(), path: String.t()}}
          | {:file, String.t()}

  @doc "What `url` points at, or why it can't be a source."
  @spec target(String.t()) :: {:ok, target} | {:error, String.t()}
  def target(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, path: path}} when is_binary(host) ->
        by_host(String.downcase(host), segments(path), url)

      {:ok, %URI{scheme: "http"}} ->
        {:error, "should be an https URL"}

      _ ->
        {:error, "is not a URL"}
    end
  end

  defp by_host(host, [owner, repo | rest], url) when host in ["github.com", "www.github.com"] do
    repo = String.replace_suffix(repo, ".git", "")

    case rest do
      [] ->
        {:ok, {:repo, %{owner: owner, repo: repo, ref: nil, path: ""}}}

      ["tree", ref | path] ->
        {:ok, {:repo, %{owner: owner, repo: repo, ref: ref, path: Enum.join(path, "/")}}}

      ["blob", ref | path] when path != [] ->
        repo_file(owner, repo, ref, path)

      _ ->
        not_a_source(url)
    end
  end

  defp by_host("raw.githubusercontent.com", [owner, repo, ref | path], _url) when path != [],
    do: repo_file(owner, repo, ref, path)

  defp by_host(_host, segments, url) do
    if markdown?(List.last(segments)), do: {:ok, {:file, url}}, else: not_a_source(url)
  end

  defp repo_file(owner, repo, ref, path) do
    if markdown?(List.last(path)),
      do: {:ok, {:repo_file, %{owner: owner, repo: repo, ref: ref, path: Enum.join(path, "/")}}},
      else: {:error, "is not a Markdown file"}
  end

  defp not_a_source(_url),
    do: {:error, "is not a GitHub repository or a SKILL.md URL"}

  defp markdown?(nil), do: false
  defp markdown?(name), do: name |> String.downcase() |> String.ends_with?(".md")

  defp segments(nil), do: []
  defp segments(path), do: path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

  @doc """
  The repository's facts: `%{name, licence, sha, truncated, files}`, where
  `files` is every blob in its tree at the commit `ref` names (the default
  branch when nil), as `%{path, size}`. `tree: false` skips the tree.
  """
  @spec repository(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def repository(owner, repo, ref, opts \\ []) do
    with {:ok, info} <- json("#{@api}/repos/#{e(owner)}/#{e(repo)}", "#{owner}/#{repo}"),
         ref = ref || info["default_branch"] || "HEAD",
         {:ok, sha} <- commit(owner, repo, ref),
         {:ok, tree} <- tree(owner, repo, sha, Keyword.get(opts, :tree, true)) do
      files =
        for %{"type" => "blob", "path" => path} = item <- tree["tree"] || [],
            do: %{path: path, size: item["size"] || 0}

      {:ok,
       %{
         name: info["full_name"] || "#{owner}/#{repo}",
         licence: licence(info),
         sha: sha,
         truncated: tree["truncated"] == true,
         files: files
       }}
    end
  end

  defp tree(_owner, _repo, _sha, false), do: {:ok, %{}}

  defp tree(owner, repo, sha, true),
    do: json("#{@api}/repos/#{e(owner)}/#{e(repo)}/git/trees/#{sha}?recursive=1", "its tree")

  @doc "The raw URL of `path` in a repository at `sha`."
  def raw_url(owner, repo, sha, path) do
    encoded = path |> String.split("/") |> Enum.map_join("/", &e/1)
    "#{@raw}/#{e(owner)}/#{e(repo)}/#{e(sha)}/#{encoded}"
  end

  defp commit(owner, repo, ref) do
    url = "#{@api}/repos/#{e(owner)}/#{e(repo)}/commits/#{e(ref)}"

    case Fetch.get(url, max_bytes: 200, headers: [{"accept", "application/vnd.github.sha"}]) do
      {:ok, %{body: body}} ->
        sha = String.trim(body)

        if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
          do: {:ok, sha},
          else: {:error, "#{ref} did not name a commit"}

      {:error, reason} ->
        {:error, "#{ref} #{reason}"}
    end
  end

  defp json(url, what) do
    headers = [{"accept", "application/vnd.github+json"}]

    with {:ok, %{body: body}} <-
           prefixed(Fetch.get(url, max_bytes: @json_max, headers: headers), what) do
      case Jason.decode(body) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _ -> {:error, "#{what} did not answer with JSON"}
      end
    end
  end

  defp prefixed({:error, reason}, what), do: {:error, "#{what} #{reason}"}
  defp prefixed(ok, _what), do: ok

  defp licence(%{"license" => %{"spdx_id" => id}}) when is_binary(id) and id != "NOASSERTION",
    do: id

  defp licence(_), do: nil

  defp e(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
