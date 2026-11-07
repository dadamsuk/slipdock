defmodule SlipdockCLI.Lanes do
  @moduledoc """
  The lane-check hook (#1629): an optional git `pre-commit` hook that keeps
  a commit inside the paths its card declared (#1628).

      slipdock hook install lane-check     # in the repository, once
      slipdock hook uninstall lane-check
      slipdock lane-check [--card ID]      # what the hook runs

  `lane-check` finds the card being worked — `--card`, else
  `$SLIPDOCK_CARD` (a runner job sets it), else a branch named `card-<id>`
  (the runner's worktree branches) — reads its paths from the board, and
  refuses a commit that stages files outside them, listing the files. A
  card with no paths, or no card at all, passes. A staged file under one of
  the board's shared paths (#1971) goes through either way, and the hook
  says it let it through as shared. It never blocks on the
  network: a board that can't be reached, or doesn't answer in a few
  seconds, gets a warning and the commit goes ahead.

  The work is done in functions that return values (`check/3`,
  `install/1`, …) so the tests can see it; `run/3` prints and exits.
  """

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(hook lane-check)
  @marker "# slipdock lane-check hook"
  @timeout 5_000

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  # -- Commands ---------------------------------------------------------------

  def run("hook", ["install", "lane-check"], _o) do
    case install(File.cwd!()) do
      {:ok, path} ->
        IO.puts("installed the lane-check pre-commit hook: #{path}")
        IO.puts("A commit on a card's work now stays inside the card's paths.")

      {:error, message} ->
        fail(message)
    end
  end

  def run("hook", ["uninstall", "lane-check"], _o) do
    case uninstall(File.cwd!()) do
      {:ok, path} -> IO.puts("removed the lane-check hook: #{path}")
      {:error, message} -> fail(message)
    end
  end

  def run("hook", _args, _o),
    do: fail("usage: slipdock hook install lane-check | slipdock hook uninstall lane-check")

  def run("lane-check", [], o) do
    case check(File.cwd!(), o[:card], System.get_env("SLIPDOCK_CARD")) do
      {:pass, nil} ->
        :ok

      {:pass, message} ->
        IO.puts(:stderr, message)

      {:warn, message} ->
        IO.puts(:stderr, "lane-check: " <> message <> "; commit allowed")

      {:refuse, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  def run("lane-check", _args, _o), do: fail("usage: slipdock lane-check [--card ID]")

  # -- The hook ---------------------------------------------------------------

  @doc "The pre-commit hook's script."
  def script do
    """
    #!/bin/sh
    #{@marker} (installed by `slipdock hook install lane-check`; remove it with
    # `slipdock hook uninstall lane-check`). Refuses a commit that stages files
    # outside the paths of the card being worked; `git commit --no-verify` skips it.
    command -v slipdock >/dev/null 2>&1 || {
      echo "lane-check: slipdock is not on the PATH; commit allowed" >&2
      exit 0
    }
    exec slipdock lane-check
    """
  end

  @doc """
  Installs the hook in the repository at `dir`. `{:ok, path}`, or
  `{:error, message}` outside a repository or over a hook of somebody
  else's (installing again over its own is fine).
  """
  def install(dir) do
    with {:ok, path} <- hook_path(dir) do
      if File.exists?(path) and not ours?(path) do
        {:error,
         "#{path} is already there and isn't the lane-check hook: call `slipdock lane-check` " <>
           "from it yourself, or move it aside first"}
      else
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, script())
        File.chmod!(path, 0o755)
        {:ok, path}
      end
    end
  end

  @doc "Removes the hook from the repository at `dir`, if it is the lane-check one."
  def uninstall(dir) do
    with {:ok, path} <- hook_path(dir) do
      cond do
        not File.exists?(path) -> {:error, "no pre-commit hook at #{path}"}
        not ours?(path) -> {:error, "#{path} isn't the lane-check hook; left alone"}
        true -> with :ok <- File.rm(path), do: {:ok, path}
      end
    end
  end

  defp ours?(path), do: File.read!(path) =~ @marker

  # The hooks directory git uses, shared by every worktree of the repository
  # (and core.hooksPath, when set).
  defp hook_path(dir) do
    case git(dir, ["rev-parse", "--git-path", "hooks"]) do
      {:ok, hooks} -> {:ok, Path.join(Path.expand(hooks, dir), "pre-commit")}
      :error -> {:error, "#{dir} is not in a git repository"}
    end
  end

  # -- The check --------------------------------------------------------------

  @doc """
  The check for a commit in the repository at `dir`, the card given as
  `flag` or in `env` (else read from the branch): `{:pass, nil}`, `{:pass,
  message}` (files outside the card's paths let through as shared on the
  board, #1971),
  `{:warn, message}` (the board couldn't say; the commit goes ahead) or
  `{:refuse, message}` naming the files outside the card's paths.
  """
  def check(dir, flag, env) do
    case card_id(flag, env, branch(dir)) do
      nil -> {:pass, nil}
      id -> check_card(dir, id)
    end
  end

  defp check_card(dir, id) do
    case fetch_paths(id) do
      {:ok, [], _shared} ->
        {:pass, nil}

      {:ok, paths, shared} ->
        outside = outside(staged(dir), paths)
        # Shared paths (#1971) hold no lane: a file under one goes through
        # whether or not the card declares it.
        allowed = outside -- outside(outside, shared)

        case outside -- allowed do
          [] when allowed == [] ->
            {:pass, nil}

          [] ->
            {:pass,
             "lane-check: allowed as shared on the board, outside card ##{id}'s paths:\n" <>
               Enum.map_join(allowed, "\n", &"  #{&1}")}

          files ->
            {:refuse,
             "lane-check: card ##{id}'s paths are\n" <>
               Enum.map_join(paths, "\n", &"  #{&1}") <>
               "\nand this commit stages files outside them:\n" <>
               Enum.map_join(files, "\n", &"  #{&1}") <>
               "\nUnstage them (git restore --staged <file>), or widen the card's paths " <>
               "(slipdock edit #{id} --paths …). git commit --no-verify skips this check."}
        end

      {:error, why} ->
        {:warn, "couldn't read card ##{id}'s paths (#{why})"}
    end
  end

  @doc "The card being worked: the flag, then the environment, then a `card-<id>` branch."
  def card_id(flag, env, branch) do
    Enum.find_value([flag, env], &id/1) ||
      case Regex.run(~r/(?:^|\/)card-(\d+)$/, branch || "") do
        [_, id] -> id
        nil -> nil
      end
  end

  defp id(value) when is_binary(value) do
    case Regex.run(~r/\A#?(\d+)\z/, String.trim(value)) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp id(_value), do: nil

  defp branch(dir) do
    case git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> branch
      :error -> nil
    end
  end

  # The card's paths and its board's shared paths, giving up after @timeout: a hook never waits long on
  # the network.
  defp fetch_paths(id) do
    task = Task.async(fn -> HTTP.get("/cards/#{id}") end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{"card" => card}}} -> {:ok, card["paths"] || [], card["shared_paths"] || []}
      {:ok, {:error, :connect, reason}} -> {:error, "board unreachable: #{inspect(reason)}"}
      {:ok, {:error, status, _}} -> {:error, "HTTP #{status}"}
      {:ok, _} -> {:error, "an answer it couldn't read"}
      nil -> {:error, "no answer in #{div(@timeout, 1000)}s"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Every path the commit touches: added, changed, deleted, and both sides
  # of a rename.
  defp staged(dir) do
    case git(dir, ["diff", "--cached", "--name-only", "--no-renames", "-z"]) do
      {:ok, out} -> String.split(out, <<0>>, trim: true)
      :error -> []
    end
  end

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # -- Matching ---------------------------------------------------------------

  @doc "The files no glob of `paths` covers."
  def outside(files, paths) do
    regexes = Enum.flat_map(paths, &regexes/1)
    Enum.reject(files, fn file -> Enum.any?(regexes, &Regex.match?(&1, file)) end)
  end

  @doc """
  Whether `glob` covers `file`: `*` and `?` within one folder, `**` any
  number of folders, `{a,b}` either, `[...]` a class, and a path covers
  everything under it. The server's overlap check (`Slipdock.Lanes`) reads
  globs the same way.
  """
  def covers?(glob, file), do: Enum.any?(regexes(glob), &Regex.match?(&1, file))

  defp regexes(glob) do
    glob
    |> String.trim()
    |> String.replace_prefix("./", "")
    |> String.trim_trailing("/")
    |> expand()
    |> Enum.map(&Regex.compile!("\\A" <> translate(&1, "") <> "(?:/.*)?\\z"))
  end

  defp expand(glob) do
    case Regex.run(~r/\{([^{}]*)\}/, glob, return: :index) do
      nil ->
        [glob]

      [{start, len}, {inner_start, inner_len}] ->
        prefix = binary_part(glob, 0, start)
        suffix = binary_part(glob, start + len, byte_size(glob) - start - len)

        glob
        |> binary_part(inner_start, inner_len)
        |> String.split(",")
        |> Enum.flat_map(&expand(prefix <> &1 <> suffix))
        |> Enum.take(64)
    end
  end

  defp translate("", acc), do: acc
  defp translate("**/" <> rest, acc), do: translate(rest, acc <> "(?:.*/)?")
  defp translate("**", acc), do: acc <> ".*"
  defp translate("*" <> rest, acc), do: translate(rest, acc <> "[^/]*")
  defp translate("?" <> rest, acc), do: translate(rest, acc <> "[^/]")

  defp translate("[" <> rest, acc) do
    case String.split(rest, "]", parts: 2) do
      [class, rest] when class != "" ->
        class = String.replace_prefix(class, "!", "^")
        translate(rest, acc <> "[" <> String.replace(class, "\\", "\\\\") <> "]")

      _ ->
        translate(rest, acc <> "\\[")
    end
  end

  defp translate(<<c::utf8, rest::binary>>, acc),
    do: translate(rest, acc <> Regex.escape(<<c::utf8>>))
end
