defmodule Slipdock.ToolPackages do
  @moduledoc """
  Tool packages for tests (see `Slipdock.Tools.Package`): a valid one to
  start from, and the tar it packs into.
  """

  @doc "A small valid package, as path => contents. `overrides` replace or add files; nil drops one."
  def files(name \\ "demo", version \\ "1.0.0", overrides \\ %{}) do
    %{
      "tool.json" =>
        Jason.encode!(%{
          "name" => name,
          "title" => "Demo Tool",
          "version" => version,
          "summary" => "A tool for tests.",
          "author" => "Tester",
          "files" => [
            %{"path" => "guide.md", "install" => "board"},
            %{"path" => "helper.sh", "install" => "local", "skill" => name}
          ]
        }),
      "README.md" => "# Demo\n\nWhat it does.",
      "board.json" =>
        Jason.encode!(%{
          "lists" => [
            %{"name" => "Found", "role" => "ready"},
            %{"name" => "Doing", "role" => "doing"},
            %{"name" => "Closed", "role" => "done"}
          ],
          "folders" => ["Config"],
          "tags" => ["hot"],
          "pages" => [
            %{"title" => "#{name} config", "folder" => "Config", "body" => "Fill me in."}
          ],
          "automations" => [
            %{
              "preset" => "send_to_runner",
              "params" => %{"column" => "Doing", "pool" => "default"}
            }
          ]
        }),
      "skills/#{name}/SKILL.md" =>
        "---\nname: #{name}\ndescription: Does the demo thing.\n---\n\n# #{name}\n\nRun it.",
      "skills/#{name}/references/notes.md" => "Notes.",
      "skills/#{name}-setup/SKILL.md" =>
        "---\nname: #{name}-setup\ndescription: Sets the demo up.\n---\n\nCall install_tool.",
      "files/guide.md" => "A guide for the board.",
      "files/helper.sh" => "#!/bin/sh\necho hi\n"
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  @doc "Packs `files` (path => contents) as a .tar.gz, under `top/` when given."
  def tarball(files, top \\ nil) do
    entries =
      for {path, content} <- Enum.sort(files) do
        path = if top, do: Path.join(top, path), else: path
        {String.to_charlist(path), content}
      end

    path = Path.join(System.tmp_dir!(), "tool-#{System.unique_integer([:positive])}.tar.gz")

    try do
      :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed, :write])
      File.read!(path)
    after
      File.rm(path)
    end
  end

  @doc "A valid package's bytes."
  def package(name \\ "demo", version \\ "1.0.0", overrides \\ %{}),
    do: tarball(files(name, version, overrides))

  @doc "A unique Tool name, so async tests never share one."
  def unique_name, do: "t#{System.unique_integer([:positive])}"
end
