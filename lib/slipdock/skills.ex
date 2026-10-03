defmodule Slipdock.Skills do
  @moduledoc """
  The agent skills this app ships, read from `priv/skills`.

  Skills that live only in a repository are skills that drift. These are
  versioned with the code they describe, served by the running server
  (`GET /api/skills`) and installed by `slipdock skills install`, so the copy in
  somebody's `~/.claude/skills` can be checked against the server that
  actually answers the calls.

  The division of labour matters as much as the distribution: **a skill says
  when and how to reach for the thing; the running server says what is
  currently true.** Board codes, list names and tag vocabularies stay out of
  these files and come from `slipdock guide`, which generates them per caller.
  A skill that hardcodes them rots; one that sends the agent to the guide
  first does not.
  """

  @doc "Where the skills live on disk."
  def dir, do: Path.join(:code.priv_dir(:slipdock), "skills")

  @doc """
  Every skill: its name, the one-line description from its front matter, the
  files it carries, and a sha over all of them.

  The sha is what `slipdock skills check` compares, so "is my copy current" is
  one request and one comparison rather than a diff of four files.
  """
  def list do
    case File.ls(dir()) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&load/1)
      _ -> []
    end
  end

  @doc "One skill, or nil."
  def get(name) do
    case load(name) do
      [skill] -> skill
      _ -> nil
    end
  end

  @doc """
  The contents of one file of a skill — `\"SKILL.md\"`, or a path under
  `references/`. Returns `{:ok, text}` or `{:error, :not_found}`.

  Paths are resolved against the skill's own directory and refused if they
  escape it, so a request cannot walk out of `priv`.
  """
  def read(name, file \\ "SKILL.md") do
    with {:ok, root} <- skill_dir(name),
         {:ok, path} <- within(root, file),
         {:ok, text} <- File.read(path) do
      {:ok, text}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Every skill as one gzipped tar, laid out the way an agent directory expects:
  `slipdock/SKILL.md`, `slipdock-work/SKILL.md`, `slipdock-wiki/references/…`.

  This is what `/install.sh` unpacks. The file-at-a-time JSON endpoints need a
  client that can parse JSON and walk a file list — which the CLI can and a
  `curl | tar` cannot, and `curl | tar` is the one that works on a machine with
  nothing installed.
  """
  def tarball do
    entries =
      for skill <- list(), file <- skill.files, {:ok, text} <- [read(skill.name, file)] do
        {String.to_charlist(Path.join(skill.name, file)), text}
      end

    # Through a temporary file because OTP's tar writer addresses a path, not a
    # binary. The archive is a few hundred kilobytes and the file is gone before
    # this returns.
    path =
      Path.join(
        System.tmp_dir!(),
        "slipdock-skills-#{:erlang.unique_integer([:positive])}.tar.gz"
      )

    try do
      with :ok <- :erl_tar.create(String.to_charlist(path), entries, [:compressed, :write]),
           {:ok, bytes} <- File.read(path) do
        {:ok, bytes}
      else
        _ -> {:error, :unavailable}
      end
    after
      File.rm(path)
    end
  end

  defp load(name) do
    with {:ok, root} <- skill_dir(name),
         {:ok, body} <- File.read(Path.join(root, "SKILL.md")) do
      files = ["SKILL.md" | reference_files(root)]

      [
        %{
          name: name,
          description: description(body),
          files: files,
          sha: sha(root, files),
          bytes: Enum.sum(Enum.map(files, &file_size(root, &1)))
        }
      ]
    else
      _ -> []
    end
  end

  defp skill_dir(name) do
    # Only a plain directory name, so nothing can be addressed by path.
    if Regex.match?(~r/^[a-z0-9][a-z0-9._-]*$/i, to_string(name)) do
      path = Path.join(dir(), name)
      if File.dir?(path), do: {:ok, path}, else: {:error, :not_found}
    else
      {:error, :not_found}
    end
  end

  defp within(root, file) do
    path = Path.expand(Path.join(root, file))

    if String.starts_with?(path, Path.expand(root) <> "/") or path == Path.expand(root),
      do: {:ok, path},
      else: {:error, :not_found}
  end

  defp reference_files(root) do
    references = Path.join(root, "references")

    case File.ls(references) do
      {:ok, files} -> files |> Enum.sort() |> Enum.map(&Path.join("references", &1))
      _ -> []
    end
  end

  # The `description:` line of the YAML front matter — what a client uses to
  # decide whether the skill is relevant, so it is worth surfacing in the
  # listing rather than making everyone fetch the file.
  defp description(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^description:\s*(.+)$/, line) do
        [_, text] -> String.trim(text)
        _ -> nil
      end
    end)
  end

  defp sha(root, files) do
    files
    |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
      case File.read(Path.join(root, file)) do
        {:ok, text} -> :crypto.hash_update(acc, file <> "\0" <> text)
        _ -> acc
      end
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp file_size(root, file) do
    case File.stat(Path.join(root, file)) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
