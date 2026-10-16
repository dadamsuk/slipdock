defmodule Slipdock.Tools.Package do
  @moduledoc """
  Reads a Tool package: a gzipped tar laid out as

      tool.json     name, version, summary, and optionally title, author,
                    requires, and files (see below)
      README.md     the docs, rendered as the Tool's page
      board.json    optional: the board blueprint (`Slipdock.Blueprint`)
      skills/<name>/SKILL.md, and anything else under skills/<name>/
      files/…       optional: files the manifest says where to put

  with or without one top-level directory around it (`job-scan/tool.json`),
  which is what `tar czf job-scan.tgz job-scan` makes.

  Each file under `files/` is listed in `tool.json`'s `files`:

      "files": [
        {"path": "cv-template.docx", "install": "board"},
        {"path": "build.mjs", "install": "local", "skill": "job-scan"}
      ]

  `board` files go into the installed board's wiki, in a folder called
  `Tool`; `local` files go into that skill's directory on the installer's
  machine, beside its `SKILL.md`.

  A package is someone's instructions run by someone else's agent, so
  reading one is strict: only regular files, no path that climbs out or
  starts at the root, nothing outside the layout above, every skill with
  front matter naming it, and limits on count and size.
  """

  alias Slipdock.Blueprint

  @max_compressed 10 * 1024 * 1024
  @max_total 25 * 1024 * 1024
  @max_file 10 * 1024 * 1024
  @max_entries 300
  @name ~r/^[a-z0-9][a-z0-9-]{0,47}$/
  @skill_name ~r/^[a-z0-9][a-z0-9._-]{0,63}$/

  def max_compressed, do: @max_compressed

  @doc """
  Reads `bytes` (a `.tar.gz`) into a package map, or `{:error, message}`:

      %{manifest: map, readme: text, board: blueprint | nil,
        skills: [%{name, description, files: [path within the skill]}],
        files: [%{path, install, skill}], entries: [{path, bytes}], size: n}

  `entries` is every file at its path in the package, sorted by path.
  """
  def read(bytes) when is_binary(bytes) do
    with :ok <- compressed_size(bytes),
         {:ok, headers} <- table(bytes),
         :ok <- check_headers(headers),
         {:ok, entries} <- extract(bytes),
         entries = strip_top(entries),
         :ok <- check_layout(entries),
         {:ok, manifest} <- manifest(entries),
         {:ok, readme} <- readme(entries),
         {:ok, board} <- board(entries),
         {:ok, skills} <- skills(entries),
         {:ok, files} <- files(entries, manifest, skills) do
      {:ok,
       %{
         manifest: manifest,
         readme: readme,
         board: board,
         skills: skills,
         files: files,
         entries: Enum.sort_by(entries, &elem(&1, 0)),
         size: entries |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum()
       }}
    end
  end

  def read(_), do: {:error, "a package is a .tar.gz"}

  @doc """
  The sha that identifies a version: over every file's path and bytes, in
  path order, so the same files give the same sha however they were packed.
  """
  def sha(entries) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {path, bytes}, acc ->
      acc |> :crypto.hash_update(path <> "\0") |> :crypto.hash_update(bytes <> "\0")
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "The `name:` and `description:` of a SKILL.md's front matter, or an error."
  def front_matter("---\n" <> rest) do
    case String.split(rest, ~r/\n---\s*(\n|$)/, parts: 2) do
      [front, _body] ->
        {:ok,
         front
         |> String.split("\n")
         |> Enum.reduce(%{}, fn line, acc ->
           case Regex.run(~r/^([a-zA-Z_-]+):\s*(.*)$/, line) do
             [_, key, value] -> Map.put(acc, key, unquote_value(String.trim(value)))
             _ -> acc
           end
         end)}

      _ ->
        {:error, :unterminated}
    end
  end

  def front_matter(_), do: {:error, :missing}

  defp unquote_value("\"" <> _ = v), do: v |> String.trim("\"")
  defp unquote_value("'" <> _ = v), do: v |> String.trim("'")
  defp unquote_value(v), do: v

  ## The archive ----------------------------------------------------------------

  defp compressed_size(bytes) when byte_size(bytes) > @max_compressed,
    do: {:error, "the package is over #{div(@max_compressed, 1024 * 1024)} MB"}

  defp compressed_size(_), do: :ok

  # The headers first, so sizes and types are checked before anything is
  # unpacked into memory.
  defp table(bytes) do
    case :erl_tar.table({:binary, bytes}, [:compressed, :verbose]) do
      {:ok, headers} -> {:ok, headers}
      _ -> {:error, "that is not a readable .tar.gz"}
    end
  rescue
    _ -> {:error, "that is not a readable .tar.gz"}
  end

  defp check_headers(headers) do
    files = Enum.filter(headers, &(elem(&1, 1) == :regular))

    cond do
      length(headers) > @max_entries ->
        {:error, "the package has more than #{@max_entries} entries"}

      bad = Enum.find(headers, &(elem(&1, 1) not in [:regular, :directory])) ->
        {:error,
         "#{name_of(bad)}: only plain files and folders can be in a package, not a #{elem(bad, 1)}"}

      bad = Enum.find(headers, &(not safe_path?(name_of(&1)))) ->
        {:error, "#{name_of(bad)}: a path in a package must stay inside it"}

      big = Enum.find(files, &(elem(&1, 2) > @max_file)) ->
        {:error, "#{name_of(big)} is over #{div(@max_file, 1024 * 1024)} MB"}

      files |> Enum.map(&elem(&1, 2)) |> Enum.sum() > @max_total ->
        {:error, "the package unpacks to more than #{div(@max_total, 1024 * 1024)} MB"}

      true ->
        :ok
    end
  end

  defp name_of(header), do: header |> elem(0) |> to_string()

  @doc false
  def safe_path?(path) do
    segments = String.split(path, "/", trim: true)

    path != "" and not String.starts_with?(path, "/") and not String.contains?(path, "\\") and
      not String.contains?(path, <<0>>) and not Regex.match?(~r/^[A-Za-z]:/, path) and
      ".." not in segments
  end

  defp extract(bytes) do
    case :erl_tar.extract({:binary, bytes}, [:compressed, :memory]) do
      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.map(fn {name, content} -> {name |> to_string() |> clean_path(), content} end)
         |> Enum.reject(fn {path, _} -> ignored?(path) end)}

      _ ->
        {:error, "that is not a readable .tar.gz"}
    end
  end

  defp clean_path(path),
    do: path |> String.split("/", trim: true) |> Enum.reject(&(&1 == ".")) |> Enum.join("/")

  # What a desktop leaves behind when somebody zips a folder.
  defp ignored?(path) do
    base = Path.basename(path)

    base in [".DS_Store", "Thumbs.db"] or String.starts_with?(base, "._") or
      String.contains?(path, "/.git/") or String.starts_with?(path, ".git/")
  end

  # `job-scan/tool.json` → `tool.json`, when every file is in one folder.
  defp strip_top(entries) do
    tops = entries |> Enum.map(fn {p, _} -> p |> String.split("/") |> hd() end) |> Enum.uniq()

    case tops do
      [top] ->
        if Enum.any?(entries, fn {p, _} -> p == top <> "/tool.json" end),
          do: Enum.map(entries, fn {p, c} -> {String.replace_prefix(p, top <> "/", ""), c} end),
          else: entries

      _ ->
        entries
    end
  end

  @top_files ~w(tool.json README.md board.json)

  defp check_layout(entries) do
    case Enum.find(entries, fn {p, _} ->
           not (p in @top_files or String.starts_with?(p, "skills/") or
                  String.starts_with?(p, "files/"))
         end) do
      nil ->
        :ok

      {path, _} ->
        {:error,
         "#{path}: a package holds tool.json, README.md, board.json, skills/ and files/ only"}
    end
  end

  ## The parts --------------------------------------------------------------------

  defp entry(entries, path), do: Enum.find_value(entries, fn {p, c} -> if p == path, do: c end)

  defp manifest(entries) do
    with {:ok, text} <- required_text(entries, "tool.json"),
         {:ok, json} <- json(text, "tool.json") do
      validate_manifest(json)
    end
  end

  defp validate_manifest(%{} = m) do
    name = m["name"]
    version = m["version"]

    cond do
      not (is_binary(name) and Regex.match?(@name, name)) ->
        {:error,
         "tool.json: name must be lowercase letters, digits and dashes, starting with a letter or digit (at most 48)"}

      not (is_binary(version) and match?({:ok, _}, Version.parse(version))) ->
        {:error, "tool.json: version must be a version number like 1.0.0"}

      not (is_binary(m["summary"]) and String.trim(m["summary"]) != "") ->
        {:error, "tool.json: summary is required — one line on what the Tool does"}

      String.length(m["summary"]) > 200 ->
        {:error, "tool.json: summary is at most 200 characters"}

      not (is_nil(m["title"]) or (is_binary(m["title"]) and String.length(m["title"]) <= 80)) ->
        {:error, "tool.json: title is text, at most 80 characters"}

      not (is_nil(m["author"]) or is_binary(m["author"])) ->
        {:error, "tool.json: author is text"}

      not (is_nil(m["requires"]) or is_map(m["requires"]) or is_list(m["requires"])) ->
        {:error, "tool.json: requires is an object or a list"}

      not (is_nil(m["files"]) or is_list(m["files"])) ->
        {:error, "tool.json: files is a list"}

      true ->
        {:ok,
         m
         |> Map.put("summary", String.trim(m["summary"]))
         |> Map.put("title", m["title"] || name)
         |> Map.put_new("files", [])}
    end
  end

  defp validate_manifest(_), do: {:error, "tool.json: must be a JSON object"}

  defp readme(entries), do: required_text(entries, "README.md")

  defp board(entries) do
    case entry(entries, "board.json") do
      nil ->
        {:ok, nil}

      bytes ->
        with {:ok, text} <- utf8(bytes, "board.json"),
             {:ok, json} <- json(text, "board.json") do
          case Blueprint.validate(json) do
            {:ok, blueprint} -> {:ok, blueprint}
            {:error, message} -> {:error, "board.json: " <> message}
          end
        end
    end
  end

  defp skills(entries) do
    by_skill =
      entries
      |> Enum.filter(fn {p, _} -> String.starts_with?(p, "skills/") end)
      |> Enum.group_by(fn {p, _} -> p |> String.split("/") |> Enum.at(1) end)

    cond do
      by_skill == %{} ->
        {:error, "a package needs at least one skill, in skills/<name>/SKILL.md"}

      loose =
          Enum.find(
            Map.keys(by_skill),
            &(not String.contains?(&1, "/") and loose_file?(entries, &1))
          ) ->
        {:error, "skills/#{loose}: each skill is a folder with a SKILL.md in it"}

      true ->
        by_skill
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, []}, fn {name, files}, {:ok, acc} ->
          case skill(name, files) do
            {:ok, skill} -> {:cont, {:ok, acc ++ [skill]}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp loose_file?(entries, name), do: Enum.any?(entries, fn {p, _} -> p == "skills/" <> name end)

  defp skill(name, files) do
    prefix = "skills/#{name}/"

    with true <-
           Regex.match?(@skill_name, name) || {:error, "skills/#{name}: not a usable skill name"},
         {:ok, text} <- required_text(files, prefix <> "SKILL.md"),
         {:ok, front} <- skill_front(name, text) do
      {:ok,
       %{
         name: name,
         description: front["description"],
         files:
           files
           |> Enum.map(fn {p, _} -> String.replace_prefix(p, prefix, "") end)
           |> Enum.sort_by(&if(&1 == "SKILL.md", do: "", else: &1))
       }}
    end
  end

  defp skill_front(name, text) do
    case front_matter(text) do
      {:ok, %{"name" => ^name, "description" => d}} when is_binary(d) and d != "" ->
        {:ok, %{"description" => d}}

      {:ok, %{"name" => other}} when other != name ->
        {:error,
         "skills/#{name}/SKILL.md: front matter name is “#{other}”, but the folder is #{name}"}

      {:ok, _} ->
        {:error, "skills/#{name}/SKILL.md: front matter needs a name and a description"}

      _ ->
        {:error,
         "skills/#{name}/SKILL.md: must start with front matter (--- name, description ---)"}
    end
  end

  defp files(entries, manifest, skills) do
    present =
      entries
      |> Enum.filter(fn {p, _} -> String.starts_with?(p, "files/") end)
      |> Enum.map(fn {p, _} -> String.replace_prefix(p, "files/", "") end)
      |> MapSet.new()

    skill_names = MapSet.new(skills, & &1.name)

    with {:ok, declared} <- declared_files(manifest["files"], skill_names, skills) do
      paths = MapSet.new(declared, & &1.path)

      cond do
        missing = Enum.find(declared, &(not MapSet.member?(present, &1.path))) ->
          {:error,
           "tool.json: files lists #{missing.path}, but files/#{missing.path} is not in the package"}

        extra = Enum.find(present, &(not MapSet.member?(paths, &1))) ->
          {:error,
           "files/#{extra}: not listed in tool.json's files — say whether it installs to the board or locally"}

        true ->
          {:ok, declared}
      end
    end
  end

  defp declared_files(list, skill_names, skills) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {f, i}, {:ok, acc} ->
      case declared_file(f, i, skill_names, skills) do
        {:ok, file} ->
          if Enum.any?(acc, &(&1.path == file.path)),
            do: {:halt, {:error, "tool.json: files lists #{file.path} twice"}},
            else: {:cont, {:ok, acc ++ [file]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp declared_file(%{"path" => path, "install" => install} = f, i, skill_names, skills)
       when is_binary(path) do
    skill = f["skill"]

    cond do
      not safe_path?(path) ->
        {:error, "tool.json: files[#{i}] path must stay inside files/"}

      install not in ["board", "local"] ->
        {:error, "tool.json: files[#{i}] install is board or local"}

      install == "local" and not MapSet.member?(skill_names, skill) ->
        {:error,
         "tool.json: files[#{i}] (#{path}) installs locally, so it needs a skill from skills/ to go beside"}

      install == "local" and
          path in Enum.find(skills, &(&1.name == skill)).files ->
        {:error,
         "tool.json: files[#{i}] (#{path}) would overwrite the #{skill} skill's own #{path}"}

      true ->
        {:ok, %{path: path, install: install, skill: if(install == "local", do: skill)}}
    end
  end

  defp declared_file(_, i, _, _),
    do: {:error, "tool.json: files[#{i}] needs a path and install (board or local)"}

  ## Helpers ------------------------------------------------------------------------

  defp required_text(entries, path) do
    case entry(entries, path) do
      nil -> {:error, "#{path} is missing"}
      bytes -> utf8(bytes, path)
    end
  end

  defp utf8(bytes, path) do
    if String.valid?(bytes), do: {:ok, bytes}, else: {:error, "#{path}: must be UTF-8 text"}
  end

  defp json(text, path) do
    case Jason.decode(text) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, "#{path}: not valid JSON"}
    end
  end
end
